# One image for every agent vendor: Claude Code, Codex, Agy and Copilot, with
# the Prax CLI reaching the Prax app on the Mac through host.docker.internal.
# Each container pane still runs in a container of its own, with its own home
# volume; they start from this one image. It is documentation of a working
# recipe, not something Parley builds or ships: Parley never builds or pulls
# images. What it relies on, and what it opens, is in docs/container-images.md.
#
# Fetch and check the inputs, then build (both commands from the repository):
#
#   sh docs/parley-agents-fetch.sh <folder> &&
#     docker build -t parley-agents:local -f docs/parley-agents.Dockerfile <folder>
#
# Rebuild when a vendor or Prax updates. node:22-slim passes Parley's image
# probe unmodified and supplies the Node that Prax's CLI needs; the vendor
# builds are standalone and need none of it.
FROM node:22-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git curl procps \
 && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 claude /usr/local/bin/claude
COPY --chmod=0755 codex /usr/local/bin/codex
COPY --chmod=0755 codex-code-mode-host /usr/local/bin/codex-code-mode-host
COPY --chmod=0755 agy /usr/local/bin/agy
COPY --chmod=0755 copilot /usr/local/bin/copilot

# Prax's own installer writes its `prax` shim. It goes in /usr/local/bin, which
# is on the PATH Parley gives a pane, and the shim names node exactly. The
# installer also copies its skills into HOME; that is repeated inside the pane
# (see docs/container-images.md), so the build's copy is thrown away.
COPY prax /opt/prax
RUN HOME=/tmp/prax-build PRAX_BIN_DIR=/usr/local/bin sh /opt/prax/skills/install.sh --cli \
 && rm -rf /tmp/prax-build

# Parley passes no variables of your own into a container pane, so the address
# is part of the image. 49636 is the loopback port one Prax app chose on first
# launch; replace it with yours, from
# ~/Library/Application Support/com.moomora.prax/webview-port. Never put a
# token here: anyone with the image can read its layers.
ENV PRAX_API_URL=http://host.docker.internal:49636

# HOME for the named volume Parley mounts and chowns. No USER line: Parley
# supplies --user at run time.
RUN mkdir -p /home/parley
