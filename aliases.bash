export EDITOR='nano'
export VISUAL='nano'

alias d=docker
alias p=podman
alias size="du -ch "
alias sg='grep $1 --context=3'
alias branch_name='git rev-parse --abbrev-ref HEAD'
alias issue_code='git rev-parse --abbrev-ref HEAD | egrep -o "^(.*\/)?([A-Z]{0,3}-[0-9]{0,4})" | egrep -o "([A-Z]{0,3}-[0-9]{0,4})" | head -n 1'
alias project_name='basename `git rev-parse --show-toplevel`'
alias gs='git status'
alias ga='git add'
alias gaa='git add --all'
alias gr='git reset'
alias grh='git reset --hard'
alias gd='git diff'
gdf() { git diff '*'$1'*'; }
gdd() { git diff origin/master -- '*'$1'*' }
tcpport() {
  lsof -nP -iTCP:$1
}
gc() {
  local ISSUE_CODE="$(issue_code)"
  git commit -m "$ISSUE_CODE $*";
}
gaac() {
  git add --all;
  local ISSUE_CODE="$(issue_code)"
  git commit -m "$ISSUE_CODE $*";
}
alias gp='git push'
alias gl='git log --decorate --graph --date=relative'
alias gcheck='git checkout'
gcheckbranch() { git checkout -b $1 origin/$1; }
alias gb='git branch'
alias gbd='git branch -d'
alias gf='git fetch'
alias gpull='git pull'
alias gt='git tag'
github() {
  local PROJECT_NAME="$(project_name)"
  local BRANCH_NAME="$(branch_name)"
  open "https://github.com/$ORG/$PROJECT_NAME/tree/$BRANCH_NAME"
}
gpr() {
  local BRANCH_NAME="$(branch_name)"
  local PROJECT_NAME="$(project_name)"
  open "https://github.com/$ORG/$PROJECT_NAME/compare/$BRANCH_NAME?expand=1"
}