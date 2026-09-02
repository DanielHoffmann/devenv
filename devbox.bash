# devbox — hardened podman dev container launcher
# bash- and zsh-compatible; source this file from ~/.zshrc (or ~/.bash_profile).
# Mounts the PARENT directory holding your projects at ~/shared in the
# container.
# Fallback defaults via env: DEVBOX_IMAGE, DEVBOX_PROJECT
devbox() {
  local image="${DEVBOX_IMAGE:-devbox}"
  local project="${DEVBOX_PROJECT:-$HOME/shared}"   # <- adjust to your layout
  local project_explicit=0

  local OPTIND opt
  while getopts ":i:p:h" opt; do
    case "$opt" in
      i) image="$OPTARG" ;;
      p) project="$OPTARG"; project_explicit=1 ;;
      h)
        echo "usage: devbox [-i image] [-p project_dir] [command...]" >&2
        return 0
        ;;
      \?)
        echo "devbox: unknown option -$OPTARG (use -h)" >&2
        return 2
        ;;
      :)
        echo "devbox: option -$OPTARG requires an argument" >&2
        return 2
        ;;
    esac
  done
  shift $((OPTIND - 1))

  if [[ ! -d "$project" ]]; then
    mkdir -p "$project"
  fi
  # resolve to an absolute path (podman requires one for bind mounts)
  project="$(cd "$project" && pwd)"

  # per-workspace shell config, sourced by the container's ~/.zshrc
  [[ -f "$project/.zshrc" ]] || touch "$project/.zshrc"

  # dedicated keypair for SSH access into the container (editor remoting)
  local sshkey="$HOME/.ssh/devbox_ed25519"
  if [[ ! -f "$sshkey" ]]; then
    if ! command -v ssh-keygen >/dev/null; then
      echo "devbox: ssh-keygen not found (install openssh-client)" >&2
      return 1
    fi
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -q -t ed25519 -N "" -C "devbox" -f "$sshkey" || return 1
  fi
  # mount a COPY of the public key from a devbox-owned dir, not ~/.ssh itself:
  # the mount is SELinux-labeled (:Z), and relabeling must never touch ~/.ssh.
  local akeys="$HOME/.config/devbox/authorized_keys"
  mkdir -p "$HOME/.config/devbox"
  cp -f "${sshkey}.pub" "$akeys"

  # One shared container per image name: if it's already running, open
  # another shell in it (podman exec) instead of creating a second container.
  local name="$image"
  if [[ -n "$(podman ps -q --filter "name=^${name}$")" ]]; then
    (( project_explicit )) && \
      echo "devbox: note: container '$name' already running; -p ignored (mounts are fixed at start)" >&2
    if [[ $# -gt 0 ]]; then
      podman exec -it "$name" "$@"
    else
      podman exec -it "$name" zsh -l
    fi
    return
  fi

  podman run -it --rm --name "$name" \
    `# --- privilege reduction ---` \
    --cap-drop=all \
    --security-opt no-new-privileges \
    `# map host user -> container devbox (uid 1000) so workspace files` \
    `# are owned by you on both sides` \
    --userns=keep-id:uid=1000,gid=1000 \
    `# --- immutable root filesystem ---` \
    --read-only \
    --read-only-tmpfs=false \
    --tmpfs /tmp:rw,exec,size=2g \
    `# --- writable carve-outs ---` \
    `# workspace (parent of your projects): the ONLY host path exposed` \
    -v "${project}:/home/devbox/shared:Z" \
    `# named volumes (container-managed, not host paths):` \
    `# container-private workspace: persists across restarts but is never` \
    `# visible on the host (unlike ~/shared); also holds the pnpm store` \
    -v "${image}-workspace:/home/devbox/workspace" \
    `# general application data` \
    -v "${image}-share:/home/devbox/.local" \
    -v "${image}-cache:/home/devbox/.cache" \
    -v "${image}-config:/home/devbox/.config" \
    `# omp credentials survive restarts; log in once with: omp /login` \
    -v "${image}-omp:/home/devbox/.omp" \
    `# Claude Code config/credentials; log in once with: claude` \
    -v "${image}-claude:/home/devbox/.claude" \
    `# editor remote server (open-remote-ssh installs it here)` \
    -v "${image}-vscodium:/home/devbox/.vscodium-server" \
    `# ssh keys generated INSIDE the container (plus known_hosts, config);` \
    `# never sees the host's ~/.ssh` \
    -v "${image}-ssh:/home/devbox/.ssh" \
    `# public half of the devbox keypair, for sshd key auth (read-only,` \
    `# SELinux-labeled; a copy in ~/.config/devbox, never ~/.ssh itself).` \
    `# Mounted INTO the ssh volume above (podman orders mounts by path depth),` \
    `# so login keys stay host-controlled while the rest of ~/.ssh is writable` \
    -v "${akeys}:/home/devbox/.ssh/authorized_keys:ro,Z" \
    `# --- network: dev servers reachable at http://localhost:PORT ---` \
    `# bound to 127.0.0.1 so they are NOT exposed to your LAN` \
    -p 127.0.0.1:3000-3999:3000-3999 \
    `# sshd, for editor access: ssh -p 2222 devbox@localhost` \
    -p 127.0.0.1:2222:2222 \
    `# --- resource ceilings (tune or delete to taste) ---` \
    --pids-limit 4096 \
    --memory 8g \
    "$image" "$@"
}

# devbox-build — (re)build the devbox image
# Containerfile location: arg > current dir
# Component selection via env: DEVBOX_<ARG> for any build ARG of the image,
# e.g. DEVBOX_NODE_VERSION, DEVBOX_RUST_VERSION, DEVBOX_OMP_INSTALL — the
# prefix is dropped and the rest passed through as --build-arg verbatim.
# Unset variables leave the Containerfile defaults in effect.
devbox-build() {
  local image="${DEVBOX_IMAGE:-devbox}"
  local src="$PWD"

  local OPTIND opt
  while getopts ":i:h" opt; do
    case "$opt" in
      i) image="$OPTARG" ;;
      h) echo "usage: devbox-build [-i image] [containerfile_dir]" >&2; return 0 ;;
      \?) echo "devbox-build: unknown option -$OPTARG (use -h)" >&2; return 2 ;;
      :) echo "devbox-build: option -$OPTARG requires an argument" >&2; return 2 ;;
    esac
  done
  shift $((OPTIND - 1))
  [[ $# -ge 1 ]] && src="$1"

  if [[ ! -f "$src/Containerfile" ]]; then
    echo "devbox-build: no Containerfile in: $src (pass a dir containing one)" >&2
    return 1
  fi

  # DEVBOX_<ARG> env vars -> --build-arg <ARG>=<value>, names passed through
  # (indirection via eval: portable across bash and zsh; names come from the
  #  fixed list below, never user input)
  local build_args=() var arg val
  for arg in NODE_VERSION PNPM_VERSION NX_VERSION GRAPHITE_VERSION RUST_VERSION GO_VERSION ZIG_VERSION OMP_INSTALL CLAUDE_CODE_VERSION; do
    var="DEVBOX_${arg}"
    eval "val=\${${var}:-}"
    if [[ -n "$val" ]]; then
      build_args+=(--build-arg "${arg}=${val}")
    fi
  done

  podman build "${build_args[@]}" -t "$image" "$src"
}

# devbox-stop — stop all running containers of the devbox image.
# Containers are started with --rm, so stopping also removes them; attached
# shells and editor SSH sessions are terminated.
devbox-stop() {
  local image="${DEVBOX_IMAGE:-devbox}"

  local OPTIND opt
  while getopts ":i:h" opt; do
    case "$opt" in
      i) image="$OPTARG" ;;
      h) echo "usage: devbox-stop [-i image]" >&2; return 0 ;;
      \?) echo "devbox-stop: unknown option -$OPTARG (use -h)" >&2; return 2 ;;
      :) echo "devbox-stop: option -$OPTARG requires an argument" >&2; return 2 ;;
    esac
  done
  shift $((OPTIND - 1))

  local containers
  containers="$(podman ps -q --filter "ancestor=$image")"
  if [[ -z "$containers" ]]; then
    echo "devbox-stop: no running '$image' containers"
    return 0
  fi
  printf '%s\n' $containers | xargs -r podman stop
}

