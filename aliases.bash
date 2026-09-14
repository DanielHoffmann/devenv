export EDITOR='nano'
export VISUAL='nano'

alias qwen35='podman start llama-qwen35'
alias qwen35-stop='podman stop llama-qwen35'
alias qwen35-logs='podman logs -f llama-qwen35'

alias d=docker
alias p=podman

alias size='du -ch '

# iterm2 setup:
# Settings -> Profiles -> Advanced -> Semantic History
# Always run command: 
# source /Users/danielhoffmannbernardes/devenv/aliases.bash && vscodium_ssh_open "\1" "\5" "\(hostname)"
vscodium_ssh_open() {
  local file="$1"
  local base="$2"
  local hostname="$3"

  while [[ $base == */ ]]; do base="${base%/}"; done

  if [[ $file == app/* && $base =~ /js[0-9]*$ ]]; then
      file="apps/business/app/${file#app/}"
  fi
  local path="${base:+$base/}$file"
  if [[ $hostname == "0.0.0.0" ]]; then
      /opt/homebrew/bin/codium  --remote ssh-remote+devbox --goto "$path"
  else
      /opt/homebrew/bin/codium  --goto "$path"
  fi
}

unalias sg 2>/dev/null
sg() {
  grep --context=3 -- "$@"
}

unalias tcpport 2>/dev/null
tcpport() {
  lsof -nP -iTCP:"$1"
}

unalias _open_url 2>/dev/null
_open_url() {
  if command -v open >/dev/null 2>&1; then
    open "$1"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$1"
  else
    printf '%s\n' "$1"
  fi
}

unalias branch_name 2>/dev/null
branch_name() {
  git rev-parse --abbrev-ref HEAD
}

unalias issue_code 2>/dev/null
issue_code() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null \
    | grep -Eo '^(.*/)?([A-Z]{1,3}-[0-9]{1,4})' \
    | grep -Eo '([A-Z]{1,3}-[0-9]{1,4})' \
    | head -n 1
}

unalias project_name 2>/dev/null
project_name() {
  basename "$(git rev-parse --show-toplevel)"
}

alias gs='git status'
alias ga='git add'
alias gaa='git add --all'
alias gr='git reset'
alias grh='git reset --hard'
alias gd='git diff'
alias gp='git push'
alias gl='git log --decorate --graph --date=relative'
alias gcheck='git checkout'
alias gb='git branch'
alias gbd='git branch -d'
alias gf='git fetch'
alias gpull='git pull'
alias gtag='git tag'

unalias gdf 2>/dev/null
gdf() {
  git diff -- "*$1*"
}

unalias gdd 2>/dev/null
gdd() {
  git diff origin/master -- "*$1*"
}

unalias gcheckbranch 2>/dev/null
gcheckbranch() {
  git checkout -b "$1" "origin/$1"
}

unalias gc 2>/dev/null
gc() {
  local issue
  issue="$(issue_code)"
  if [ -n "$issue" ]; then
    git commit -m "$issue $*"
  else
    git commit -m "$*"
  fi
}

unalias gaac 2>/dev/null
gaac() {
  git add --all
  gc "$@"
}

unalias github 2>/dev/null
github() {
  _open_url "https://github.com/$ORG/$(project_name)/tree/$(branch_name)"
}

unalias gpr 2>/dev/null
gpr() {
  _open_url "https://github.com/$ORG/$(project_name)/compare/$(branch_name)?expand=1"
}