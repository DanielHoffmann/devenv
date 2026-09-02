# devbox — hardened podman dev environment

A sandboxed development container for running toolchains and coding agents with limited blast radius. Ubuntu 24.04 base with manually installed, system-wide toolchains (Node.js, pnpm, nx, Rust, Go, Zig), zsh + oh-my-zsh, the omp and Claude Code agent CLIs, and a set of everyday CLI tools (jq, git-lfs, ripgrep, fd, fzf, bat, tmux, and friends).

The container is designed to be run **rootless** with an **immutable root filesystem**, **no capabilities**, and **no privilege escalation path** — see [Security model](#security-model).

## Files

| File | Purpose | Goes where |
|---|---|---|
| `Containerfile` | The image definition | anywhere you build from |
| `devbox.bash` | `devbox`, `devbox-build`, `devbox-stop`, `devbox-delete` shell functions | sourced from `~/.zshrc` |

## Prerequisites

- Rootless podman, i.e. installed and run as your normal user, never via `sudo`. Verify with `podman info --format '{{.Host.Security.Rootless}}'` — must print `true`.
- Subordinate UID/GID ranges for your user (most distro packages set this up; check that `grep $USER /etc/subuid` returns a line).
- A parent directory that holds (or will hold) your projects. These instructions assume `~/workspace`; substitute your own throughout.

## 1. Install the shell functions

From the directory containing `devbox.bash`, add a source line to your `~/.zshrc` and reload:

```sh
echo "source $PWD/devbox.bash" >> ~/.zshrc
source ~/.zshrc
```

(Keeping the file in place and sourcing it — rather than copy-pasting its contents — means later updates to the file take effect on the next shell. The functions are bash- and zsh-compatible.)

Then adjust the default workspace if yours isn't `~/workspace` — either edit the `DEVBOX_PROJECT` default inside the function, or export it in your profile:

```sh
export DEVBOX_PROJECT="$HOME/code"
```

Build the image (from the directory containing the `Containerfile`):

```sh
devbox-build
```

and start the container:

```sh
devbox
```

Usage (`-h` prints this too):

```sh
devbox                       # interactive zsh, workspace mounted at ~/workspace
devbox -i myimage            # different image
devbox -p ~/other/workspace  # different workspace dir
devbox make test             # trailing args run as the container command
devbox (again, elsewhere)    # 2nd+ terminal: opens a shell in the SAME container
devbox-build                 # (re)build the image from the current dir
devbox-stop                  # stop running devbox containers (kills sessions)
devbox-delete                # remove image + its containers (volumes kept)
devbox-delete -v             # ... and also remove the devbox-* volumes
```

### Editor in the container: minimum steps (VSCodium + open-remote-ssh)

The four steps from zero to an editor whose terminal, language servers, and extensions all run inside the container (background and troubleshooting in step 5 below):

1. Install [VSCodium](https://vscodium.com) (distro package, Flatpak, or the release tarball).
2. In VSCodium, install the **Open Remote - SSH** extension (`jeanp413.open-remote-ssh`, on Open VSX).
3. Add this to `~/.ssh/config` (details on each line in step 5):

   ```
   Host devbox
       HostName 127.0.0.1
       Port 2222
       User devbox
       IdentityFile ~/.ssh/devbox_ed25519
       IdentitiesOnly yes
       UserKnownHostsFile ~/.ssh/known_hosts_devbox
       StrictHostKeyChecking accept-new
   ```

4. With the container running (`devbox` in any terminal): command palette → **"Remote-SSH: Connect to Host..." → devbox**, then open `/home/devbox/workspace`.

First connect downloads the editor's remote server into the container (needs a minute and network); install language extensions "in the remote" when prompted. Sanity check when anything fails: `ssh devbox` from a terminal.

### Multiple terminals

`devbox` keeps **one shared container per image name**: the first invocation creates and owns it; every further `devbox` (or `devbox some-command`) from any terminal opens an additional shell/process in that same container via `podman exec` — shared filesystem, processes, and ports.

The first terminal owns the container's lifetime: when that shell exits (or on `devbox-stop`), the container stops and every attached session dies with it (`/tmp` contents evaporate too, as usual). Exit the extra shells like any other; only the first one tears things down. For long-lived sessions where that coupling is annoying, `tmux` is installed in the image — one `devbox`, multiple tmux windows — which also survives host terminal-emulator crashes.

Because mounts and ports are fixed when a container starts, `-p` on an attach is ignored (a notice is printed). To use a different workspace or image concurrently, use a different image tag (`-i`), which gets its own container.

### Per-workspace shell config

Container shells also source `~/workspace/.zshrc` (i.e. `<workspace>/.zshrc` on the host — `devbox` creates it empty on first run). Since the container's own `~/.zshrc` is read-only image content, this file is the place for aliases, env vars, and prompt tweaks that should survive rebuilds without baking them into the image. It loads after the image's config, so it can override anything. Edit it from either side; changes apply to new shells.


## 2. Selecting components and versions

Every runtime and agent is optional and version-pinnable. `devbox-build` passes `DEVBOX_<ARG>` environment variables straight through as the Containerfile's build args — the variable name is the build arg name with a `DEVBOX_` prefix, nothing else to remember. Unset variables leave the defaults (latest / installed) in effect:

| Variable | Component | Values |
|---|---|---|
| `DEVBOX_NODE_VERSION` | Node.js | version, `latest`, `false` |
| `DEVBOX_PNPM_VERSION` | pnpm | version, `latest`, `false` |
| `DEVBOX_NX_VERSION` | nx | version, `latest`, `false` |
| `DEVBOX_RUST_VERSION` | Rust | version (e.g. `1.94`), `latest`, `false` |
| `DEVBOX_GO_VERSION` | Go | version, `latest`, `false` |
| `DEVBOX_ZIG_VERSION` | Zig | version, `latest`, `false` |
| `DEVBOX_OMP_INSTALL` | omp agent | `true`, `false` |
| `DEVBOX_CLAUDE_CODE_VERSION` | Claude Code agent | version, `latest`, `false` |

Examples:

```sh
# match a project's .tool-versions
DEVBOX_NODE_VERSION=24.11.0 DEVBOX_PNPM_VERSION=11.0.8 DEVBOX_RUST_VERSION=1.94 devbox-build

# lean JS-only image
DEVBOX_RUST_VERSION=false DEVBOX_GO_VERSION=false DEVBOX_ZIG_VERSION=false devbox-build
```

Export them in your profile to make a selection permanent. `pnpm`/`nx` require Node (the build fails with a clear error if Node is disabled but they aren't).

All toolchains are installed at build time because the container's root filesystem is read-only at runtime. This is the workflow's central rule: **to add or update a tool, edit the Containerfile and rebuild** — there is deliberately no `sudo apt install` inside a running container. Rebuilds are fast thanks to layer caching.

Toolchain versions are controlled by `ARG`s at the top of the Containerfile — each defaults to the latest release (resolved at build time), can be pinned to an exact version, or disabled with `false`. To match a project's `.tool-versions`/`mise.toml`, set the `DEVBOX_<ARG>` variables (or edit the `ARG` defaults) and rebuild. Note the toolchains are installed system-wide and version managers are not part of the image — a project's `.tool-versions`/`mise.toml` is not enforced inside the container, so keeping the `ARG`s in sync with the projects is a manual responsibility.

## 3. pnpm store and gitignore

The image pins pnpm's content-addressable store to `~/workspace/.pnpm-store` (container-side). This keeps the store and every project's `node_modules` on the **same mount**, which is what allows pnpm's hard-linked, deduplicated installs (hard links can't cross mount boundaries). All projects under the workspace share one store, persisted on the host at `~/workspace/.pnpm-store` — the host and container paths mirror each other.

Add it to your global gitignore so a repo never accidentally tracks it:

```sh
git config --global core.excludesFile ~/.gitignore
echo '.pnpm-store/' >> ~/.gitignore
```

## 4. Agent logins (omp, Claude Code)

Each agent's config and credentials live in its own named volume (`devbox-omp`, `devbox-claude`), so you log in once and it persists across containers:

```sh
devbox omp      # then authenticate via /login inside omp
devbox claude   # follow the login flow (it prints a URL to open on the host;
                # paste the code back — the container has no browser)
```

Never bake API keys into the image or mount your host agent config dirs — the volumes keep credentials container-side only.

## 5. Editor integration (open-remote-ssh)

Language servers for Rust/Go/Zig need the container's toolchains and caches, so the editor connects *into* the running container over SSH using [Open Remote - SSH](https://github.com/jeanp413/open-remote-ssh) (`jeanp413.open-remote-ssh`, on Open VSX — the open Remote-SSH implementation for VSCodium).

How the plumbing works: the image runs a user-level `sshd` on port 2222 (key-auth only, published to `127.0.0.1` on the host). `devbox` generates a dedicated keypair `~/.ssh/devbox_ed25519` on first run and mounts its public half as the container's `authorized_keys` (via an SELinux-labeled copy in `~/.config/devbox/` — mounting from `~/.ssh` directly would either be unreadable in the container on SELinux hosts, or require relabeling `~/.ssh`; both bad). The sshd host key persists on the `devbox-state` volume, so the container's identity is stable across restarts. The editor's remote server installs into the `devbox-vscodium` volume.

One-time setup:

1. Install the **Open Remote - SSH** extension from Open VSX, and enable its proposed API: run **"Preferences: Configure Runtime Arguments"**, add `"enable-proposed-api": ["jeanp413.open-remote-ssh"]` to `argv.json`, and restart the editor.
2. Add a host entry to `~/.ssh/config`:

```
Host devbox
    HostName 127.0.0.1
    Port 2222
    User devbox
    IdentityFile ~/.ssh/devbox_ed25519
    IdentitiesOnly yes
    UserKnownHostsFile ~/.ssh/known_hosts_devbox
    StrictHostKeyChecking accept-new
```

Why the non-obvious lines: `IdentitiesOnly yes` stops ssh from offering every key in your agent first — with several keys loaded, sshd's auth-attempt limit can reject the connection before the right key is tried. The separate `UserKnownHostsFile` keeps the container's host key out of your main `known_hosts`; after `devbox-delete -v` (which deletes the state volume holding the host key), just remove that one file. `StrictHostKeyChecking accept-new` trusts the key on first connect but still errors if it later changes.

Daily use: start the container (`devbox` in any terminal — the SSH daemon starts with it), then in the editor: **"Remote-SSH: Connect to Host..." → devbox**, and open `/home/devbox/workspace`. The extension reads the same `~/.ssh/config`, so no extension-side host configuration is needed. Install rust-analyzer, gopls, and the Zig extension *in the remote* when prompted — they run container-side with the container's toolchains. Plain `ssh devbox` from a terminal exercises the identical path, which makes it the first diagnostic: if it works and the editor doesn't, the problem is extension setup (usually the `argv.json` step or a missed editor restart), not SSH.

Notes:

- The container must be running before the editor connects; when the owning `devbox` shell exits, the SSH session and editor connection drop with it.
- sshd runs as the unprivileged `devbox` user — it can only ever log in as that user, fits the no-root/no-caps model, and its failure is non-fatal to the shell (check `/tmp/sshd.log` in the container if connecting fails).
- The dedicated keypair means no reuse of your personal SSH keys; the private key never enters the container, and auth is possible only from your host user account.

## Ports

Container ports **3000–3999** are published to the host, so a dev server listening on e.g. `:3000` inside the container is reachable at `http://localhost:3000` on the host. Two things to know:

- Inside the container, bind servers to `0.0.0.0` (or `::`), not `127.0.0.1` — the container's loopback is separate from the host's, so a server bound only to the container's localhost is unreachable through the published port. Most dev servers have a `--host 0.0.0.0` flag.
- On the host side the ports are bound to `127.0.0.1` only, so nothing is exposed to your LAN.
- Port **2222** is additionally published for the container's SSH daemon (editor access, see step 5).

Ports outside the range aren't reachable; widen or change the range in `devbox.bash` if needed. (The editor's SSH connection can additionally tunnel arbitrary ports on demand, independent of this range.)

## Persistent state (named volumes)

Everything outside the workspace mount that needs to survive restarts lives in podman named volumes — container-managed, never host paths:

| Volume | Mounted at | Holds |
|---|---|---|
| `devbox-cache` | `~/.cache` | cargo registry + bins, Go module cache + bins, npm cache + globals, pnpm globals |
| `devbox-omp` | `~/.omp` | omp credentials and config |
| `devbox-claude` | `~/.claude` | Claude Code credentials and config |
| `devbox-state` | `~/.local/state` | zsh history, sshd host key, misc state |
| `devbox-vscodium` | `~/.vscodium-server` | editor remote server + container-side extensions |

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
- When the editor is connected over SSH, its remote extension host shares the container boundary with the agent; the host remains protected, but IDE-vs-agent separation inside the container does not exist. Disconnecting the editor restores an IDE-free container when stricter separation is wanted.
- Resource ceilings (`--pids-limit 4096`, `--memory 8g`) are runaway-process insurance; tune per machine.

Rules that keep the model intact: never run via `sudo podman`, never add `--privileged`, never mount the podman socket into the container, and mount credentials only as named volumes, not host paths.

## Troubleshooting

- **pnpm falls back to copying instead of hard links** — you ran pnpm outside `/workspace` scope or the store dir moved; verify `pnpm config get store-dir` prints `/home/devbox/workspace/.pnpm-store` inside the container.
- **Editor fails to connect over SSH** — first check plain `ssh devbox` from a terminal. Container not running → start `devbox`. Connection refused → sshd didn't start; check `/tmp/sshd.log` inside the container. Auth failure → verify the keypair exists (`~/.ssh/devbox_ed25519`) and the container was started by the current `devbox` (`podman inspect devbox` should show the `authorized_keys` mount). If `cat ~/.ssh/authorized_keys` *inside* the container gives permission denied, that's the SELinux signature of an unlabeled mount — restart with the current `devbox`, which mounts a labeled copy. Host-key warning after `devbox-delete -v` → the host key lived on the deleted state volume; clear `~/.ssh/known_hosts_devbox`. Server install issues → `podman volume rm devbox-vscodium` for a fresh install.
- **Permission denied writing to ~/workspace in the container, or wrong ownership** — the `devbox` function must run with `--userns=keep-id:uid=1000,gid=1000` (already present). Without it, rootless podman's default mapping makes mounted files appear root-owned inside the container, and the unprivileged `devbox` user cannot write them.
- **Network failures inside builds** — corporate proxies/DNS: pass `--network=host` to `podman build` only (build-time, not runtime) or configure proxy env via `--build-arg`.

## Updating

- **Toolchains**: bump the `ARG` pins at the top of the Containerfile, rebuild, restart containers. Caches in `devbox-cache` carry over.
- **omp**: installed via its official installer at build time; rebuilding picks up the latest release.
- **Base image**: `podman build --pull ...` to refresh Ubuntu layers for security updates; worth doing periodically.