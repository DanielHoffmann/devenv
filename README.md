# devbox — hardened podman dev environment

A sandboxed development container for running toolchains and the [omp (oh-my-pi)](https://github.com/can1357/oh-my-pi) coding agent with limited blast radius. Ubuntu 24.04 base, toolchains managed by [mise](https://mise.jdx.dev) (Node.js LTS, pnpm, Rust, Go, Zig), zsh + oh-my-zsh, and a set of everyday CLI tools (jq, git-lfs, ripgrep, fd, fzf, bat, tmux, and friends).

The container is designed to be run **rootless** with an **immutable root filesystem**, **no capabilities**, and **no privilege escalation path** — see [Security model](#security-model).

## Files

| File | Purpose | Goes where |
|---|---|---|
| `Containerfile.hardened` | The image definition | anywhere you build from |
| `devbox.bash` | `devbox` shell function | sourced from `~/.bash_profile` |
| `devcontainer.json` | VS Code Dev Containers config | `<workspace>/.devcontainer/` |

## Prerequisites

- Rootless podman, i.e. installed and run as your normal user, never via `sudo`. Verify with `podman info --format '{{.Host.Security.Rootless}}'` — must print `true`.
- Subordinate UID/GID ranges for your user (most distro packages set this up; check that `grep $USER /etc/subuid` returns a line).
- A parent directory that holds (or will hold) your projects. These instructions assume `~/code`; substitute your own throughout.

## 1. Build the image

```sh
podman build -t devbox -f Containerfile.hardened .
```

All toolchains are installed at build time because the container's root filesystem is read-only at runtime. This is the workflow's central rule: **to add or update a tool, edit the Containerfile and rebuild** — there is deliberately no `sudo apt install` inside a running container. Rebuilds are fast thanks to layer caching.

Toolchain versions are set to `latest`/`lts` in the `mise use --global` block. Pin them (e.g. `node@22 go@1.24 zig@0.14`) if you want reproducible images.

## 2. Install the shell functions

Append the contents of `devbox.bash` to your `~/.bash_profile` (or keep the file somewhere and source it):

```sh
cat devbox.bash >> ~/.bash_profile
source ~/.bash_profile
```

Then adjust the default workspace if yours isn't `~/code` — either edit the `DEVBOX_PROJECT` default inside the function, or export it in your profile:

```sh
export DEVBOX_PROJECT="$HOME/code"
```

Usage (`-h` prints this too):

```sh
devbox                       # interactive zsh, workspace mounted at /workspace
devbox -i myimage            # different image
devbox -p ~/other/workspace  # different workspace dir
devbox make test             # trailing args run as the container command
```

## 3. pnpm store and gitignore

The image pins pnpm's content-addressable store to `/workspace/.pnpm-store`. This keeps the store and every project's `node_modules` on the **same mount**, which is what allows pnpm's hard-linked, deduplicated installs (hard links can't cross mount boundaries). All projects under the workspace share one store, persisted on the host at `~/code/.pnpm-store`.

Add it to your global gitignore so a repo never accidentally tracks it:

```sh
git config --global core.excludesFile ~/.gitignore
echo '.pnpm-store/' >> ~/.gitignore
```

## 4. omp (agent) login

omp's config and credentials live in the `devbox-omp` named volume, so you log in once and it persists across containers:

```sh
devbox omp   # then authenticate via /login inside omp
```

Never bake API keys into the image or mount your host `~/.omp` — the volume keeps credentials container-side only.

## 5. VS Code integration (Dev Containers)

Language servers for Rust/Go/Zig need the container's toolchains and caches, so the VS Code extension host runs inside the container.

One-time setup:

1. Install the **Dev Containers** extension.
2. Add to your VS Code user settings: `"dev.containers.dockerPath": "podman"`.
3. Copy the config into your workspace: `mkdir -p ~/code/.devcontainer && cp devcontainer.json ~/code/.devcontainer/`.

Daily use: open `~/code` in VS Code → command palette → **"Dev Containers: Reopen in Container"**. rust-analyzer, gopls, and the zig LSP run container-side with correct paths; the integrated terminal lands in the container with zsh, omp, and all toolchains available.

Notes:

- The devcontainer reuses the same image and named volumes as the `devbox` function — same caches, same omp login — but runs as a **separate container**.
- JS/TS needs no container-side LSP: `node_modules` lives on the host mount, so tsserver works either way.
- On SELinux hosts (Fedora family), uncomment the `"--security-opt=label=disable"` line in `devcontainer.json` if mounts hit permission errors. Ubuntu/Debian hosts don't need it.
- File ownership across the boundary is handled by `--userns=keep-id`, mapping your host user onto the container's `dev` user (uid 1000).

## Ports

Container ports **3000–3999** are published to the host, so a dev server listening on e.g. `:3000` inside the container is reachable at `http://localhost:3000` on the host. Two things to know:

- Inside the container, bind servers to `0.0.0.0` (or `::`), not `127.0.0.1` — the container's loopback is separate from the host's, so a server bound only to the container's localhost is unreachable through the published port. Most dev servers have a `--host 0.0.0.0` flag.
- On the host side the ports are bound to `127.0.0.1` only, so nothing is exposed to your LAN.

Ports outside the range aren't reachable; widen or change the range in `devbox.bash` and `devcontainer.json` if needed. In VS Code, the Dev Containers extension additionally auto-forwards any port it detects, independent of this range.

## Persistent state (named volumes)

Everything outside the workspace mount that needs to survive restarts lives in podman named volumes — container-managed, never host paths:

| Volume | Mounted at | Holds |
|---|---|---|
| `devbox-cache` | `~/.cache` | cargo registry + bins, Go module cache + bins, npm cache + globals, pnpm globals |
| `devbox-omp` | `~/.omp` | omp credentials and config |
| `devbox-state` | `~/.local/state` | zsh history, misc state |
| `devbox-vscode` | `~/.vscode-server` | VS Code remote server + container-side extensions |

Useful commands: `podman volume ls`, and `podman volume rm devbox-cache` for a clean dependency slate (it regenerates on next use). `/tmp` is a size-capped tmpfs and evaporates every run.

## Security model

What the setup defends against and how, honestly stated:

- **Rootless podman + user namespaces**: container root maps to your unprivileged host user. A full container escape would land an attacker as your user, not host root — host root would require a second, separate escalation.
- **`--cap-drop=all`**: even container-root processes hold zero Linux capabilities, shrinking the kernel attack surface.
- **`--security-opt no-new-privileges`** plus no sudo/setuid path in the image: nothing in the container can ever elevate.
- **`--read-only` rootfs**: nothing can trojan a binary on `$PATH` or persist outside the explicit carve-outs.
- **Narrow exposure**: the workspace directory is the only host path the container sees.

Known accepted tradeoffs:

- Everything under the workspace mount is readable/writable by whatever runs inside — including omp. Point the mount at a parent directory containing only projects you're comfortable exposing; use `-p` for anything narrower.
- The cache volumes are persistent, executable, and on `$PATH` — the natural place for a malicious process to persist. `podman volume rm` any of them to reset.
- With the devcontainer, your IDE's extension host shares the container boundary with the agent; the host remains protected, but IDE-vs-agent separation inside the container does not exist. The `devbox` function remains available as an IDE-free container when stricter separation is wanted.
- Resource ceilings (`--pids-limit 4096`, `--memory 8g`) are runaway-process insurance; tune per machine.

Rules that keep the model intact: never run via `sudo podman`, never add `--privileged`, never mount the podman socket into the container, and mount credentials only as named volumes, not host paths.

## Troubleshooting

- **`fd`, tools missing in `podman exec` one-offs** — non-interactive contexts rely on mise shims already on `PATH` via `ENV`; if a freshly `mise use`d tool is missing, rebuild (runtime `mise install` can't write the read-only home).
- **pnpm falls back to copying instead of hard links** — you ran pnpm outside `/workspace` scope or the store dir moved; verify `pnpm config get store-dir` prints `/workspace/.pnpm-store` inside the container.
- **VS Code fails to attach / server install errors** — confirm `dockerPath` is `podman`, the image was rebuilt after the `.vscode-server` mount point was added, and try `podman volume rm devbox-vscode` to force a fresh server install.
- **Wrong file ownership on workspace files** — the devcontainer needs `--userns=keep-id` (already in `runArgs`); for the shell functions, rootless podman maps ownership correctly by default.
- **Network failures inside builds** — corporate proxies/DNS: pass `--network=host` to `podman build` only (build-time, not runtime) or configure proxy env via `--build-arg`.

## Updating

- **Toolchains**: edit versions in the Containerfile, rebuild, restart containers. Caches in `devbox-cache` carry over.
- **omp**: pinned via mise's github backend; rebuild picks up the latest release, or pin a version: `github:can1357/oh-my-pi@vX.Y.Z`.
- **Base image**: `podman build --pull ...` to refresh Ubuntu layers for security updates; worth doing periodically.
