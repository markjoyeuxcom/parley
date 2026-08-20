//! Terminal panes, on `portable-pty` instead of `node-pty`.
//!
//! This module is the whole reason the migration is viable or not. Everything
//! else in Parley's main process is ordinary logic that moves to Rust
//! mechanically; the PTY layer is the part that has cost the most to get right,
//! and AGENTS.md carries three separate hard-won notes about it. They are
//! reproduced here as behaviour rather than as folklore, because a rewrite
//! inherits none of them for free:
//!
//! * A GUI app is launched by `launchd` with a minimal `/usr/bin:/bin` PATH,
//!   so anything from Homebrew, mise, npm or an install script is invisible.
//!   The login shell is asked for its PATH once at startup.
//! * Panes are spawned with an explicit argv and never through a shell. Agent
//!   authored strings reach this layer, and a shell would make any of them an
//!   injection.
//! * A pane's process is told which pane it is, so a CLI running inside one can
//!   tell it is inside Parley rather than launching a second copy of the app to
//!   reach its neighbour.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::Arc;

use parking_lot::Mutex;
use portable_pty::{CommandBuilder, NativePtySystem, PtyPair, PtySize, PtySystem};
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Pane {
    pub id: String,
    pub kind: String,
    pub title: String,
    pub cwd: String,
    pub status: String,
    pub exit_code: Option<i32>,
    pub created_at: i64,
}

/// One chunk of output, on its own channel. High volume and opaque bytes: the
/// Electron build learned to coalesce these into one message per frame rather
/// than one per chunk, and that batching belongs here too once panes work.
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PtyChunk {
    pub pane_id: String,
    pub data: String,
}

struct Live {
    pane: Pane,
    pair: PtyPair,
    writer: Box<dyn Write + Send>,
}

#[derive(Default)]
pub struct Panes {
    live: Arc<Mutex<HashMap<String, Live>>>,
}

impl Panes {
    pub fn list(&self) -> Vec<Pane> {
        self.live.lock().values().map(|l| l.pane.clone()).collect()
    }

    pub fn open(
        &self,
        app: &AppHandle,
        kind: &str,
        cwd: &str,
        cols: u16,
        rows: u16,
    ) -> Result<Pane, String> {
        let (file, args) = command_for(kind);
        let resolved = which(&file).ok_or_else(|| {
            // The same distinction the Electron build draws: "the CLI is not
            // installed" and "the pty layer is broken" produce identical
            // errors from the pty crate and need opposite fixes.
            if kind == "shell" {
                format!("{file} was not found. Set $SHELL to a shell that exists.")
            } else {
                format!(
                    "The {kind} CLI was not found on PATH. Install it and sign in, then restart \
                     Parley so it picks up your shell's PATH."
                )
            }
        })?;

        let system = NativePtySystem::default();
        let pair = system
            .openpty(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
            .map_err(|e| format!("could not open a pty: {e}"))?;

        let id = new_id();
        let mut cmd = CommandBuilder::new(&resolved);
        for arg in &args {
            cmd.arg(arg);
        }
        cmd.cwd(cwd);
        cmd.env("TERM", "xterm-256color");
        for (key, value) in pane_env(&id, kind) {
            cmd.env(key, value);
        }

        let mut child = pair
            .slave
            .spawn_command(cmd)
            .map_err(|e| format!("could not start {resolved}: {e}"))?;

        let writer = pair
            .master
            .take_writer()
            .map_err(|e| format!("could not write to the pty: {e}"))?;
        let mut reader = pair
            .master
            .try_clone_reader()
            .map_err(|e| format!("could not read from the pty: {e}"))?;

        let pane = Pane {
            id: id.clone(),
            kind: kind.to_string(),
            title: cwd.rsplit('/').next().unwrap_or(cwd).to_string(),
            cwd: cwd.to_string(),
            status: "starting".into(),
            exit_code: None,
            created_at: now_ms(),
        };

        self.live.lock().insert(
            id.clone(),
            Live { pane: pane.clone(), pair, writer },
        );

        // Output pump. One thread per pane rather than async: a PTY read is a
        // blocking file descriptor, and a thread per terminal is the cheap,
        // obvious shape at this scale.
        let handle = app.clone();
        let pane_id = id.clone();
        let live = Arc::clone(&self.live);
        std::thread::spawn(move || {
            let mut buffer = [0u8; 8 * 1024];
            loop {
                match reader.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(n) => {
                        let data = String::from_utf8_lossy(&buffer[..n]).to_string();
                        // Never swallowed. A pane that draws nothing looks
                        // identical whether the child said nothing or the
                        // event never reached the webview, and those need
                        // opposite fixes.
                        if let Err(err) = handle.emit(
                            "pty:data",
                            PtyChunk { pane_id: pane_id.clone(), data },
                        ) {
                            eprintln!("parley: pane {pane_id} output could not be delivered: {err}");
                        }
                    }
                    Err(_) => break,
                }
            }
            let code = child.wait().ok().and_then(|s| i32::try_from(s.exit_code()).ok());
            if let Some(entry) = live.lock().get_mut(&pane_id) {
                entry.pane.status = "exited".into();
                entry.pane.exit_code = code;
            }
            let _ = handle.emit("pane:status", (pane_id.clone(), "exited", code));
        });

        Ok(pane)
    }

