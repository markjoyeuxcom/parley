# The Dockerfile that built parley-agents:local on 14 September 2026, the image
# every container-pane check and the four-vendor hand test ran against. It is
# documentation of a working recipe, not something Parley builds or ships:
# Parley never builds or pulls images (docs/container-images.md).
#
# Inputs next to this file when building: `agy` and `copilot`, the publishers'
# Linux arm64 executables, verified as described in docs/container-images.md.
# Claude and Codex are copied from an earlier local image; replace those two
# lines with COPY of your own verified Linux executables if you have no such
# image.
#
#   docker build -t parley-agents:local -f docs/parley-agents.Dockerfile <dir>
FROM debian:stable-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git curl procps \
 && rm -rf /var/lib/apt/lists/*

COPY --from=parley-container-spike:local /usr/local/bin/claude /usr/local/bin/claude
COPY --from=parley-container-spike:local /usr/local/bin/codex /usr/local/bin/codex
COPY --from=parley-container-spike:local /usr/local/bin/codex-code-mode-host /usr/local/bin/codex-code-mode-host
COPY --chmod=0755 copilot /usr/local/bin/copilot
COPY --chmod=0755 agy /usr/local/bin/agy

# HOME for the named volume Parley mounts and chowns. No USER line: Parley
# supplies --user at run time.
RUN mkdir -p /home/parley
