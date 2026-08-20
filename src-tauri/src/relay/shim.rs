//! The `parley` command a pane finds on its PATH.
//!
//! Every CLI in a pane has a shell and nothing else in common — Claude Code,
//! Codex and Antigravity share no tool protocol — so the capability is a
//! script, which all three can already run. Discovery is the shim being on
//! PATH plus a line in AGENTS.md, the same route that taught them to check
//! `PARLEY_PANE`.
//!
//! `sh`, not `bash` or `node`: it has to run under whatever a CLI shells out
//! with. Text is piped to curl as a raw body rather than quoted into JSON,
//! because escaping a model's output — quotes, backticks, newlines — from a
//! shell script is a bug in waiting.
//!
//! This is the twin of `SHIM` in `src/main/relay/shim.ts`, and the two have to
//! agree: an agent writes `parley relay codex …` once and must not care which
//! runtime it happens to be sitting in. The test below pins the wire contract
//! both copies share, so a change to one of them fails here rather than in a
//! pane at midnight.

use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

pub const SHIM: &str = r##"#!/bin/sh
# Parley relay. Hands text to another pane in the same Parley window.
#
#   parley relay codex "have a look at this"
#   some-command | parley relay claude
#
# The text is pasted into that pane's prompt and NOT sent. A person there
# presses Enter. That is deliberate: nothing another model wrote should be
# able to run on its own.
set -eu

if [ "${1:-}" != "relay" ]; then
  echo "usage: parley relay <pane> [text...]   (text may also come on stdin)" >&2
  exit 2
fi
if [ -z "${PARLEY_RELAY_URL:-}" ]; then
  echo "not running inside a Parley pane" >&2
  exit 2
fi
target="${2:-}"
if [ -z "$target" ]; then
  echo "name a pane, for example: parley relay codex \"hello\"" >&2
  exit 2
fi
shift 2

if [ "$#" -eq 0 ] && [ -t 0 ]; then
  # No message and nothing piped in. Reading stdin here would wait forever on
  # a terminal that is never going to type anything.
  echo "nothing to relay: give the text as arguments or pipe it in" >&2
  exit 2
fi

if [ "$#" -gt 0 ]; then
  printf '%s' "$*"
else
  cat
fi | curl -sS --fail-with-body -X POST \
  -H "Authorization: Bearer ${PARLEY_RELAY_TOKEN:-}" \
  -H "X-Parley-To: $target" \
  -H "Content-Type: text/plain" \
  --data-binary @- \
  "${PARLEY_RELAY_URL}/relay"
"##;

/// Writes the shim and returns the directory to put on a pane's PATH.
pub fn install(app_data_dir: &Path) -> io::Result<PathBuf> {
    let bin_dir = app_data_dir.join("bin");
    fs::create_dir_all(&bin_dir)?;
    let path = bin_dir.join("parley");
    fs::write(&path, SHIM)?;
    // Rewritten and re-marked on every launch: a stale shim from an older
    // build would talk a protocol this one no longer serves.
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755))?;
    Ok(bin_dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn speaks_the_wire_contract_the_server_answers() {
        // The sender is derived from the credential now, so the shim must not
        // send a name at all — a header the server ignores is a header the
        // next reader will think still means something.
        assert!(
            !SHIM.contains("X-Parley-From"),
            "the shim still claims a sender; the relay derives it from the token",
        );
        for required in [
            "Authorization: Bearer ${PARLEY_RELAY_TOKEN:-}",
            "X-Parley-To: $target",
            "${PARLEY_RELAY_URL}/relay",
            "--data-binary @-",
        ] {
            assert!(SHIM.contains(required), "the shim no longer sends: {required}");
        }
    }

    #[test]
    fn refuses_outside_a_pane_rather_than_posting_nowhere() {
        assert!(SHIM.contains("not running inside a Parley pane"));
    }

    #[test]
    fn is_written_executable() {
        let dir = std::env::temp_dir().join(format!("parley-shim-{}", std::process::id()));
        let bin = install(&dir).expect("install");
        let mode = fs::metadata(bin.join("parley")).expect("stat").permissions().mode();
        assert_eq!(mode & 0o777, 0o755);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_reinstall_replaces_a_stale_shim() {
        let dir = std::env::temp_dir().join(format!("parley-shim-stale-{}", std::process::id()));
        let bin = install(&dir).expect("install");
        fs::write(bin.join("parley"), "#!/bin/sh\nexit 9\n").expect("stale");
        install(&dir).expect("reinstall");
        assert_eq!(fs::read_to_string(bin.join("parley")).expect("read"), SHIM);
        let _ = fs::remove_dir_all(&dir);
    }
}
