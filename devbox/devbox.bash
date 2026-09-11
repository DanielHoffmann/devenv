# devbox — hardened podman dev container launcher
# bash- and zsh-compatible; source this file from ~/.zshrc (or ~/.bash_profile).
# Mounts the PARENT directory holding your projects at ~/shared in the
# container.
# Fallback defaults via env: DEVBOX_IMAGE, DEVBOX_PROJECT
devbox() {
  local image="${DEVBOX_IMAGE:-devbox}"
  local shared="${DEVBOX_PROJECT:-$HOME/$image}"
  local project_explicit=0

  local OPTIND opt
  while getopts ":i:p:h" opt; do
    case "$opt" in
      i) image="$OPTARG" ;;
      p) shared="$OPTARG"; project_explicit=1 ;;
      h)
        echo "usage: devbox [-i image] [-p project_dir] [command... | cd [dir]]" >&2
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

  if [[ ! -d "$shared" ]]; then
    mkdir -p "$shared"
  fi
  # resolve to an absolute path (podman requires one for bind mounts)
  shared="$(cd "$shared" && pwd)" || return 1

  # per-workspace shell config, sourced by the container's ~/.zshrc
  [[ -f "$shared/.zshrc" ]] || touch "$shared/.zshrc"

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

  # terminal identity forwarded from the host so tools inside the container
  # (colors, OSC sequences, editor integrations) see the real terminal.
  # `-e VAR` without a value copies the host's value and is skipped if unset.
  local term_env=(-e TERM -e TERM_PROGRAM -e TERM_PROGRAM_VERSION)

  # `devbox cd DIR` — open an interactive shell already in DIR instead of
  # running `cd` as a one-shot command (which would exit immediately).
  # DIR is a container path: absolute paths are used as-is, anything else
  # (including ~/…) is relative to the container home. `devbox cd` -> ~.
  local workdir=()
  if [[ $# -gt 0 && "$1" == "cd" ]]; then
    local dir="${2:-/home/devbox}"
    case "$dir" in
      /*)  ;;
      '~') dir="/home/devbox" ;;
      '~/'*) dir="/home/devbox/${dir#\~/}" ;;
      *)   dir="/home/devbox/$dir" ;;
    esac
    workdir=(-w "$dir")
    set -- zsh -l
  fi

  # One shared container per image name: if it's already running, open
  # another shell in it (podman exec) instead of creating a second container.
  local name="$image"
  if [[ -n "$(podman ps -q --filter "name=^${name}$")" ]]; then
    (( project_explicit )) && \
      echo "devbox: note: container '$name' already running; -p ignored (mounts are fixed at start)" >&2
    if [[ $# -gt 0 ]]; then
      podman exec -it "${term_env[@]}" "${workdir[@]}" "$name" "$@"
    else
      podman exec -it "${term_env[@]}" "$name" zsh -l
    fi
    return
  fi

  podman run -it --rm --name "$name" \
    "${term_env[@]}" \
    "${workdir[@]}" \
    `# --- privilege reduction ---` \
    --cap-drop=all \
    --security-opt no-new-privileges \
    `# map host user -> container devbox (uid 1000) so workspace files` \
    `# are owned by you on both sides` \
    --userns=keep-id:uid=1000,gid=1000 \
    `# --- immutable root filesystem ---` \
    --read-only \
    --read-only-tmpfs=false \
    --tmpfs /tmp:rw,exec,size=4g \
    `# writable, persistent home survives container restarts` \
    `# is never visible on the host.` \
    -v "${image}-home:/home/devbox/" \
    `# shared with the host` \
    -v "${shared}:/home/devbox/shared:Z" \
    `# ssh keys generated inside the container (id_*, known_hosts, config)` \
    `# in their own named volume, so they survive a home volume wipe and` \
    `# can be removed/backed up independently. ` \
    -v "${image}-ssh:/home/devbox/.ssh" \
    `# public half of the devbox keypair, for sshd key auth (read-only,` \
    `# SELinux-labeled; a copy in ~/.config/devbox, never ~/.ssh itself).` \
    `# Mounted INTO the ssh volume above (podman orders mounts by path depth),` \
    `# so login keys stay host-controlled while the rest of ~/.ssh is writable` \
    -v "${akeys}:/home/devbox/.ssh/authorized_keys:ro,Z" \
    `# --- network: dev servers reachable at http://localhost:PORT ---` \
    `# bound to 127.0.0.1 so they are NOT exposed to your LAN` \
    -p 127.0.0.1:3000-3005:3000-3005 \
    `# sshd, for editor access: ssh -p 2222 devbox@localhost` \
    -p 127.0.0.1:2222:2222 \
    `# --- resource ceilings (tune or delete to taste) ---` \
    --pids-limit 4096 \
    --memory 16g \
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
  for arg in NODE_VERSION PNPM_VERSION NX_VERSION GRAPHITE_VERSION RUST_VERSION GO_VERSION ZIG_VERSION PLAYWRIGHT_INSTALL OMP_INSTALL CLAUDE_INSTALL; do
    var="DEVBOX_${arg}"
    eval "val=\${${var}:-}"
    if [[ -n "$val" ]]; then
      build_args+=(--build-arg "${arg}=${val}")
    fi
  done

  echo build_args: "${build_args[@]}"
  echo ""
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

# devbox-delete — remove devbox state. Containers of the image are always
# removed first (volumes and images can't be deleted while in use).
#   devbox-delete        image only
#   devbox-delete -home  <image>-home volume only
#   devbox-delete -ssh   <image>-ssh volume + the host-side authorized_keys
#                        copy (~/.config/devbox/authorized_keys; regenerated
#                        on next start). Your ~/.ssh/devbox_ed25519 is kept.
#   devbox-delete -a     image + all <image>-* volumes + authorized_keys copy
# The host-shared project directory (~/shared in the container) is NEVER
# touched.
devbox-delete() {
  local image="${DEVBOX_IMAGE:-devbox}"
  local del_image=0 del_home=0 del_ssh=0 del_all=0

  # manual parsing: getopts can't do multi-letter flags like -home / -ssh
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i)
        [[ $# -ge 2 ]] || { echo "devbox-delete: option -i requires an argument" >&2; return 2; }
        image="$2"; shift 2 ;;
      -home) del_home=1; shift ;;
      -ssh)  del_ssh=1; shift ;;
      -a)    del_all=1; shift ;;
      -h)
        echo "usage: devbox-delete [-i image] [-home] [-ssh] [-a]" >&2
        echo "  (no flags)  remove the image only" >&2
        echo "  -home       remove the <image>-home volume" >&2
        echo "  -ssh        remove the <image>-ssh volume and the authorized_keys copy" >&2
        echo "  -a          remove the image and all <image>-* volumes" >&2
        return 0 ;;
      *) echo "devbox-delete: unknown option $1 (use -h)" >&2; return 2 ;;
    esac
  done
  if (( del_all )); then
    del_image=1; del_home=1; del_ssh=1
  elif (( ! del_home && ! del_ssh )); then
    del_image=1
  fi

  local akeys="$HOME/.config/devbox/authorized_keys"
  local containers
  containers="$(podman ps -aq --filter "ancestor=$image")"

  local items=()
  [[ -n "$containers" ]] && items+=("$(wc -w <<<"$containers" | tr -d ' ') container(s)")
  (( del_image )) && items+=("image '$image'")
  (( del_home ))  && items+=("volume '${image}-home'")
  (( del_ssh ))   && items+=("volume '${image}-ssh'" "file '$akeys'")
  if (( del_all )); then
    # any other ${image}-<suffix> volumes (escape '.' so the image name is
    # matched literally; volume names only allow [a-zA-Z0-9_.-])
    local pattern extra
    pattern="$(printf '%s' "$image" | sed 's/\./\\./g')"
    extra="$(podman volume ls -q | grep -E "^${pattern}-" | grep -vxE "${pattern}-(home|ssh)")"
    [[ -n "$extra" ]] && items+=("other volumes: $(tr '\n' ' ' <<<"$extra")")
  fi

  local summary="" item
  for item in "${items[@]}"; do
    summary+="${summary:+, }${item}"
  done
  echo "Will remove: $summary"
  local answer
  printf 'Proceed? [y/N] '
  read -r answer
  [[ "$answer" == [yY]* ]] || { echo "aborted"; return 1; }

  if [[ -n "$containers" ]]; then
    # xargs -r: no-op when the list is empty
    printf '%s\n' $containers | xargs -r podman rm -f
  fi

  (( del_image )) && podman image exists "$image" && podman rmi "$image"

  (( del_home )) && podman volume exists "${image}-home" && podman volume rm "${image}-home"

  if (( del_ssh )); then
    podman volume exists "${image}-ssh" && podman volume rm "${image}-ssh"
    rm -f "$akeys"
  fi

  if (( del_all )) && [[ -n "$extra" ]]; then
    printf '%s\n' $extra | xargs -r podman volume rm
  fi
  return 0
}

