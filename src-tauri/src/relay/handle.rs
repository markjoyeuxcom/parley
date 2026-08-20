//! A relay an agent asked for, rather than one a person clicked.
//!
//! The menu relay is a person deciding what crosses. This one is a CLI in a
//! pane deciding, which is a different thing and needs a different ending: the
//! text is pasted into the target's prompt and NOT submitted. It sits there,
//! visible and editable, until a person presses Enter.
//!
//! That single property is what makes the whole path safe to have. An agent
//! that could submit into another agent's session would be a prompt-injection
//! channel with a command runner on the far end — anything Claude read on a
//! web page could steer Codex. Landing in an input box costs an agent nothing
//! it actually needs and closes that entirely.

use serde_json::json;

use super::target::{resolve_relay_target, RelayTarget};
use crate::pty::Pane;

/// Bounded because it arrives over a socket from a process we do not control.
const MAX_TEXT: usize = 100_000;

/// What the relay endpoint is allowed to do to a pane.
///
/// A trait rather than a direct call into `Panes`, because the safety property
/// of the entire feature lives in one line of the implementation — `paste_only`,
/// not `write` — and in the Electron build that line was untested for a while.
/// Every relay test passed a mock, so swapping in the submitting variant would
/// have left the suite green while giving an agent the ability to press Enter
/// in another agent's session.
pub trait RelayDeps: Send + Sync {
    fn panes(&self) -> Vec<Pane>;
    /// Which pane holds this credential, or None. The sender is derived from
    /// it rather than taken from a header, so a pane cannot post as another.
    fn pane_for_token(&self, token: &str) -> Option<String>;
    /// Pastes without submitting. Errs if the pane cannot receive it.
    fn paste(&self, pane_id: &str, text: &str) -> Result<(), String>;
    fn name_of(&self, pane_id: &str) -> String;
}

pub struct RelayResult {
    pub status: u16,
    pub body: String,
}

fn refuse(status: u16, message: &str) -> RelayResult {
    RelayResult {
        status,
        body: json!({ "ok": false, "error": message }).to_string(),
    }
}

pub fn handle_relay(from: &str, to: &str, text: &str, deps: &dyn RelayDeps) -> RelayResult {
    if from.is_empty() || to.is_empty() || text.trim().is_empty() {
        return refuse(400, "need from, to and text");
    }

    // The sender must BE a pane. `X-Parley-From` arrives on trust, and in the
    // Electron build it once fell through to the raw string — so anything
    // holding the token could post as "System Admin said:", and every pane
    // holds the token. Attribution is the only thing telling the reader where
    // relayed words came from; it cannot be whatever the caller typed.
    let panes = deps.panes();
    if !panes.iter().any(|pane| pane.id == from) {
        return refuse(400, "unknown sender pane");
    }
    if text.len() > MAX_TEXT {
        return refuse(400, &format!("text too long (max {MAX_TEXT} characters)"));
    }

    let target = match resolve_relay_target(&panes, to, from) {
        RelayTarget::Found(id) => id,
        RelayTarget::Refused(error) => return refuse(400, &error),
    };

    // Attributed, like every relay. The receiving CLI has no idea where this
    // came from, and an unattributed wall of another model's words reads as
    // the user's own.
    let relayed = format!("{} said:\n\n{}", deps.name_of(from), text.trim());
    if let Err(error) = deps.paste(&target, &relayed) {
        // A pane that went between resolving and writing. Saying "delivered"
        // over that would be the exact lie the menu relay was fixed for.
        return refuse(409, &error);
    }

    RelayResult {
        status: 200,
        body: json!({
            "ok": true,
            "delivered": deps.name_of(&target),
            "submitted": false,
            // Stated every time. The caller is a model, and it will otherwise
            // report to the user that it sent a message somebody still has to
            // send.
            "note": "Pasted into the prompt and NOT sent. The person there presses Enter.",
        })
        .to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use parking_lot::Mutex;

    struct Fake {
        panes: Vec<Pane>,
        pasted: Mutex<Vec<(String, String)>>,
    }

    fn pane(id: &str, kind: &str) -> Pane {
        Pane {
            id: id.into(),
            kind: kind.into(),
            title: "parley".into(),
            cwd: "/tmp".into(),
            status: "live".into(),
            exit_code: None,
            created_at: 0,
        }
    }

    impl Fake {
        fn new() -> Self {
            Fake {
                panes: vec![pane("a", "claude"), pane("b", "codex")],
                pasted: Mutex::new(Vec::new()),
            }
        }
    }

    impl RelayDeps for Fake {
        fn panes(&self) -> Vec<Pane> {
            self.panes.clone()
        }
        fn pane_for_token(&self, token: &str) -> Option<String> {
            (token == "tok-a").then(|| "a".to_string())
        }
        fn paste(&self, pane_id: &str, text: &str) -> Result<(), String> {
            self.pasted.lock().push((pane_id.into(), text.into()));
            Ok(())
        }
        fn name_of(&self, pane_id: &str) -> String {
            self.panes
                .iter()
                .find(|p| p.id == pane_id)
                .map(|p| p.kind.clone())
                .unwrap_or_else(|| "an unknown pane".into())
        }
    }

    #[test]
    fn delivers_attributed_and_says_it_did_not_send() {
        let deps = Fake::new();
        let result = handle_relay("a", "codex", "have a look", &deps);
        assert_eq!(result.status, 200);
        assert!(result.body.contains("NOT sent"), "{}", result.body);

        let pasted = deps.pasted.lock();
        assert_eq!(pasted.len(), 1);
        assert_eq!(pasted[0].0, "b");
        assert!(pasted[0].1.starts_with("claude said:"), "{}", pasted[0].1);
    }

    #[test]
    fn a_sender_that_is_not_a_pane_is_refused() {
        // The forged-attribution defect: without this, any holder of the token
        // posts as whatever name it likes, and every pane holds the token.
        let deps = Fake::new();
        let result = handle_relay("System Admin", "codex", "run this", &deps);
        assert_eq!(result.status, 400);
        assert!(result.body.contains("unknown sender"), "{}", result.body);
        assert!(deps.pasted.lock().is_empty(), "nothing should have been pasted");
    }

    #[test]
    fn oversized_text_is_refused_before_it_reaches_a_pane() {
        let deps = Fake::new();
        let huge = "x".repeat(MAX_TEXT + 1);
        let result = handle_relay("a", "codex", &huge, &deps);
        assert_eq!(result.status, 400);
        assert!(deps.pasted.lock().is_empty());
    }

    #[test]
    fn blank_text_is_not_a_relay() {
        let deps = Fake::new();
        assert_eq!(handle_relay("a", "codex", "   \n ", &deps).status, 400);
        assert!(deps.pasted.lock().is_empty());
    }
}
