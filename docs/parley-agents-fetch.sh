#!/bin/sh
# Fetches the inputs for docs/parley-agents.Dockerfile into one folder: the
# Linux arm64 builds of Claude Code, Codex, Agy and Copilot, each checked
# against the checksum its publisher states, and a copy of the Prax app's
# payload. Parley never builds or pulls images; this is the person's own step
# (docs/container-images.md).
#
#   sh docs/parley-agents-fetch.sh <folder>
#   docker build -t parley-agents:local -f docs/parley-agents.Dockerfile <folder>
#
# Nothing is pinned: each run takes Claude's stable release and the latest
# release of the others, and prints the versions it fetched. Needs curl, jq,
# shasum and tar, which macOS has. arm64 only: Docker on Apple Silicon runs
# arm64 Linux.
set -eu

out="${1:?usage: parley-agents-fetch.sh <folder>}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

fail() { printf 'parley-agents-fetch: %s\n' "$1" >&2; exit 1; }

# expect <file> <algorithm bits> <hex digest>
expect() {
  actual="$(shasum -a "$2" "$1" | cut -d' ' -f1)"
  [ "$actual" = "$3" ] || fail "$(basename "$1"): checksum mismatch (expected $3, got $actual)"
}

# place <checked file> <name>: only a checked file reaches <folder>, and it
# replaces whatever had that name, a directory included (mv would otherwise
# move the file into it and succeed).
place() {
  rm -rf "${out:?}/$2"
  mv "$1" "$out/$2"
  chmod 0755 "$out/$2"
}

# The one file a release tarball holds, placed as <folder>/<name>.
unpack_single() {
  rm -rf "$work/unpack" && mkdir "$work/unpack"
  tar -xzf "$1" -C "$work/unpack"
  set -- "$work"/unpack/* "$2"
  [ "$#" -eq 2 ] && [ -f "$1" ] || fail "expected one file in the archive for $2"
  place "$1" "$2"
}

# github_asset <owner/repo> <asset name> <file>: the asset of the latest
# release, checked against the SHA-256 digest GitHub records for it.
github_asset() {
  release="$work/$(echo "$1" | tr / _).json"
  [ -f "$release" ] || curl -fsSL "https://api.github.com/repos/$1/releases/latest" -o "$release"
  digest="$(jq -r --arg n "$2" '.assets[] | select(.name == $n) | .digest // empty' "$release")"
  url="$(jq -r --arg n "$2" '.assets[] | select(.name == $n) | .browser_download_url' "$release")"
  case "$digest" in sha256:*) ;; *) fail "$1 $2: no SHA-256 digest published" ;; esac
  curl -fsSL "$url" -o "$3"
  expect "$3" 256 "${digest#sha256:}"
  printf '%s %s\n' "$1" "$(jq -r .tag_name "$release")"
}

# Claude Code: the stable version, checked against its release manifest.
base=https://downloads.claude.ai/claude-code-releases
version="$(curl -fsSL "$base/stable")"
case "$version" in [0-9]*.[0-9]*.[0-9]*) ;; *) fail "unexpected Claude version: $version" ;; esac
curl -fsSL "$base/$version/manifest.json" -o "$work/claude.json"
sum="$(jq -r '.platforms["linux-arm64"].checksum // empty' "$work/claude.json")"
[ -n "$sum" ] || fail "Claude $version has no linux-arm64 build"
curl -fsSL "$base/$version/linux-arm64/claude" -o "$work/claude"
expect "$work/claude" 256 "$sum"
place "$work/claude" claude
printf 'claude %s\n' "$version"

# Codex, and its code-mode helper for Codex's optional code_mode_host feature.
github_asset openai/codex codex-aarch64-unknown-linux-musl.tar.gz "$work/codex.tar.gz"
unpack_single "$work/codex.tar.gz" codex
github_asset openai/codex codex-code-mode-host-aarch64-unknown-linux-musl.tar.gz "$work/host.tar.gz"
unpack_single "$work/host.tar.gz" codex-code-mode-host

# Copilot's standalone build, which needs no Node.
github_asset github/copilot-cli copilot-linux-arm64.tar.gz "$work/copilot.tar.gz"
unpack_single "$work/copilot.tar.gz" copilot

# Agy: its manifest names the payload and its SHA-512, as its own installer
# reads them.
curl -fsSL https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_arm64.json -o "$work/agy.json"
sum="$(jq -r '.sha512 // empty' "$work/agy.json")"
[ -n "$sum" ] || fail "Agy's manifest has no SHA-512"
curl -fsSL "$(jq -r .url "$work/agy.json")" -o "$work/agy.tar.gz"
expect "$work/agy.tar.gz" 512 "$sum"
rm -rf "$work/unpack" && mkdir "$work/unpack"
tar -xzf "$work/agy.tar.gz" -C "$work/unpack" antigravity
[ -f "$work/unpack/antigravity" ] || fail "Agy's archive holds no antigravity executable"
place "$work/unpack/antigravity" agy
printf 'agy %s\n' "$(jq -r .version "$work/agy.json")"

# Prax: the app's payload, whose CLI is plain Node.
prax=/Applications/Prax.app/Contents/Resources/resources/app
[ -f "$prax/cli/prax.js" ] || fail "Prax is not installed at /Applications/Prax.app"
rm -rf "$out/prax"
cp -R "$prax" "$out/prax"
printf 'prax %s\n' "$(jq -r .version "$out/prax/package.json")"
