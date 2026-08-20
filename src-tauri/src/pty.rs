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
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

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

/// An interactive CLI's first bytes are its splash screen, not an input-ready
/// boundary. Claude and Codex both redraw while entering raw mode, and
/// keystrokes written during that window are discarded. A short quiet period
/// is the boundary instead.
const QUIET_MS: u64 = 750;
/// A CLI that never says anything on startup would otherwise stay `starting`
/// for as long as it lived, and a relay to it would be refused forever.
const READY_CEILING: Duration = Duration::from_secs(3);

/// What a pane needs in its environment to reach its neighbours.
///
/// Minted once per run and handed to panes through their environment, never
/// written to disk beside the shim: a token a web page cannot read is the
/// thing that stops a visited site posting to the port.
#[derive(Clone, Default)]
pub struct RelayEnv {
    pub url: String,
    pub token: String,
    pub bin_dir: String,
}

struct Live {
    pane: Pane,
    pair: PtyPair,
    writer: Box<dyn Write + Send>,
}

/// Clone shares the panes rather than copying them — every field is an `Arc`.
/// The relay server runs on its own thread and needs the same map the commands
/// mutate.
#[derive(Default, Clone)]
pub struct Panes {
    live: Arc<Mutex<HashMap<String, Live>>>,
    relay: Arc<Mutex<Option<RelayEnv>>>,
}

impl Panes {
    pub fn list(&self) -> Vec<Pane> {
        self.live.lock().values().map(|l| l.pane.clone()).collect()
    }

    pub fn get(&self, pane_id: &str) -> Option<Pane> {
        self.live.lock().get(pane_id).map(|l| l.pane.clone())
    }

