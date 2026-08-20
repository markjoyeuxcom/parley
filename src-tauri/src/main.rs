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

use pty::{Pane, Panes};
use tauri::{AppHandle, State};

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
fn pane_close(panes: State<'_, Panes>, pane_id: String) {
    panes.close(&pane_id)
}

#[tauri::command]
fn pane_list(panes: State<'_, Panes>) -> Vec<Pane> {
    panes.list()
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

fn main() {
    resolve_login_path();

    tauri::Builder::default()
        .manage(Panes::default())
        .invoke_handler(tauri::generate_handler![
            pane_open,
            pane_write,
            pane_resize,
            pane_close,
            pane_list
        ])
        .run(tauri::generate_context!())
        .expect("failed to start Parley");
}
