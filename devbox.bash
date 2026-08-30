# devbox — hardened podman dev container launcher
# Mounts the PARENT directory holding your projects at ~/workspace in the
# container (pnpm store lives at ~/workspace/.pnpm-store — add .pnpm-store/
# to your global gitignore).
# Fallback defaults via env: DEVBOX_IMAGE, DEVBOX_PROJECT
devbox() {
  local image="${DEVBOX_IMAGE:-devbox}"
  local project="${DEVBOX_PROJECT:-$HOME/workspace}"   # <- adjust to your layout
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
    echo "devbox: project dir not found: $project" >&2
    return 1
  fi
  # resolve to an absolute path (podman requires one for bind mounts)
  project="$(cd "$project" && pwd)"

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
    `# are owned by you on both sides (matches devcontainer.json)` \
    --userns=keep-id:uid=1000,gid=1000 \
    `# --- immutable root filesystem ---` \
    --read-only \
    --read-only-tmpfs=false \
    --tmpfs /tmp:rw,exec,size=2g \
    `# --- writable carve-outs ---` \
    `# workspace (parent of your projects): the ONLY host path exposed` \
    -v "${project}:/home/devbox/workspace:Z" \
    `# named volumes (container-managed, not host paths):` \
    `#   dependency & build caches (cargo registry, go modules, npm, pnpm bins)` \
    -v devbox-cache:/home/devbox/.cache \
    `#   omp credentials survive restarts; log in once with: omp /login` \
    -v devbox-omp:/home/devbox/.omp \
    `#   shell history and misc state` \
    -v devbox-state:/home/devbox/.local/state \
    `# --- network: dev servers reachable at http://localhost:PORT ---` \
    `# bound to 127.0.0.1 so they are NOT exposed to your LAN` \
    -p 127.0.0.1:3000-3999:3000-3999 \
    `# --- resource ceilings (tune or delete to taste) ---` \
    --pids-limit 4096 \
    --memory 8g \
    "$image" "$@"
}

# devbox-build — (re)build the devbox image
# Containerfile location: arg > current dir
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
  podman build -t "$image" "$src"
}

# devbox-delete — remove the devbox image and any containers created from it.
# Named volumes (caches, omp credentials, state) are KEPT unless -v is given.
devbox-delete() {
  local image="${DEVBOX_IMAGE:-devbox}"
  local rm_volumes=0

  local OPTIND opt
  while getopts ":i:vh" opt; do
    case "$opt" in
      i) image="$OPTARG" ;;
      v) rm_volumes=1 ;;
      h) echo "usage: devbox-delete [-i image] [-v: also remove devbox-* volumes]" >&2; return 0 ;;
      \?) echo "devbox-delete: unknown option -$OPTARG (use -h)" >&2; return 2 ;;
      :) echo "devbox-delete: option -$OPTARG requires an argument" >&2; return 2 ;;
    esac
  done
  shift $((OPTIND - 1))

  local containers
  containers="$(podman ps -aq --filter "ancestor=$image")"

  local summary="image '$image'"
  [[ -n "$containers" ]] && summary+=", $(wc -w <<<"$containers") container(s)"
  (( rm_volumes )) && summary+=", devbox-* volumes"
  echo "Will remove: $summary"
  local answer
  read -r -p "Proceed? [y/N] " answer
  [[ "$answer" == [yY]* ]] || { echo "aborted"; return 1; }

  if [[ -n "$containers" ]]; then
    # xargs -r: no-op when the list is empty
    printf '%s\n' $containers | xargs -r podman rm -f
  fi
  podman image exists "$image" && podman rmi "$image"

  if (( rm_volumes )); then
    podman volume ls -q | grep -E '^devbox-' | xargs -r podman volume rm
  fi
}