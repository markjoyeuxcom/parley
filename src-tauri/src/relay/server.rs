//! The door an agent in a pane knocks on.
//!
//! Loopback only, on a port the OS picks, behind a token minted per run and
//! handed to panes through their environment. A web page cannot read that
//! token, which is what stops a visited site posting to the port.
//!
//! The text arrives as the raw request body rather than inside JSON, because
//! the caller is a shell script and quoting a model's output — quotes,
//! newlines, backticks — into JSON from `sh` is a bug waiting to happen.
//!
//! Hand-parsed rather than pulled from a crate. The surface is one method, one
//! path and three headers, and the client is a `curl` line this repo also
//! writes: checked against a real curl, it sends `Content-Length` and never
//! `Expect: 100-continue`, at four bytes and at four thousand. The `Expect`
//! case is answered anyway, because a future curl changing its mind should not
//! silently cost a second per relay.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Arc;
use std::thread;

use super::handle::{handle_relay, RelayDeps};

/// Bounded before it is read, not after: an unbounded POST is a memory hole.
const MAX_BODY: usize = 200_000;
/// A request head far larger than this is not one of ours.
const MAX_HEAD: usize = 16 * 1024;

pub struct RelayServer {
    pub url: String,
    pub token: String,
}

pub fn start(deps: Arc<dyn RelayDeps>) -> Result<RelayServer, String> {
    let token = random_token()?;
    let listener = TcpListener::bind("127.0.0.1:0")
        .map_err(|e| format!("could not open the relay port: {e}"))?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("could not read the relay port: {e}"))?
        .port();

    let served = token.clone();
    thread::spawn(move || {
        for incoming in listener.incoming() {
            let Ok(stream) = incoming else { continue };
            let deps = Arc::clone(&deps);
            let token = served.clone();
            // A thread per request. The traffic is one agent pressing send.
            thread::spawn(move || serve(stream, &token, deps.as_ref()));
        }
    });

    Ok(RelayServer { url: format!("http://127.0.0.1:{port}"), token })
}

