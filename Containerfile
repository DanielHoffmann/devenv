# Dev environment image (hardened) — build with podman:
#   podman build -t devbox .
# Run via the devbox() shell function (devbox.bash); editors connect over SSH.
# Both apply the hardened runtime flags. See SETUP.md.
#
# Hardening baked into the image:
#   - no sudo, no sudoers entry, no setuid escalation path
#   - everything installed at build time; image is run with --read-only
#   - mount points pre-created for tmpfs/volumes (~/.cache, ~/.omp, state)
#
# Base: Ubuntu 24.04
# Runtimes/tools (all optional, see ARGs): Node.js, pnpm, nx, Graphite CLI,
#   Rust, Go, Zig — default "latest", pin with a version, disable with "false".
# Shell: zsh + oh-my-zsh
# Agent harnesses (optional): omp (oh-my-pi), Claude Code

FROM docker.io/library/ubuntu:24.04

ARG USERNAME=devbox

# --- optional components ---------------------------------------------------
# Every runtime/agent below is opt-out and (where meaningful) version-pinnable
# via these ARGs (override at build: podman build --build-arg NODE_VERSION=24.11.0 .):
#   "latest" (default)  -> newest release, resolved at build time
#   "<version>"         -> that exact version (e.g. NODE_VERSION=24.11.0,
#                          RUST_VERSION=1.94, ZIG_VERSION=0.16.0)
#   "false"             -> do not install
# Unversioned components (installer-managed) take "true" (default) / "false":
#   OMP_INSTALL. CLAUDE_CODE_VERSION additionally accepts a version.
# Notes: PNPM/NX/GRAPHITE require NODE_VERSION != false (build fails loudly
# otherwise).
ARG NODE_VERSION=latest
ARG PNPM_VERSION=latest
ARG NX_VERSION=latest
ARG GRAPHITE_VERSION=latest
ARG RUST_VERSION=latest
ARG GO_VERSION=latest
ARG ZIG_VERSION=latest
ARG OMP_INSTALL=true
ARG CLAUDE_CODE_VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# System packages: toolchain deps + common CLI utilities
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    # build essentials (needed by cargo crates, node-gyp, cgo, etc.)
    build-essential pkg-config cmake \
    # networking / certs
    ca-certificates curl wget gnupg openssh-client \
    # sshd for editor remote access (open-remote-ssh)
    openssh-server \
    # version control
    git git-lfs \
    # JSON parsing
    jq \
    # shell
    zsh \
    # archives
    unzip zip tar xz-utils bzip2 \
    # search / navigation niceties
    ripgrep fd-find fzf bat tree less file \
    # everyday tools
    tmux htop vim nano rsync \
    # misc
    locales procps \
    python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Sane locale
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# Ubuntu packages rename fd -> fdfind and bat -> batcat; restore canonical names
RUN ln -sf "$(command -v fdfind)" /usr/local/bin/fd \
 && ln -sf "$(command -v batcat)" /usr/local/bin/bat

# ---------------------------------------------------------------------------
# Go (official tarball into /usr/local/go)
# ---------------------------------------------------------------------------
RUN if [ "${GO_VERSION}" = "false" ]; then echo "skipping go"; exit 0; fi \
 && arch="$(dpkg --print-architecture)" \
 && if [ "${GO_VERSION}" = "latest" ]; then \
      gofile="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)"; \
    else \
      gofile="go${GO_VERSION}"; \
    fi \
 && [ -n "$gofile" ] || { echo "go version resolution failed" >&2; exit 1; } \
 && curl -fsSL "https://go.dev/dl/${gofile}.linux-${arch}.tar.gz" \
    | tar -xz -C /usr/local \
 && /usr/local/go/bin/go version

