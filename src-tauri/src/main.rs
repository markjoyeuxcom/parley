// Parley, on Tauri.
//
// The renderer talks to exactly one seam — `window.parley` in the Electron
// build — and the entire main process sits behind it. That is what makes this
// migration tractable rather than a rewrite of everything at once: the seam is
// reimplemented command by command, and the React app above it does not care
// which runtime is answering.
//
// Panes come first because they decide whether the migration is possible at
// all. Everything else (the store, rooms, the relay) is ordinary logic that
// moves mechanically; a PTY that cannot spawn a signed CLI under a hardened
// runtime would end the exercise.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod pty;
mod relay;

use std::sync::Arc;

use pty::{Pane, Panes, RelayEnv};
use relay::handle::RelayDeps;
use tauri::{AppHandle, Manager, State};

/// The relay endpoint's view of the panes: list them, name one, paste into one.
///
/// Deliberately this narrow. The endpoint reaches a pty through exactly these
/// three methods and no others — in particular through no submitting write,
/// because the safety of the entire feature is that relayed text waits for a
/// person to press Enter.
struct PaneRelay {
    panes: Panes,
}

impl RelayDeps for PaneRelay {
    fn panes(&self) -> Vec<Pane> {
        self.panes.list()
    }

    fn pane_for_token(&self, token: &str) -> Option<String> {
        self.panes.pane_for_token(token)
    }

    fn paste(&self, pane_id: &str, text: &str) -> Result<(), String> {
        self.panes.paste_only(pane_id, text)
    }

    fn name_of(&self, pane_id: &str) -> String {
        // No fallback to the id. Falling through to whatever string arrived is
        // how a forged `X-Parley-From` became "System Admin said:"; a sender
        // that is not a pane is refused before this ever runs, and anything
        // that still slips through gets a name claiming nothing.
        match self.panes.get(pane_id) {
            Some(pane) if !pane.title.trim().is_empty() => pane.title.trim().to_string(),
            Some(pane) => pane.kind,
            None => "an unknown pane".into(),
        }
    }
}

#[tauri::command]
fn pane_open(
    app: AppHandle,
    panes: State<'_, Panes>,
    kind: String,
    cwd: String,
    cols: u16,
    rows: u16,
) -> Result<Pane, String> {
    panes.open(&app, &kind, &cwd, cols, rows)
}

#[tauri::command]
fn pane_write(panes: State<'_, Panes>, pane_id: String, data: String) -> Result<(), String> {
    panes.write(&pane_id, &data)
}

#[tauri::command]
fn pane_resize(panes: State<'_, Panes>, pane_id: String, cols: u16, rows: u16) -> Result<(), String> {
    panes.resize(&pane_id, cols, rows)
}

#[tauri::command]
fn pane_flow(panes: State<'_, Panes>, pane_id: String, paused: bool) -> Result<(), String> {
    panes.set_flow(&pane_id, paused)
}

#[tauri::command]
fn pane_close(panes: State<'_, Panes>, pane_id: String) {
    panes.close(&pane_id)
}

#[tauri::command]
fn pane_list(panes: State<'_, Panes>) -> Vec<Pane> {
    panes.list()
}

/// Where a pane opens when nobody has chosen a folder.
///
/// The Tauri shell had the author's own checkout written into it, which worked
/// on exactly one machine. Choosing a folder is a command that has not been
/// migrated yet; until it is, home is the default.
///
/// Not the working directory, which was the first thing tried: `tauri dev`
/// runs the binary from src-tauri and a bundled app is launched from `/`, so
/// it means something different every way the app can start. Home is the same
/// in all of them, and it is where a person would begin anyway.
#[tauri::command]
fn default_cwd() -> String {
    std::env::var("HOME").unwrap_or_else(|_| "/".into())
}

/// A GUI app is started by `launchd` with a minimal PATH, so every CLI the user
/// installed is invisible. Asked of the login shell once, at startup, before
/// anything is spawned. One fixed literal command with nothing interpolated —
/// the single deliberate exception to the no-shell rule, same as the Electron
/// build's.
fn resolve_login_path() {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
    if let Ok(out) = std::process::Command::new(&shell)
        .args(["-lic", "printf '__PARLEY_PATH__%s__END__' \"$PATH\""])
        .output()
    {
        let text = String::from_utf8_lossy(&out.stdout);
        if let Some(rest) = text.split("__PARLEY_PATH__").nth(1) {
            if let Some(path) = rest.split("__END__").next() {
                if !path.trim().is_empty() {
                    std::env::set_var("PATH", path.trim());
                }
            }
        }
    }
}

/// Puts the shim on disk and opens the relay port, then tells the panes how to
/// reach it. Before any pane exists, so none can start without it — a pane
/// spawned first would hold no token and have no `parley` on its PATH, and
/// would look exactly like a relay that is broken.
fn start_relay(app: &tauri::App, panes: &Panes) -> Result<String, String> {
    let data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("no application data directory: {e}"))?;
    let bin_dir = relay::shim::install(&data_dir)
        .map_err(|e| format!("could not install the relay shim: {e}"))?;
    let server = relay::server::start(Arc::new(PaneRelay { panes: panes.clone() }))?;
    panes.set_relay(RelayEnv {
        url: server.url.clone(),
        bin_dir: bin_dir.to_string_lossy().to_string(),
    });
    Ok(server.url)
}

fn main() {
    resolve_login_path();

    tauri::Builder::default()
        .manage(Panes::default())
        .setup(|app| {
            let panes = app.state::<Panes>().inner().clone();
            match start_relay(app, &panes) {
                Ok(url) => eprintln!("parley: relay listening on {url}"),
                // Not fatal. Panes and their CLIs are the app; the relay is a
                // capability they can do without, and killing the window over
                // it would trade a missing feature for no app at all.
                Err(err) => eprintln!("parley: the relay is not available — {err}"),
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            pane_open,
            pane_write,
            pane_resize,
            pane_close,
            pane_flow,
            pane_list,
            default_cwd
        ])
        .run(tauri::generate_context!())
        .expect("failed to start Parley");
}
