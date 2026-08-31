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
# Runtimes (installed manually, system-wide): Node.js 24, pnpm 11, Rust 1.94,
#   .NET 9, Go, Zig. Update the ARG pins below and rebuild to bump.
# Shell: zsh + oh-my-zsh
# Agent harness: omp (oh-my-pi)

FROM docker.io/library/ubuntu:24.04

ARG USERNAME=devbox

# --- toolchain version pins ---------------------------------------------
# node/pnpm/rust/dotnet match the projects' .tool-versions / mise.toml;
# go/zig track latest (update manually).
# NOTE: .NET 9 is an STS release, end-of-life since May 2026 (no more security
# patches, and dropped from the Ubuntu archive — hence the install script
# below). Ubuntu's apt carries dotnet-sdk-8.0 / dotnet-sdk-10.0 (LTS) if the
# projects ever move.
ARG DOTNET_CHANNEL=9.0
ARG NODE_VERSION=24.11.0
ARG PNPM_VERSION=11.0.8
ARG RUST_VERSION=1.94
ARG GO_VERSION=1.26.7
ARG ZIG_VERSION=0.16.0

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
    # .NET runtime dependency (the SDK is installed via script below)
    libicu74 \
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
RUN arch="$(dpkg --print-architecture)" \
 && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" \
    | tar -xz -C /usr/local \
 && /usr/local/go/bin/go version

# ---------------------------------------------------------------------------
# Zig (official tarball into /usr/local/zig, symlinked onto PATH)
# ---------------------------------------------------------------------------
RUN arch="$(dpkg --print-architecture)" \
 && case "$arch" in amd64) zarch=x86_64 ;; arm64) zarch=aarch64 ;; *) echo "unsupported arch: $arch" >&2; exit 1 ;; esac \
 && mkdir -p /usr/local/zig \
 && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zarch}-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /usr/local/zig --strip-components=1 \
 && ln -s /usr/local/zig/zig /usr/local/bin/zig \
 && zig version

# ---------------------------------------------------------------------------
# .NET SDK via Microsoft's official dotnet-install script (channel pinned
# above). Not apt: Ubuntu's archive only carries in-support .NET versions
# (currently 8 and 10), and 9 has been dropped since its May 2026 EOL.
# ---------------------------------------------------------------------------
ENV DOTNET_ROOT=/usr/local/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh \
    | bash -s -- --channel "${DOTNET_CHANNEL}" --install-dir "${DOTNET_ROOT}" \
 && ln -s "${DOTNET_ROOT}/dotnet" /usr/local/bin/dotnet \
 && dotnet --version

# ---------------------------------------------------------------------------
# Rust via rustup, system-wide (the official rust image layout):
# toolchain in /usr/local/rustup, proxies in /usr/local/cargo/bin.
# The default profile includes clippy + rustfmt; wasm32-wasip1 added per the
# projects' [tools.rust]. Adding targets/components at runtime fails (read-
# only) — extend the flags here and rebuild instead.
# ---------------------------------------------------------------------------
ENV RUSTUP_HOME=/usr/local/rustup
RUN curl -fsSL https://sh.rustup.rs \
    | CARGO_HOME=/usr/local/cargo sh -s -- -y --no-modify-path \
        --profile default \
        --default-toolchain "${RUST_VERSION}" \
        --target wasm32-wasip1 \
 && chmod -R a+rX ${RUSTUP_HOME} /usr/local/cargo \
 && /usr/local/cargo/bin/rustc --version

# ---------------------------------------------------------------------------
# Node.js (official tarball into /usr/local) + pnpm and nx via npm.
# NOTE: npm -g here runs BEFORE the NPM_CONFIG_PREFIX env below, so these land
# in /usr/local (real image content). Anything npm-globally installed AFTER
# that env would go into ~/.cache and be shadowed by the cache volume.
# ---------------------------------------------------------------------------
RUN arch="$(dpkg --print-architecture)" \
 && case "$arch" in amd64) narch=x64 ;; arm64) narch=arm64 ;; *) echo "unsupported arch: $arch" >&2; exit 1 ;; esac \
 && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${narch}.tar.xz" \
    | tar -xJ -C /usr/local --strip-components=1 --no-same-owner \
 && node --version \
 && npm install -g "pnpm@${PNPM_VERSION}" nx \
 && pnpm --version && nx --version

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
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended \
 && sed -i 's/^ZSH_THEME=.*/ZSH_THEME="robbyrussell"/' ~/.zshrc

