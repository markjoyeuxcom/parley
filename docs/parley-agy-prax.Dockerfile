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

# Parley replaces PATH in a container pane, so the shim names node exactly.
COPY prax /opt/prax
RUN printf '#!/bin/sh\nexec /usr/local/bin/node /opt/prax/cli/prax.js "$@"\n' > /usr/local/bin/prax \
 && chmod 0755 /usr/local/bin/prax

# Parley passes no variables of your own into a container pane, so the address
# is part of the image. 49636 is the Prax app's own loopback port. Never put a
# token here: anyone with the image can read its layers.
ENV PRAX_API_URL=http://host.docker.internal:49636

# HOME for the named volume Parley mounts and chowns. No USER line: Parley
# supplies --user at run time.
RUN mkdir -p /home/parley
