# The Dockerfile that built parley-agy-prax:local on 30 September 2026: Agy
# with the Prax CLI, reaching the Prax app on the Mac through
# host.docker.internal. It is documentation of a working recipe, not something
# Parley builds or ships: Parley never builds or pulls images. What it relies
# on, and what it opens, is under "Reaching a service on your Mac" in
# docs/container-images.md.
#
# Inputs next to this file when building: `agy`, the publisher's Linux arm64
# executable verified as described in docs/container-images.md, and `prax`, a
# copy of /Applications/Prax.app/Contents/Resources/resources/app. Rebuild
# when either updates.
#
#   docker build -t parley-agy-prax:local -f docs/parley-agy-prax.Dockerfile <dir>
#
# node:22-slim passes Parley's image probe unmodified and supplies the Node
# that Prax's CLI needs; the Mac's own prax command runs a macOS binary that
# cannot run here.
FROM node:22-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git curl procps \
 && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 agy /usr/local/bin/agy

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