# ---------------------------------------------------------------------------
# Zig (official tarball into /usr/local/zig, symlinked onto PATH)
# ---------------------------------------------------------------------------
RUN if [ "${ZIG_VERSION}" = "false" ]; then echo "skipping zig"; exit 0; fi \
 && arch="$(dpkg --print-architecture)" \
 && case "$arch" in amd64) zarch=x86_64 ;; arm64) zarch=aarch64 ;; *) echo "unsupported arch: $arch" >&2; exit 1 ;; esac \
 && if [ "${ZIG_VERSION}" = "latest" ]; then \
      zver="$(curl -fsSL https://ziglang.org/download/index.json \
              | jq -r '[keys[] | select(. != "master")] | sort_by(split(".") | map(tonumber)) | last')"; \
    else \
      zver="${ZIG_VERSION}"; \
    fi \
 && [ -n "$zver" ] || { echo "zig version resolution failed" >&2; exit 1; } \
 && mkdir -p /usr/local/zig \
 && curl -fsSL "https://ziglang.org/download/${zver}/zig-${zarch}-linux-${zver}.tar.xz" \
    | tar -xJ -C /usr/local/zig --strip-components=1 \
 && ln -s /usr/local/zig/zig /usr/local/bin/zig \
 && zig version

# ---------------------------------------------------------------------------
# Rust via rustup, system-wide (the official rust image layout):
# toolchain in /usr/local/rustup, proxies in /usr/local/cargo/bin.
# The default profile includes clippy + rustfmt; wasm32-wasip1 added per the
# projects' [tools.rust]. Adding targets/components at runtime fails (read-
# only) — extend the flags here and rebuild instead.
# ---------------------------------------------------------------------------
ENV RUSTUP_HOME=/usr/local/rustup
RUN if [ "${RUST_VERSION}" = "false" ]; then echo "skipping rust"; exit 0; fi \
 && if [ "${RUST_VERSION}" = "latest" ]; then toolchain="stable"; else toolchain="${RUST_VERSION}"; fi \
 && curl -fsSL https://sh.rustup.rs \
    | CARGO_HOME=/usr/local/cargo sh -s -- -y --no-modify-path \
        --profile default \
        --default-toolchain "${toolchain}" \
        --target wasm32-wasip1 \
 && chmod -R a+rX ${RUSTUP_HOME} /usr/local/cargo \
 && /usr/local/cargo/bin/rustc --version

# ---------------------------------------------------------------------------
# Node.js (official tarball into /usr/local) + pnpm, nx and Graphite via npm.
# NOTE: npm -g here runs BEFORE the NPM_CONFIG_PREFIX env below, so these land
# in /usr/local (real image content). Anything npm-globally installed AFTER
# that env would go into ~/.cache and be shadowed by the cache volume.
# ---------------------------------------------------------------------------
RUN if [ "${NODE_VERSION}" = "false" ]; then \
      if [ "${PNPM_VERSION}" != "false" ] || [ "${NX_VERSION}" != "false" ] || [ "${GRAPHITE_VERSION}" != "false" ]; then \
        echo "ERROR: PNPM_VERSION/NX_VERSION/GRAPHITE_VERSION require NODE_VERSION != false" >&2; exit 1; \
      fi; echo "skipping node/pnpm/nx/graphite"; exit 0; \
    fi \
 && arch="$(dpkg --print-architecture)" \
 && case "$arch" in amd64) narch=x64 ;; arm64) narch=arm64 ;; *) echo "unsupported arch: $arch" >&2; exit 1 ;; esac \
 && if [ "${NODE_VERSION}" = "latest" ]; then \
      nver="$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '.[0].version')"; \
    else \
      nver="v${NODE_VERSION}"; \
    fi \
 && [ -n "$nver" ] && [ "$nver" != "v" ] || { echo "node version resolution failed" >&2; exit 1; } \
 && curl -fsSL "https://nodejs.org/dist/${nver}/node-${nver}-linux-${narch}.tar.xz" \
    | tar -xJ -C /usr/local --strip-components=1 --no-same-owner \
 && node --version \
 && if [ "${PNPM_VERSION}" != "false" ]; then npm install -g "pnpm@${PNPM_VERSION}" && pnpm --version; fi \
 && if [ "${NX_VERSION}" != "false" ]; then npm install -g "nx@${NX_VERSION}" && nx --version; fi \
 # Graphite recommends its "stable" npm dist-tag; map "latest" onto it
 && if [ "${GRAPHITE_VERSION}" != "false" ]; then \
      gtver="${GRAPHITE_VERSION}"; [ "$gtver" = "latest" ] && gtver="stable"; \
      npm install -g "@withgraphite/graphite-cli@${gtver}" && gt --version; \
    fi

