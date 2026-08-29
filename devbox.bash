# devbox — hardened podman dev container launcher
# Mounts the PARENT directory holding your projects (pnpm store lives at
# /workspace/.pnpm-store — add .pnpm-store/ to your global gitignore).
# Fallback defaults via env: DEVBOX_IMAGE, DEVBOX_PROJECT
devbox() {
  local image="${DEVBOX_IMAGE:-devbox}"
  local project="${DEVBOX_PROJECT:-$HOME/workspace}"   # <- adjust to your layout

  local OPTIND opt
  while getopts ":i:p:h" opt; do
    case "$opt" in
      i) image="$OPTARG" ;;
      p) project="$OPTARG" ;;
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

  podman run -it --rm \
    `# --- privilege reduction ---` \
    --cap-drop=all \
    --security-opt no-new-privileges \
    `# --- immutable root filesystem ---` \
    --read-only \
    --read-only-tmpfs=false \
    --tmpfs /tmp:rw,exec,size=2g \
    `# --- writable carve-outs ---` \
    `# workspace (parent of your projects): the ONLY host path exposed` \
    -v "${project}:/workspace:Z" \
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
    `# --- resource ceilings ---` \
    --pids-limit 4096 \
    --memory 8g \
    "$image" "$@"
}


devbox-build() {
  local image="${DEVBOX_IMAGE:-devbox}"
  while getopts ":i:p:h" opt; do
  case "$opt" in
    i) image="$OPTARG" ;;
    esac
  done
  podman build -t "$image" .
}