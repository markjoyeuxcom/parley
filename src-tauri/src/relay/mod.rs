//! The relay, on Tauri.
//!
//! A CLI inside a pane has a shell and nothing else — Claude Code, Codex and
//! Antigravity share no tool protocol — so the capability is an HTTP endpoint
//! on loopback plus a one-line shim on PATH, which all three can already call.
//!
//! This is a port of `src/main/relay/`, and it is a port rather than a
//! reimplementation on purpose: the rules about who may relay to whom, and
//! what happens to the text when it lands, were each argued into place by a
//! defect. The comments that came with them are worth more than the code.
//!
//! The one property the whole feature rests on: relayed text is pasted and NOT
//! submitted. An agent that could press Enter in another agent's session would
//! be a prompt-injection channel with a command runner on the far end.

pub mod handle;
pub mod server;
pub mod shim;
pub mod target;