# ---------------------------------------------------------------------------
# Non-root user with zsh as login shell — NO sudo. The image is immutable at
# runtime; add packages by editing this file and rebuilding, not via sudo.
# (Ubuntu 24.04 ships a default 'ubuntu' user at uid 1000 — replace it)
# ---------------------------------------------------------------------------
RUN userdel -r ubuntu 2>/dev/null || true \
 && useradd -m -u 1000 -s /usr/bin/zsh "${USERNAME}"

# Entrypoint: generate a persistent SSH host key (state volume) and start a
# user-level sshd for editor access, then exec the requested command. sshd
# failure is non-fatal — the shell must stay usable without it.
RUN printf '%s\n' \
      '#!/bin/sh' \
      'KEYDIR="$HOME/.local/state/sshd"' \
      'mkdir -p "$KEYDIR"' \
      '[ -f "$KEYDIR/host_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -f "$KEYDIR/host_ed25519"' \
      '/usr/sbin/sshd -f "$HOME/.config/sshd/sshd_config" -E /tmp/sshd.log || echo "devbox: sshd failed to start (see /tmp/sshd.log)" >&2' \
      'exec "$@"' \
      > /usr/local/bin/devbox-entrypoint \
 && chmod 0755 /usr/local/bin/devbox-entrypoint

USER ${USERNAME}
WORKDIR /home/${USERNAME}
ENV HOME=/home/${USERNAME} \
    SHELL=/usr/bin/zsh

# Enable git-lfs hooks for this user
RUN git lfs install

# ---------------------------------------------------------------------------
# sshd config (runs as the devbox user, key-auth only, port 2222).
# Host key lives on the state volume (generated by the entrypoint);
# authorized_keys is bind-mounted read-only by devbox().
# ---------------------------------------------------------------------------
RUN mkdir -p ~/.ssh ~/.config/sshd && chmod 700 ~/.ssh \
 && printf '%s\n' \
      'Port 2222' \
      'ListenAddress 0.0.0.0' \
      'HostKey /home/devbox/.local/state/sshd/host_ed25519' \
      'PidFile /tmp/sshd.pid' \
      'UsePAM no' \
      'PasswordAuthentication no' \
      'KbdInteractiveAuthentication no' \
      'PubkeyAuthentication yes' \
      'AuthorizedKeysFile /home/devbox/.ssh/authorized_keys' \
      'StrictModes no' \
      'Subsystem sftp internal-sftp' \
      > ~/.config/sshd/sshd_config

# ---------------------------------------------------------------------------
# oh-my-zsh
# ---------------------------------------------------------------------------
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

# ---------------------------------------------------------------------------
# PATH for the devbox user: user bins, then the system toolchains.
# Redirect every package manager that doesn't respect ~/.cache into it, so a
# single persistent cache volume covers them all under the read-only rootfs:
#   cargo: registry + `cargo install` bins
#   npm: cache + -g prefix
#   go:    module cache + `go install` bins
# (RUSTUP_HOME stays at /usr/local/rustup so the cargo/rustc proxies find the
#  baked toolchain; CARGO_HOME below only relocates the user's cargo data.)
# ---------------------------------------------------------------------------

ENV CARGO_HOME=/home/${USERNAME}/.cache/cargo \
    GOPATH=/home/${USERNAME}/.cache/go \
    NPM_CONFIG_CACHE=/home/${USERNAME}/.cache/npm \
    NPM_CONFIG_PREFIX=/home/${USERNAME}/.cache/npm-global \
    PNPM_HOME=/home/${USERNAME}/.local/share/pnpm
ENV PATH="/home/${USERNAME}/.local/bin:${CARGO_HOME}/bin:${GOPATH}/bin:${NPM_CONFIG_PREFIX}/bin:${PNPM_HOME}:/usr/local/cargo/bin:/usr/local/go/bin:${PATH}"

