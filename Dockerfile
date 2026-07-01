# syntax=docker/dockerfile:1
#
# Build a patched Actual web client from source and serve it from the
# stock actual-server image. The only thing that changes is the Schedules
# manager page's default sort (next-date -> name A->Z).
#
# Bump VERSION to track a new Actual release (must match an existing
# git tag "v<VERSION>" AND a published actual-server:<VERSION> image).
# Override at build time with:  --build-arg VERSION=26.7.0
ARG VERSION=26.5.2

# ---------------------------------------------------------------------------
# Stage 1 — build the patched web bundle from source
# ---------------------------------------------------------------------------
# --platform=$BUILDPLATFORM keeps this heavy stage on the runner's NATIVE arch
# (e.g. amd64 in CI) even when the final image targets ARM — so `yarn build`
# never runs under slow QEMU emulation. For a plain native build it's a no-op.
FROM --platform=$BUILDPLATFORM node:22-bookworm AS builder
ARG VERSION

RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN corepack enable

WORKDIR /app

# Clone the exact release tag (shallow).
RUN git clone --depth 1 --branch "v${VERSION}" \
    https://github.com/actualbudget/actual.git .

# Apply the schedules name-sort patch.
# If a future release moves this line, `git apply` fails and the build
# stops here (loud failure > silently shipping an unpatched bundle).
COPY schedules-name-sort.patch /tmp/schedules-name-sort.patch
RUN git apply --verbose /tmp/schedules-name-sort.patch

# Full workspace install (dev deps are needed to build).
RUN yarn install --immutable

# Build the web bundle with the SAME script the official Docker image uses:
# `yarn build:server` runs `yarn build:browser` (= ./bin/package-browser),
# which builds @actual-app/crdt, plugins-service, the loot-core BROWSER backend
# worker (@actual-app/core build:browser -> the "kcab" worker that populates
# window.Actual), and finally the web app in browser mode. It fetches
# translations and sets NODE_OPTIONS internally, and touches no Electron.
#
# (An earlier `vite build` alone produced a UI with no backend worker, so
# window.Actual was undefined -> "Cannot read ... ACTUAL_VERSION". And
# `yarn build --scope=@actual-app/web` via lage wrongly pulled in
# desktop-electron's electron-builder/Flatpak packaging. This is the correct,
# official path.)
RUN yarn build:browser
# Output: /app/packages/desktop-client/build

# ---------------------------------------------------------------------------
# Stage 2 — stock server image, web root pointed at the patched bundle
# ---------------------------------------------------------------------------
FROM docker.io/actualbudget/actual-server:${VERSION}

COPY --from=builder /app/packages/desktop-client/build /web
ENV ACTUAL_WEB_ROOT=/web