# ---------------------------------------------------------------------------
# PATH for the devbox user: user bins, then the system toolchains.
# Redirect every package manager that doesn't respect ~/.cache into it, so a
# single persistent cache volume covers them all under the read-only rootfs:
#   cargo: registry + `cargo install` bins    npm:  cache + -g prefix
#   go:    module cache + `go install` bins   pnpm: global bins (store: below)
# (RUSTUP_HOME stays at /usr/local/rustup so the cargo/rustc proxies find the
#  baked toolchain; CARGO_HOME below only relocates the user's cargo data.)
# ---------------------------------------------------------------------------
ENV CARGO_HOME=/home/${USERNAME}/.cache/cargo \
    GOPATH=/home/${USERNAME}/.cache/go \
    NPM_CONFIG_CACHE=/home/${USERNAME}/.cache/npm \
    NPM_CONFIG_PREFIX=/home/${USERNAME}/.cache/npm-global \
    PNPM_HOME=/home/${USERNAME}/.cache/pnpm
ENV PATH="/home/${USERNAME}/.local/bin:${CARGO_HOME}/bin:${GOPATH}/bin:${NPM_CONFIG_PREFIX}/bin:${PNPM_HOME}:/usr/local/cargo/bin:/usr/local/go/bin:${PATH}"

# pnpm store lives INSIDE the workspace mount (~/workspace/.pnpm-store), not in
# the cache volume: hard links cannot cross mounts, so keeping the store and
# node_modules on the same mount preserves pnpm's link-based installs. Mount a
# PARENT directory containing your projects as ~/workspace and every project
# shares one deduplicated store, persisted on the host.
# (Written to ~/.config/pnpm/rc, baked into the image.)
RUN pnpm config set store-dir /home/${USERNAME}/workspace/.pnpm-store

# ---------------------------------------------------------------------------
# omp (oh-my-pi) — AI coding agent / harness, via its official installer
# (installs a release binary into ~/.local/bin, which is on PATH)
# ---------------------------------------------------------------------------
RUN curl -fsSL https://omp.sh/install | sh \
 && command -v omp

# ---------------------------------------------------------------------------
# zsh configuration
# ---------------------------------------------------------------------------
RUN { \
      echo ''; \
      echo '# --- dev environment ---'; \
      echo 'command -v omp >/dev/null && eval "$(omp completions zsh)"'; \
      echo 'alias ll="ls -lah"'; \
      echo '# per-workspace shell config, lives on the host (created by devbox())'; \
      echo '[[ -f ~/workspace/.zshrc ]] && source ~/workspace/.zshrc'; \
      echo '# root fs is read-only at runtime; keep history on the state volume'; \
      echo 'export HISTFILE="$HOME/.local/state/zsh_history"'; \
      echo 'export HISTSIZE=50000 SAVEHIST=50000'; \
    } >> ~/.zshrc

# ---------------------------------------------------------------------------
# Pre-create mount points so tmpfs/volumes land with correct ownership when
# the container runs with --read-only:
#   ~/.cache        -> volume  (dependency + build caches, persistent)
#   ~/.omp          -> volume  (omp credentials/config, persistent)
#   ~/.local/state  -> volume  (shell history etc., persistent)
#   ~/.vscodium-server -> volume (editor remote server, via open-remote-ssh)
#   ~/workspace     -> bind    (your projects, the only host path exposed)
# ---------------------------------------------------------------------------
RUN mkdir -p ~/.cache ~/.omp ~/.local/state ~/.vscodium-server ~/workspace

WORKDIR /home/${USERNAME}/workspace

# Start sshd (non-fatal) around the requested command; default: login zsh
ENTRYPOINT ["/usr/local/bin/devbox-entrypoint"]
CMD ["zsh", "-l"]