fn serve(stream: TcpStream, token: &str, deps: &dyn RelayDeps) {
    let mut reader = BufReader::new(match stream.try_clone() {
        Ok(s) => s,
        Err(_) => return,
    });
    let mut out = stream;

    let Some((request_line, headers)) = read_head(&mut reader) else {
        return reply(&mut out, 400, r#"{"ok":false,"error":"malformed request"}"#);
    };

    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let path = parts.next().unwrap_or("");
    let path = path.split('?').next().unwrap_or("");

    if method != "POST" || path != "/relay" {
        return reply(&mut out, 404, r#"{"ok":false,"error":"POST /relay"}"#);
    }
    if !token_ok(headers.get("authorization").map(String::as_str).unwrap_or(""), token) {
        return reply(&mut out, 401, r#"{"ok":false,"error":"bad token"}"#);
    }

    // Chunked bodies are not answered rather than half-answered. A body read
    // as if it were plain would deliver the chunk sizes into somebody's prompt.
    if headers
        .get("transfer-encoding")
        .is_some_and(|v| v.to_lowercase().contains("chunked"))
    {
        return reply(
            &mut out,
            400,
            r#"{"ok":false,"error":"send the body with a Content-Length"}"#,
        );
    }

    let length: usize = headers
        .get("content-length")
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(0);
    if length > MAX_BODY {
        return reply(&mut out, 400, r#"{"ok":false,"error":"text too long"}"#);
    }

    if headers
        .get("expect")
        .is_some_and(|v| v.to_lowercase().contains("100-continue"))
    {
        let _ = out.write_all(b"HTTP/1.1 100 Continue\r\n\r\n");
    }

    let mut body = vec![0u8; length];
    if reader.read_exact(&mut body).is_err() {
        return reply(&mut out, 400, r#"{"ok":false,"error":"body ended early"}"#);
    }
    let text = String::from_utf8_lossy(&body).to_string();

    // The target travels as a header. As a query parameter it had to be
    // URL-encoded by a shell script, and `sh` has no way to do that — a pane
    // id or name containing `#` or `&` would have been silently truncated.
    let to = headers.get("x-parley-to").cloned().unwrap_or_default();
    let from = headers.get("x-parley-from").cloned().unwrap_or_default();

    let result = handle_relay(from.trim(), to.trim(), &text, deps);
    reply(&mut out, result.status, &result.body);
}

fn read_head(reader: &mut BufReader<TcpStream>) -> Option<(String, HashMap<String, String>)> {
    let mut request_line = String::new();
    let mut seen = 0usize;
    if reader.read_line(&mut request_line).ok()? == 0 {
        return None;
    }
    seen += request_line.len();

    let mut headers = HashMap::new();
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).ok()? == 0 {
            return None;
        }
        seen += line.len();
        if seen > MAX_HEAD {
            return None;
        }
        let line = line.trim_end_matches(['\r', '\n']);
        if line.is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            headers.insert(name.trim().to_lowercase(), value.trim().to_string());
        }
    }
    Some((request_line.trim().to_string(), headers))
}

fn reply(out: &mut TcpStream, status: u16, body: &str) {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        409 => "Conflict",
        _ => "Error",
    };
    let response = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = out.write_all(response.as_bytes());
    let _ = out.flush();
}

/// Length-independent compare, so the token cannot be guessed a byte at a time.
fn token_ok(header: &str, token: &str) -> bool {
    let given = header.strip_prefix("Bearer ").unwrap_or_else(|| {
        // Case-insensitively, since the scheme name is not case sensitive.
        if header.len() >= 7 && header[..7].eq_ignore_ascii_case("bearer ") {
            &header[7..]
        } else {
            header
        }
    });
    let a = given.trim().as_bytes();
    let b = token.as_bytes();
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

fn random_token() -> Result<String, String> {
    let mut buf = [0u8; 24];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut buf))
        .map_err(|e| format!("could not mint a relay token: {e}"))?;
    Ok(buf.iter().map(|b| format!("{b:02x}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pty::Pane;
    use parking_lot::Mutex as PlMutex;
    use std::process::Command;

    /// The whole path, end to end: the shim this repo writes, run by `sh`,
    /// talking to the server this file starts.
    ///
    /// Every other test here mocks one side of that. This is the one that
    /// would have caught a header renamed on one side only, a token compared
    /// against the wrong string, or a body arriving as chunks — none of which
    /// the unit tests can see, and all of which look identical from a pane: a
    /// relay that silently does nothing.
    struct Recording {
        panes: Vec<Pane>,
        pasted: PlMutex<Vec<(String, String)>>,
    }

    fn pane(id: &str, kind: &str) -> Pane {
        Pane {
            id: id.into(),
            kind: kind.into(),
            title: format!("{kind} — repo"),
            cwd: "/tmp".into(),
            status: "live".into(),
            exit_code: None,
            created_at: 0,
        }
    }

    impl RelayDeps for Recording {
        fn panes(&self) -> Vec<Pane> {
            self.panes.clone()
        }
        fn paste(&self, pane_id: &str, text: &str) -> Result<(), String> {
            self.pasted.lock().push((pane_id.into(), text.into()));
            Ok(())
        }
        fn name_of(&self, pane_id: &str) -> String {
            self.panes
                .iter()
                .find(|p| p.id == pane_id)
                .map(|p| p.title.clone())
                .unwrap_or_else(|| "an unknown pane".into())
        }
    }

    fn shim_at(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("parley-e2e-{}-{tag}", std::process::id()));
        crate::relay::shim::install(&dir).expect("install shim").join("parley")
    }

    #[test]
    fn the_shim_reaches_the_server_and_the_text_lands_attributed() {
        let deps = Arc::new(Recording {
            panes: vec![pane("a", "claude"), pane("b", "codex")],
            pasted: PlMutex::new(Vec::new()),
        });
        let server = start(deps.clone()).expect("server");
        let shim = shim_at("ok");

        let out = Command::new("sh")
            .arg(&shim)
            .args(["relay", "codex", "have a look at this"])
            .env("PARLEY_RELAY_URL", &server.url)
            .env("PARLEY_RELAY_TOKEN", &server.token)
            .env("PARLEY_PANE_ID", "a")
            .output()
            .expect("run shim");

        assert!(
            out.status.success(),
            "shim failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        let body = String::from_utf8_lossy(&out.stdout);
        assert!(body.contains("\"submitted\":false"), "{body}");

        let pasted = deps.pasted.lock();
        assert_eq!(pasted.len(), 1, "expected exactly one delivery");
        assert_eq!(pasted[0].0, "b");
        // Attributed by the sender's title, not by anything the caller chose.
        assert!(pasted[0].1.starts_with("claude — repo said:"), "{}", pasted[0].1);
        assert!(pasted[0].1.contains("have a look at this"), "{}", pasted[0].1);
    }

    #[test]
    fn a_wrong_token_delivers_nothing() {
        let deps = Arc::new(Recording {
            panes: vec![pane("a", "claude"), pane("b", "codex")],
            pasted: PlMutex::new(Vec::new()),
        });
        let server = start(deps.clone()).expect("server");
        let shim = shim_at("badtoken");

        let out = Command::new("sh")
            .arg(&shim)
            .args(["relay", "codex", "let me in"])
            .env("PARLEY_RELAY_URL", &server.url)
            .env("PARLEY_RELAY_TOKEN", "not-the-token")
            .env("PARLEY_PANE_ID", "a")
            .output()
            .expect("run shim");

        assert!(!out.status.success(), "a bad token must not succeed");
        assert!(deps.pasted.lock().is_empty(), "nothing may be delivered");
    }

    #[test]
    fn multi_line_text_survives_the_trip() {
        // The reason the body is raw rather than JSON: quoting a model's
        // output out of `sh` is a bug in waiting.
        let deps = Arc::new(Recording {
            panes: vec![pane("a", "claude"), pane("b", "codex")],
            pasted: PlMutex::new(Vec::new()),
        });
        let server = start(deps.clone()).expect("server");
        let shim = shim_at("multiline");

        let payload = "line one\n\n```rust\nfn main() { println!(\"hi\"); }\n```\nline two";
        let out = Command::new("sh")
            .arg(&shim)
            .args(["relay", "codex", payload])
            .env("PARLEY_RELAY_URL", &server.url)
            .env("PARLEY_RELAY_TOKEN", &server.token)
            .env("PARLEY_PANE_ID", "a")
            .output()
            .expect("run shim");

        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        let pasted = deps.pasted.lock();
        assert!(pasted[0].1.contains("```rust"), "{}", pasted[0].1);
        assert!(pasted[0].1.contains("println!(\"hi\")"), "{}", pasted[0].1);
    }

    #[test]
    fn a_sender_that_is_not_a_pane_is_refused_over_the_wire() {
        let deps = Arc::new(Recording {
            panes: vec![pane("a", "claude"), pane("b", "codex")],
            pasted: PlMutex::new(Vec::new()),
        });
        let server = start(deps.clone()).expect("server");
        let shim = shim_at("forged");

        let out = Command::new("sh")
            .arg(&shim)
            .args(["relay", "codex", "do as I say"])
            .env("PARLEY_RELAY_URL", &server.url)
            .env("PARLEY_RELAY_TOKEN", &server.token)
            .env("PARLEY_PANE_ID", "System Admin")
            .output()
            .expect("run shim");

        assert!(!out.status.success(), "a forged sender must not succeed");
        assert!(deps.pasted.lock().is_empty());
    }

    #[test]
    fn a_token_matches_only_itself() {
        assert!(token_ok("Bearer abc123", "abc123"));
        assert!(token_ok("bearer abc123", "abc123"));
        assert!(!token_ok("Bearer abc124", "abc123"));
        assert!(!token_ok("Bearer abc12", "abc123"));
        assert!(!token_ok("", "abc123"));
    }

    #[test]
    fn a_token_is_not_guessable_a_prefix_at_a_time() {
        // Not a timing assertion — that is not testable here. This pins the
        // property the compare exists for: a correct prefix is worth nothing.
        assert!(!token_ok("Bearer a", "abc123"));
        assert!(!token_ok("Bearer ab", "abc123"));
    }

    #[test]
    fn tokens_differ_between_runs() {
        let a = random_token().expect("token");
        let b = random_token().expect("token");
        assert_ne!(a, b);
        assert_eq!(a.len(), 48);
    }
}