# devbox-delete — remove the devbox image and any containers created from it.
# Named volumes (caches, credentials, container-side ssh keys, state) are
# KEPT unless -v is given.
devbox-delete() {
  local image="${DEVBOX_IMAGE:-devbox}"
  local rm_volumes=0

  local OPTIND opt
  while getopts ":i:vh" opt; do
    case "$opt" in
      i) image="$OPTARG" ;;
      v) rm_volumes=1 ;;
      h) echo "usage: devbox-delete [-i image] [-v: also remove the image's <image>-* volumes]" >&2; return 0 ;;
      \?) echo "devbox-delete: unknown option -$OPTARG (use -h)" >&2; return 2 ;;
      :) echo "devbox-delete: option -$OPTARG requires an argument" >&2; return 2 ;;
    esac
  done
  shift $((OPTIND - 1))

  local containers
  containers="$(podman ps -aq --filter "ancestor=$image")"

  local summary="image '$image'"
  [[ -n "$containers" ]] && summary+=", $(wc -w <<<"$containers") container(s)"
  (( rm_volumes )) && summary+=", ${image}-* volumes"
  echo "Will remove: $summary"
  local answer
  printf 'Proceed? [y/N] '
  read -r answer
  [[ "$answer" == [yY]* ]] || { echo "aborted"; return 1; }

  if [[ -n "$containers" ]]; then
    # xargs -r: no-op when the list is empty
    printf '%s\n' $containers | xargs -r podman rm -f
  fi
  podman image exists "$image" && podman rmi "$image"

  if (( rm_volumes )); then
    # volumes are named ${image}-<suffix> by devbox(); escape '.' so the
    # image name is matched literally (volume names only allow [a-zA-Z0-9_.-])
    local pattern
    pattern="$(printf '%s' "$image" | sed 's/\./\\./g')"
    podman volume ls -q | grep -E "^${pattern}-" | xargs -r podman volume rm
  fi
}