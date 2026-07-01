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
#
# If your build host is low on RAM and Vite OOMs, uncomment the next line:
# ENV NODE_OPTIONS=--max-old-space-size=4096
RUN yarn install --immutable

# Build ONLY the web bundle and its two upstream workspace deps, by invoking
# each package's own build script directly. Do NOT use
# `yarn build --scope=@actual-app/web` here: lage walks the graph and also
# builds dependents like `desktop-electron`, whose build runs electron-builder
# to package an AppImage/Flatpak and fails on CI runners lacking `flatpak`.
# The server web bundle needs none of that. Order matters — the web build
# reads loot-core's build output (../loot-core/lib-dist/*).
RUN yarn workspace @actual-app/crdt build \
    && yarn workspace @actual-app/core build \
    && yarn workspace @actual-app/web build
# Output: /app/packages/desktop-client/build

# ---------------------------------------------------------------------------
# Stage 2 — stock server image, web root pointed at the patched bundle
# ---------------------------------------------------------------------------
FROM docker.io/actualbudget/actual-server:${VERSION}

COPY --from=builder /app/packages/desktop-client/build /web
ENV ACTUAL_WEB_ROOT=/web