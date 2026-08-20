//! Which pane an agent meant.
//!
//! A CLI asked to "say hello to codex" knows the word `codex` and nothing else
//! — not pane ids, not what else is open. So a vendor name resolves when it is
//! unambiguous, and a pane id always works.
//!
//! Every refusal names what IS available. The caller is a language model
//! reading a one-line error in a terminal, and "no such pane" tells it nothing
//! it can act on; "codex, agy" tells it what to try instead.

use crate::pty::Pane;

#[derive(Debug, PartialEq, Eq)]
pub enum RelayTarget {
    Found(String),
    Refused(String),
}

/// A shell has no conversation to receive one; a room takes turns, not keys.
fn receives(pane: &Pane) -> bool {
    pane.kind != "shell"
}

pub fn resolve_relay_target(panes: &[Pane], target: &str, from_pane_id: &str) -> RelayTarget {
    let trimmed = target.trim();
    let wanted = trimmed.to_lowercase();
    if wanted.is_empty() {
        return RelayTarget::Refused("name a pane to relay to".into());
    }

    let open: Vec<&Pane> = panes
        .iter()
        .filter(|p| receives(p) && p.id != from_pane_id)
        .collect();

    let mut available: Vec<String> = Vec::new();
    for pane in open.iter().filter(|p| p.status == "live") {
        if !available.contains(&pane.kind) {
            available.push(pane.kind.clone());
        }
    }
    let naming = if available.is_empty() {
        "nothing else is open".to_string()
    } else {
        available.join(", ")
    };

    if panes
        .iter()
        .any(|p| p.id == from_pane_id && p.kind.to_lowercase() == wanted)
    {
        // Only when the name would ALSO have matched something else does this
        // matter; otherwise the vendor lookup below simply finds nobody.
        if !open.iter().any(|p| p.kind.to_lowercase() == wanted) {
            return RelayTarget::Refused(format!(
                "that is your own pane — relay targets are {naming}"
            ));
        }
    }

    let by_id = panes.iter().find(|p| p.id == wanted || p.id == trimmed);
    let matches: Vec<&Pane> = match by_id {
        Some(pane) => vec![pane],
        None => open
            .iter()
            .copied()
            .filter(|p| p.kind.to_lowercase() == wanted)
            .collect(),
    };

    if matches.is_empty() {
        return RelayTarget::Refused(format!("no pane called \u{201c}{target}\u{201d} — try {naming}"));
    }
    if matches.len() > 1 {
        // Never guess. The sender cannot see which pane it went to, so picking
        // one silently would put somebody's work in front of the wrong agent.
        let ids: Vec<&str> = matches.iter().map(|p| p.id.as_str()).collect();
        return RelayTarget::Refused(format!(
            "{} panes are \u{201c}{}\u{201d} — name one by id: {}",
            matches.len(),
            target,
            ids.join(", ")
        ));
    }

    let found = matches[0];
    if found.id == from_pane_id {
        return RelayTarget::Refused(format!(
            "that is your own pane — relay targets are {naming}"
        ));
    }
    if !receives(found) {
        return RelayTarget::Refused(format!("a {} pane cannot receive a relay", found.kind));
    }
    if found.status == "exited" {
        return RelayTarget::Refused(format!("the {} pane has exited", found.kind));
    }
    if found.status == "starting" {
        // A paste during a CLI's startup, before it has put its terminal in raw
        // mode, is swallowed — and reporting success over it would be a lie.
        return RelayTarget::Refused(format!(
            "the {} pane is still starting — try again in a moment",
            found.kind
        ));
    }
    RelayTarget::Found(found.id.clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pane(id: &str, kind: &str, status: &str) -> Pane {
        Pane {
            id: id.into(),
            kind: kind.into(),
            title: "parley".into(),
            cwd: "/tmp".into(),
            status: status.into(),
            exit_code: None,
            created_at: 0,
        }
    }

    #[test]
    fn resolves_a_vendor_name() {
        let panes = vec![pane("a", "claude", "live"), pane("b", "codex", "live")];
        assert_eq!(
            resolve_relay_target(&panes, "codex", "a"),
            RelayTarget::Found("b".into())
        );
    }

    #[test]
    fn resolves_a_pane_id() {
        let panes = vec![pane("a", "claude", "live"), pane("b", "codex", "live")];
        assert_eq!(
            resolve_relay_target(&panes, "b", "a"),
            RelayTarget::Found("b".into())
        );
    }

    #[test]
    fn refuses_to_guess_between_two_of_a_kind() {
        let panes = vec![
            pane("a", "claude", "live"),
            pane("b", "codex", "live"),
            pane("c", "codex", "live"),
        ];
        let refusal = resolve_relay_target(&panes, "codex", "a");
        match refusal {
            RelayTarget::Refused(msg) => {
                assert!(msg.contains("name one by id"), "{msg}");
                // The ids have to be in it, or the caller cannot act on it.
                assert!(msg.contains('b') && msg.contains('c'), "{msg}");
            }
            other => panic!("expected a refusal, got {other:?}"),
        }
    }

    #[test]
    fn a_shell_cannot_receive() {
        let panes = vec![pane("a", "claude", "live"), pane("b", "shell", "live")];
        match resolve_relay_target(&panes, "b", "a") {
            RelayTarget::Refused(msg) => assert!(msg.contains("cannot receive"), "{msg}"),
            other => panic!("expected a refusal, got {other:?}"),
        }
    }

    #[test]
    fn a_starting_pane_is_refused_rather_than_pasted_into() {
        // The whole reason `starting` exists as a status: a paste before the
        // CLI enters raw mode is swallowed, and saying "delivered" over that
        // is a lie the caller cannot detect.
        let panes = vec![pane("a", "claude", "live"), pane("b", "codex", "starting")];
        match resolve_relay_target(&panes, "codex", "a") {
            RelayTarget::Refused(msg) => assert!(msg.contains("still starting"), "{msg}"),
            other => panic!("expected a refusal, got {other:?}"),
        }
    }

    #[test]
    fn naming_your_own_kind_says_so_and_lists_the_alternatives() {
        let panes = vec![pane("a", "claude", "live"), pane("b", "codex", "live")];
        match resolve_relay_target(&panes, "claude", "a") {
            RelayTarget::Refused(msg) => {
                assert!(msg.contains("your own pane"), "{msg}");
                assert!(msg.contains("codex"), "{msg}");
            }
            other => panic!("expected a refusal, got {other:?}"),
        }
    }

    #[test]
    fn your_own_kind_still_resolves_when_another_pane_shares_it() {
        let panes = vec![
            pane("a", "claude", "live"),
            pane("b", "claude", "live"),
        ];
        assert_eq!(
            resolve_relay_target(&panes, "claude", "a"),
            RelayTarget::Found("b".into())
        );
    }

    #[test]
    fn an_unknown_name_lists_what_is_open() {
        let panes = vec![pane("a", "claude", "live"), pane("b", "codex", "live")];
        match resolve_relay_target(&panes, "gemini", "a") {
            RelayTarget::Refused(msg) => assert!(msg.contains("codex"), "{msg}"),
            other => panic!("expected a refusal, got {other:?}"),
        }
    }
}