# pnpm store on the container-private workspace volume (~/workspace/.pnpm-store):
# same mount as projects cloned under ~/workspace, so pnpm's hard-linked installs
# work there. Projects under ~/shared are on a different mount and fall back to
# copying (hard links can't cross mounts).
# (Written to ~/.config/pnpm/rc, baked into the image.)
RUN if command -v pnpm >/dev/null; then \
      pnpm config set store-dir /home/${USERNAME}/workspace/.pnpm-store; \
    else echo "pnpm not installed; skipping store config"; fi

# ---------------------------------------------------------------------------
# omp (oh-my-pi) — AI coding agent / harness, via its official installer
# (installs a release binary into ~/.local/bin, which is on PATH)
# ---------------------------------------------------------------------------
RUN if [ "${OMP_INSTALL}" = "false" ]; then echo "skipping omp"; exit 0; fi \
 && curl -fsSL https://omp.sh/install | sh \
 && command -v omp

# ---------------------------------------------------------------------------
# Claude Code CLI via its official installer (per-user: versions under
# ~/.local/share/claude, launcher symlink in ~/.local/bin).
# DISABLE_AUTOUPDATER: its background self-update can never succeed against
# the read-only rootfs — update by rebuilding the image instead.
#
# CLAUDE_CONFIG_DIR routes Claude Code's config + credentials into ~/.claude
# (a named volume), since its default of writing at $HOME level hits the
# read-only rootfs.
# ---------------------------------------------------------------------------
ENV CLAUDE_CONFIG_DIR=/home/${USERNAME}/.claude
ENV DISABLE_AUTOUPDATER=1
RUN if [ "${CLAUDE_CODE_VERSION}" = "false" ]; then echo "skipping claude code"; exit 0; fi \
 && if [ "${CLAUDE_CODE_VERSION}" = "latest" ]; then \
      curl -fsSL https://claude.ai/install.sh | bash; \
    else \
      curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_CODE_VERSION}"; \
    fi \
 && claude --version

# ---------------------------------------------------------------------------
# zsh configuration
# ---------------------------------------------------------------------------
RUN { \
      echo ''; \
      echo '# --- dev environment ---'; \
      echo 'command -v omp >/dev/null && eval "$(omp completions zsh)"'; \
      echo 'alias ll="ls -lah"'; \
      echo '# per-workspace shell config, lives on the host (created by devbox())'; \
      echo '[[ -f ~/shared/.zshrc ]] && source ~/shared/.zshrc'; \
      echo '# root fs is read-only at runtime; keep history on the state volume'; \
      echo 'export HISTFILE="$HOME/.local/state/zsh_history"'; \
      echo 'export HISTSIZE=50000 SAVEHIST=50000'; \
    } >> ~/.zshrc

# ---------------------------------------------------------------------------
# Pre-create mount points so tmpfs/volumes land with correct ownership when
# the container runs with --read-only:
#   ~/.cache        -> volume  (dependency + build caches, persistent)
#   ~/.local        -> volume (pnpm global bins, shell history, etc persistent)
#   ~/.config       -> volume (Graphite CLI auth token + cache, persistent)
#   ~/.omp          -> volume  (omp credentials/config, persistent)
#   ~/.claude       -> volume  (Claude Code config/credentials, persistent)
#   ~/.vscodium-server -> volume (editor remote server, via open-remote-ssh)
#   ~/.ssh          -> volume  (container-side ssh keys/known_hosts; created
#                               with chmod 700 in the sshd section above,
#                               authorized_keys bind-mounted read-only on top)
#   ~/workspace     -> volume  (container-private workspace + pnpm store,
#                               persistent, never exposed to the host)
#   ~/shared        -> bind    (the only host path exposed)
# ---------------------------------------------------------------------------
RUN mkdir -p ~/.cache ~/.local ~/.config ~/.omp ~/.claude ~/.vscodium-server ~/.ssh ~/workspace ~/shared 

WORKDIR /home/${USERNAME}/shared

# Start sshd (non-fatal) around the requested command; default: login zsh
ENTRYPOINT ["/usr/local/bin/devbox-entrypoint"]
CMD ["zsh", "-l"]