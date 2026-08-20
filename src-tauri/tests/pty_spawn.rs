//! Can a Rust PTY actually start the CLIs this app exists to run?
//!
//! The whole migration turns on this. Everything else in Parley's main process
//! is ordinary logic that moves to Rust mechanically; the PTY layer is the part
//! that has repeatedly broken in ways that look like something else — a missing
//! `spawn-helper`, library validation refusing to exec it under a signed
//! hardened runtime, `launchd` handing the app a PATH with nothing on it.
//!
//! `cargo check` passing says nothing about any of that. These spawn real
//! processes on this machine.

use std::io::{Read, Write};
use std::time::{Duration, Instant};

use portable_pty::{CommandBuilder, NativePtySystem, PtySize, PtySystem};

fn read_for(mut reader: Box<dyn Read + Send>, ms: u64) -> String {
    let deadline = Instant::now() + Duration::from_millis(ms);
    let mut out = String::new();
    let mut buf = [0u8; 4096];
    while Instant::now() < deadline {
        match reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => out.push_str(&String::from_utf8_lossy(&buf[..n])),
            Err(_) => break,
        }
        if !out.is_empty() {
            break;
        }
    }
    out
}

fn spawn(argv: &[&str]) -> String {
    let system = NativePtySystem::default();
    let pair = system
        .openpty(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 })
        .expect("openpty");
    let mut cmd = CommandBuilder::new(argv[0]);
    for a in &argv[1..] {
        cmd.arg(a);
    }
    let mut child = pair.slave.spawn_command(cmd).expect("spawn");
    let reader = pair.master.try_clone_reader().expect("reader");
    let out = read_for(reader, 5_000);
    let _ = child.wait();
    out
}

#[test]
fn opens_a_pty_and_reads_what_the_child_wrote() {
    // The floor. If this fails, nothing above it matters.
    let out = spawn(&["/bin/echo", "parley-pty-works"]);
    assert!(out.contains("parley-pty-works"), "got: {out:?}");
}

#[test]
fn the_child_gets_a_real_terminal() {
    // A TUI behaves completely differently without one, and every CLI this app
    // runs is a TUI. `test -t 0` is the child asking the question itself.
    let out = spawn(&["/bin/sh", "-c", "test -t 0 && echo IS_A_TTY || echo NOT_A_TTY"]);
    assert!(out.contains("IS_A_TTY"), "got: {out:?}");
}

#[test]
fn environment_reaches_the_child() {
    // How a CLI in a pane learns which pane it is, instead of launching a
    // second copy of the app to reach its neighbour.
    let system = NativePtySystem::default();
    let pair = system
        .openpty(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 })
        .expect("openpty");
    let mut cmd = CommandBuilder::new("/bin/sh");
    cmd.arg("-c");
    cmd.arg("printf %s \"$PARLEY_PANE_ID\"");
    cmd.env("PARLEY_PANE_ID", "pane-under-test");
    let mut child = pair.slave.spawn_command(cmd).expect("spawn");
    let out = read_for(pair.master.try_clone_reader().expect("reader"), 5_000);
    let _ = child.wait();
    assert!(out.contains("pane-under-test"), "got: {out:?}");
}

#[test]
#[ignore = "needs the real CLI installed; run with --ignored"]
fn starts_a_real_agent_cli() {
    // The one that matters, and the one no amount of compiling can answer:
    // a signed third-party binary, started from Rust, under this Mac's
    // hardened runtime and code-signing rules.
    let out = spawn(&["claude", "--version"]);
    assert!(!out.trim().is_empty(), "claude produced nothing: {out:?}");
}

/// A keystroke reaches the child and its echo comes back.
///
/// This is the other direction of the terminal, and it is the half that looked
/// fine for longest: output was visibly broken, so it got the attention, while
/// nothing at all proved a typed character ever left the app. `Panes::write`
/// is `write_all` then `flush` on the master — the flush is the part worth
/// pinning, since a buffered writer loses a keystroke silently and a terminal
/// that swallows every third character is a miserable thing to diagnose later.
#[test]
fn a_keystroke_reaches_the_child_and_echoes_back() {
    let system = NativePtySystem::default();
    let pair = system
        .openpty(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 })
        .expect("openpty");
    let mut child = pair.slave.spawn_command(CommandBuilder::new("cat")).expect("spawn cat");

    let mut writer = pair.master.take_writer().expect("writer");
    writer.write_all(b"parley\n").expect("write");
    writer.flush().expect("flush");

    let mut reader = pair.master.try_clone_reader().expect("reader");
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut seen = String::new();
    let mut buf = [0u8; 4096];
    while Instant::now() < deadline && !seen.contains("parley") {
        match reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => seen.push_str(&String::from_utf8_lossy(&buf[..n])),
            Err(_) => break,
        }
    }
    let _ = child.kill();
    let _ = child.wait();

    assert!(seen.contains("parley"), "typed text never came back; saw {seen:?}");
}