    /// Set once at startup, before any pane exists, so no pane can start
    /// without the environment its neighbours are reachable through.
    pub fn set_relay(&self, env: RelayEnv) {
        *self.relay.lock() = Some(env);
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
        // Without this the pane has no way to reach a neighbour. A Claude Code
        // session asked to "say hello to the agy pane" once launched a SECOND
        // Parley with a remote debugging port and drove it over CDP — building
        // a whole app to reach something it was already sitting beside —
        // because nothing in its environment said otherwise.
        if let Some(relay) = self.relay.lock().clone() {
            cmd.env("PARLEY_RELAY_URL", &relay.url);
            cmd.env("PARLEY_RELAY_TOKEN", &relay.token);
            // Prepended, so `parley` resolves to the shim rather than to
            // anything of that name the user happens to have installed.
            let inherited = std::env::var("PATH").unwrap_or_default();
            cmd.env("PATH", format!("{}:{}", relay.bin_dir, inherited));
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
            title: pane_title(kind, cwd),
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
        // Milliseconds of the last output, or 0 for a pane that has not spoken.
        let last_output = Arc::new(AtomicU64::new(0));
        let observed = Arc::clone(&last_output);
        std::thread::spawn(move || {
            let mut buffer = [0u8; 8 * 1024];
            loop {
                match reader.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(n) => {
                        observed.store(now_ms() as u64, Ordering::Relaxed);
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

        self.watch_for_ready(app, &id, last_output);
        Ok(pane)
    }

    /// Moves a pane from `starting` to `live` once it looks able to read input.
    ///
    /// This matters more than it sounds: `starting` is the status the relay
    /// refuses to paste into, because a paste before a CLI enters raw mode is
    /// swallowed and reporting success over that is a lie. Rust panes had no
    /// route out of `starting` at all, so every relay to one would have been
    /// refused forever — the port carried the PTY across and left the state
    /// machine behind.
    fn watch_for_ready(&self, app: &AppHandle, pane_id: &str, last_output: Arc<AtomicU64>) {
        let live = Arc::clone(&self.live);
        let handle = app.clone();
        let pane_id = pane_id.to_string();
        std::thread::spawn(move || {
            let start = Instant::now();
            loop {
                std::thread::sleep(Duration::from_millis(50));
                if !live.lock().contains_key(&pane_id) {
                    return; // Closed before it ever settled.
                }
                let last = last_output.load(Ordering::Relaxed);
                let quiet = last != 0 && now_ms() as u64 >= last + QUIET_MS;
                if quiet || start.elapsed() >= READY_CEILING {
                    break;
                }
            }
            let announced = {
                let mut map = live.lock();
                match map.get_mut(&pane_id) {
                    Some(entry) if entry.pane.status == "starting" => {
                        entry.pane.status = "live".into();
                        true
                    }
                    _ => false,
                }
            };
            if announced {
                let _ = handle.emit("pane:status", (pane_id, "live", Option::<i32>::None));
            }
        });
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

    /// Hands a pane pasted content, with no Enter after it.
    ///
    /// What makes an agent-initiated relay safe to have at all: the text
    /// arrives in the other CLI's prompt where it can be read and edited, and
    /// a person commits it. Nothing another model wrote executes on its own —
    /// the worst case is unwanted text sitting in an input box.
    ///
    /// There is deliberately no submitting twin of this on `Panes`. In the
    /// Electron build both existed and only a comment separated them; the
    /// safety of the feature should not rest on picking the right method name.
    pub fn paste_only(&self, pane_id: &str, text: &str) -> Result<(), String> {
        self.write(pane_id, &bracketed(text))
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

/// What a pane calls itself — and, through the relay, what it is quoted as.
///
/// The same shape as the Electron build's, which is not cosmetic: this string
/// is the attribution on relayed text. A title of just the folder would have
/// every pane in a window quoted identically — "parley said:" from claude,
/// codex and agy alike — which is worse than no attribution, because it reads
/// as though it means something.
fn pane_title(kind: &str, cwd: &str) -> String {
    let where_ = shorten_path(cwd);
    if kind == "shell" {
        where_
    } else {
        format!("{kind} — {where_}")
    }
}

/// The last two path segments, with `$HOME` as `~`. A pane header is narrow and
/// an absolute path in it is mostly prefix.
fn shorten_path(dir: &str) -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    let with_tilde = if !home.is_empty() && dir.starts_with(&home) {
        format!("~{}", &dir[home.len()..])
    } else {
        dir.to_string()
    };
    let parts: Vec<&str> = with_tilde.split('/').filter(|p| !p.is_empty()).collect();
    if parts.len() <= 2 {
        return with_tilde;
    }
    format!("{}/{}", parts[parts.len() - 2], parts[parts.len() - 1])
}

/// Wraps text in the terminal's own paste markers.
///
/// The relay carries what one CLI said into another — code blocks, file
/// listings, numbered findings — and neither obvious delivery works. Flattening
/// newlines to spaces is right for a one-line instruction and ruins a diff.
/// Writing the newlines raw is worse: a TUI reads the first one as Enter and
/// submits a message cut off after its opening line.
///
/// A CR inside the payload IS Enter to the receiving TUI, and content copied
/// out of a terminal is full of them. The markers go too — the payload is
/// another model's output, and a closing marker inside it would end paste mode
/// early, with everything after it read as typing in a CLI that runs commands.
/// Relayed content does not get to decide where the paste ends.
fn bracketed(text: &str) -> String {
    let body = text
        .replace("\r\n", "\n")
        .replace('\r', "\n")
        .replace("\u{1b}[200~", "")
        .replace("\u{1b}[201~", "");
    format!("\u{1b}[200~{body}\u{1b}[201~")
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

#[cfg(test)]
mod tests {
    use super::bracketed;

    const START: &str = "\u{1b}[200~";
    const END: &str = "\u{1b}[201~";

    #[test]
    fn wraps_the_payload_in_paste_markers() {
        let out = bracketed("hello");
        assert_eq!(out, format!("{START}hello{END}"));
    }

    #[test]
    fn newlines_survive_but_carriage_returns_do_not() {
        // A CR reaches the receiving TUI as Enter, which submits a relayed
        // message cut off at its first line.
        let out = bracketed("one\r\ntwo\rthree\nfour");
        assert!(!out.contains('\r'), "{out:?}");
        assert!(out.contains("one\ntwo\nthree\nfour"), "{out:?}");
    }

    #[test]
    fn a_marker_inside_the_payload_cannot_end_the_paste_early() {
        // The payload is another model's output. If it could close paste mode,
        // everything after it would be read as typing by a CLI that runs
        // commands.
        let hostile = format!("innocent{END}rm -rf /");
        let out = bracketed(&hostile);
        assert_eq!(out.matches(END).count(), 1, "{out:?}");
        assert!(out.ends_with(END), "{out:?}");
        assert_eq!(out.matches(START).count(), 1, "{out:?}");
    }

    #[test]
    fn an_opening_marker_inside_the_payload_goes_too() {
        let out = bracketed(&format!("a{START}b"));
        assert_eq!(out.matches(START).count(), 1, "{out:?}");
    }
}

#[cfg(test)]
mod title_tests {
    use super::{pane_title, shorten_path};

    #[test]
    fn a_shell_is_named_for_where_it_is() {
        assert_eq!(pane_title("shell", "/a/b/repo"), "b/repo");
    }

    #[test]
    fn an_agent_pane_carries_its_vendor() {
        // This string is the attribution on relayed text. Without the vendor
        // in it, claude, codex and agy in one folder are all quoted the same.
        assert_eq!(pane_title("codex", "/a/b/repo"), "codex — b/repo");
        assert_ne!(pane_title("codex", "/a/b/repo"), pane_title("agy", "/a/b/repo"));
    }

    #[test]
    fn a_short_path_is_left_alone() {
        assert_eq!(shorten_path("/tmp"), "/tmp");
    }
}
