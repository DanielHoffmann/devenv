# Dev environment image (hardened) — build with podman:
#   podman build -t devbox .
# Run via the devbox() shell function (devbox.bash) or VS Code devcontainer,
# both of which apply the hardened runtime flags. See SETUP.md.
#
# Hardening baked into the image:
#   - no sudo, no sudoers entry, no setuid escalation path
#   - everything installed at build time; image is run with --read-only
#   - mount points pre-created for tmpfs/volumes (~/.cache, ~/.omp, state)
#
# Base: Ubuntu 24.04
# Runtimes via mise: Node.js (LTS), Rust, Go, Zig — plus pnpm
# Shell: zsh + oh-my-zsh
# Agent harness: omp (oh-my-pi), installed through mise's github backend

FROM docker.io/library/ubuntu:24.04

ARG USERNAME=devbox
ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# System packages: toolchain deps + common CLI utilities
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    # build essentials (needed by cargo crates, node-gyp, cgo, etc.)
    build-essential pkg-config cmake \
    # networking / certs
    ca-certificates curl wget gnupg openssh-client \
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
# Non-root user with zsh as login shell — NO sudo. The image is immutable at
# runtime; add packages by editing this file and rebuilding, not via sudo.
# (Ubuntu 24.04 ships a default 'ubuntu' user at uid 1000 — replace it)
# ---------------------------------------------------------------------------
RUN userdel -r ubuntu 2>/dev/null || true \
 && useradd -m -u 1000 -s /usr/bin/zsh "${USERNAME}"

USER ${USERNAME}
WORKDIR /home/${USERNAME}
ENV HOME=/home/${USERNAME} \
    SHELL=/usr/bin/zsh

# Enable git-lfs hooks for this user
RUN git lfs install

# ---------------------------------------------------------------------------
# oh-my-zsh
# ---------------------------------------------------------------------------
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

# ---------------------------------------------------------------------------
# mise + toolchains (Node.js, Rust, Go, Zig)
# ---------------------------------------------------------------------------
RUN curl -fsSL https://mise.run | sh

# Shims on PATH so tools resolve in non-interactive contexts too
# (RUN steps below, `podman exec`, CI, scripts). Interactive shells get the
# full `mise activate` treatment via .zshrc further down.
ENV PATH="/home/${USERNAME}/.local/bin:/home/${USERNAME}/.local/share/mise/shims:${PATH}"

# ---------------------------------------------------------------------------
# Redirect every package manager that doesn't respect ~/.cache into it, so a
# single persistent cache volume covers them all under the read-only rootfs:
#   cargo: registry + `cargo install` bins    npm:  cache + -g prefix
#   go:    module cache + `go install` bins   pnpm: global bins (store: below)
# ---------------------------------------------------------------------------
ENV CARGO_HOME=/home/${USERNAME}/.cache/cargo \
    GOPATH=/home/${USERNAME}/.cache/go \
    NPM_CONFIG_CACHE=/home/${USERNAME}/.cache/npm \
    NPM_CONFIG_PREFIX=/home/${USERNAME}/.cache/npm-global \
    PNPM_HOME=/home/${USERNAME}/.cache/pnpm
ENV PATH="${CARGO_HOME}/bin:${GOPATH}/bin:${NPM_CONFIG_PREFIX}/bin:${PNPM_HOME}:${PATH}"

# Pin versions here if you want reproducible builds, e.g. node@22 go@1.24
RUN mise use --global \
      node@lts \
      pnpm@latest \
      rust@latest \
      go@latest \
      zig@latest \
 && mise install \
 && mise reshim

# pnpm store lives INSIDE the workspace mount (~/workspace/.pnpm-store), not in
# the cache volume: hard links cannot cross mounts, so keeping the store and
# node_modules on the same mount preserves pnpm's link-based installs. Mount a
# PARENT directory containing your projects as ~/workspace and every project
# shares one deduplicated store, persisted on the host.
# (Written to ~/.config/pnpm/rc, baked into the image.)
RUN pnpm config set store-dir /home/${USERNAME}/workspace/.pnpm-store

# ---------------------------------------------------------------------------
# omp (oh-my-pi) — AI coding agent / harness
# Installed as a pinned release binary through mise's github backend,
# per the project's recommended "pinned versions" route.
# ---------------------------------------------------------------------------
RUN mise use --global github:can1357/oh-my-pi \
 && mise reshim

# ---------------------------------------------------------------------------
# zsh configuration: activate mise, wire up completions
# ---------------------------------------------------------------------------
RUN { \
      echo ''; \
      echo '# --- dev environment ---'; \
      echo 'eval "$(~/.local/bin/mise activate zsh)"'; \
      echo 'command -v omp >/dev/null && eval "$(omp completions zsh)"'; \
      echo 'alias ll="ls -lah"'; \
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
#   ~/.vscode-server-> volume  (VS Code remote server, when using devcontainers)
#   ~/workspace     -> bind    (your projects, the only host path exposed)
# ---------------------------------------------------------------------------
RUN mkdir -p ~/.cache ~/.omp ~/.local/state ~/.vscode-server ~/workspace

WORKDIR /home/${USERNAME}/workspace

# Default to an interactive login zsh
CMD ["zsh", "-l"]