    pub fn write(&self, pane_id: &str, data: &str) -> Result<(), String> {
        let mut live = self.live.lock();
        let entry = live.get_mut(pane_id).ok_or("that pane is no longer open")?;
        entry
            .writer
            .write_all(data.as_bytes())
            .map_err(|e| format!("could not write to the pane: {e}"))?;
        entry.writer.flush().map_err(|e| format!("could not flush: {e}"))
    }

    pub fn resize(&self, pane_id: &str, cols: u16, rows: u16) -> Result<(), String> {
        let live = self.live.lock();
        let entry = live.get(pane_id).ok_or("that pane is no longer open")?;
        entry
            .pair
            .master
            .resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
            .map_err(|e| format!("could not resize: {e}"))
    }

    pub fn close(&self, pane_id: &str) {
        self.live.lock().remove(pane_id);
    }
}

/// The CLIs, run bare and interactively — their own TUIs, their own permissions.
fn command_for(kind: &str) -> (String, Vec<String>) {
    match kind {
        "claude" => ("claude".into(), vec![]),
        "codex" => ("codex".into(), vec![]),
        // Agy's headless mode is triggered by a non-TTY stdin; a pane gives it a
        // real TTY, so no flag is needed and none is passed.
        "agy" => ("agy".into(), vec![]),
        // -l so the shell reads the user's profile.
        _ => (login_shell(), vec!["-l".into()]),
    }
}

/// Facts a CLI in a pane can read to tell where it is running.
fn pane_env(pane_id: &str, kind: &str) -> Vec<(String, String)> {
    vec![
        ("PARLEY_PANE".into(), "1".into()),
        ("PARLEY_PANE_ID".into(), pane_id.to_string()),
        ("PARLEY_PANE_KIND".into(), kind.to_string()),
        ("PARLEY_APP_PID".into(), std::process::id().to_string()),
    ]
}

fn login_shell() -> String {
    std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into())
}

/// Resolves against PATH, so "not installed" is distinguishable from a broken
/// pty. `PATH` here is the one `resolve_login_path` put back.
fn which(file: &str) -> Option<String> {
    if file.contains('/') {
        return std::path::Path::new(file).exists().then(|| file.to_string());
    }
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths).find_map(|dir| {
            let candidate = dir.join(file);
            candidate.is_file().then(|| candidate.to_string_lossy().to_string())
        })
    })
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn new_id() -> String {
    // Good enough for a process-local handle, and no dependency for it.
    format!("{:x}-{:x}", now_ms(), std::process::id() ^ rand_bits())
}

fn rand_bits() -> u32 {
    use std::hash::{BuildHasher, Hasher};
    std::collections::hash_map::RandomState::new().build_hasher().finish() as u32
}
