#!/bin/bash
# Downloadable entry point. Keep modules/options in install.sh, not duplicated here.
set -euo pipefail

bootstrap_git() { /usr/bin/git "$@"; }
bootstrap_install() { /bin/sh "$1/install.sh" "${@:2}"; }
bootstrap_clt_ready() {
  /usr/bin/xcode-select -p >/dev/null 2>&1 &&
    /usr/bin/xcrun clang --version >/dev/null 2>&1 &&
    /usr/bin/xcrun swiftc --version >/dev/null 2>&1
}
bootstrap_brew_ready() {
  [[ -x /opt/homebrew/bin/brew ]] &&
    [[ $(HOMEBREW_NO_ANALYTICS=1 /opt/homebrew/bin/brew --prefix 2>/dev/null) == /opt/homebrew ]]
}

bootstrap_supported_host() {
  [[ $1 =~ ^[0-9]+([.][0-9]+)*$ ]] && (( ${1%%.*} >= 26 ))
}

bootstrap_dependencies() {
  [[ $(/usr/bin/uname -m) == arm64 ]] || { printf 'Apple Silicon is required.\n' >&2; return 1; }
  local version
  version=$(/usr/bin/sw_vers -productVersion)
  bootstrap_supported_host "$version" || { printf 'macOS 26 or later is required.\n' >&2; return 1; }
  (( EUID != 0 )) || { printf 'Run as your normal Mac account, without sudo.\n' >&2; return 1; }
  if ! bootstrap_clt_ready; then
    printf 'Installing Apple Command Line Tools on the host.\n'
    /usr/bin/sudo -v
    local marker=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    local catalog label marker_created=false
    if [[ ! -e "$marker" ]]; then /usr/bin/touch "$marker"; marker_created=true; fi
    catalog=$(/usr/sbin/softwareupdate --list 2>&1) || { [[ "$marker_created" == false ]] || /bin/rm -f "$marker"; printf '%s\n' "$catalog" >&2; return 1; }
    label=$(printf '%s\n' "$catalog" | /usr/bin/sed -n 's/.*Label: \(Command Line Tools.*\)/\1/p' | /usr/bin/tail -1)
    if [[ -z "$label" ]]; then
      [[ "$marker_created" == false ]] || /bin/rm -f "$marker"
      printf 'Apple did not list Command Line Tools. Run xcode-select --install, complete it, then rerun this command.\n' >&2
      return 1
    fi
    /usr/bin/sudo /usr/sbin/softwareupdate --install "$label" --verbose || { [[ "$marker_created" == false ]] || /bin/rm -f "$marker"; return 1; }
    [[ "$marker_created" == false ]] || /bin/rm -f "$marker"
    /usr/bin/sudo /usr/bin/xcode-select --switch /Library/Developer/CommandLineTools
    bootstrap_clt_ready || { printf 'Command Line Tools are not ready yet. Complete any pending Apple installation or permission prompt, then rerun this command.\n' >&2; return 1; }
  fi
  if ! bootstrap_brew_ready; then
    printf 'Installing Homebrew from its official installer.\n'
    /usr/bin/sudo -v
    local directory
    directory=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agent-vm-homebrew.XXXXXX")
    /usr/bin/curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
      --connect-timeout 20 --max-time 300 https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
      -o "$directory/install.sh" || { /bin/rm -rf "$directory"; return 1; }
    NONINTERACTIVE=1 HOMEBREW_NO_ANALYTICS=1 /bin/bash "$directory/install.sh" || { /bin/rm -rf "$directory"; return 1; }
    /bin/rm -rf "$directory"
    bootstrap_brew_ready || { printf 'Homebrew setup is incomplete. Rerun this command to continue its official installer.\n' >&2; return 1; }
  fi
  HOMEBREW_NO_ANALYTICS=1 /opt/homebrew/bin/brew analytics off
}

bootstrap_main() {
  local repository='procrastinine/second_mac' branch='' checkout='' plan=false
  local options=()
  while (( $# )); do
    case "$1" in
      --repo|--ref|--checkout)
        (( $# >= 2 )) || { printf '%s requires a value.\n' "$1" >&2; return 1; }
        case "$1" in
          --repo) repository=$2 ;;
          --ref) branch=$2 ;;
          --checkout) checkout=$2 ;;
        esac
        shift 2 ;;
      --plan) plan=true; options+=("$1"); shift ;;
      --help|-h)
        printf '%s\n' 'Usage: bootstrap.sh [--repo OWNER/REPOSITORY] [--ref BRANCH] [--checkout PATH] [install options...]' \
          'Default repository: procrastinine/second_mac; use --repo to install a fork.' \
          'Install options: --name NAME --user USER --profiles base|web,science,documents,media,build,latex|full' \
          '  --agents none|pi,codex,claude --cpus N --memory GiB --disk GB --menubar --ui' \
          '  --share PATH --guest-share NAME --sharing hybrid|macfuse|native|none --share-read-only' \
          '  --[no-]linked-files (default: detect ready host macFUSE) --[no-]audio-output' \
          '  --from-vm NAME --fresh --ipsw PATH --no-autologin --no-desktop-on-demand' \
          '  --source-mode git|local' \
          '--plan prints the bootstrap plan without downloading or installing anything.'
        return ;;
      *) options+=("$1"); shift ;;
    esac
  done
  [[ "$repository" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || {
    printf 'Supply the published GitHub repository as --repo OWNER/REPOSITORY.\n' >&2; return 1;
  }
  [[ -z "$branch" || "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9_./-]*$ ]] || { printf 'Invalid branch.\n' >&2; return 1; }
  local url="https://github.com/$repository.git"
  [[ -n "$checkout" ]] || checkout="${AGENT_VM_HOME:-$HOME/.local/share/agent-vm}/source/$repository"
  if [[ "$plan" == true ]]; then
    printf 'Ensure Apple host Command Line Tools and Homebrew, then fetch %s (%s) into %s.\n' "$url" "${branch:-default branch}" "$checkout"
    printf 'Installer options: '; printf '%q ' ${options[@]+"${options[@]}"}; printf '\n'
    return
  fi
  # Restore terminal input for sudo when the entry point arrives through a pipe.
  if [[ ! -t 0 && -t 1 ]]; then exec </dev/tty; fi
  umask 077
  export HOMEBREW_NO_ANALYTICS=1 DO_NOT_TRACK=1 OTEL_SDK_DISABLED=true
  trap 'result=$?; if [[ -n "${bootstrap_pending_checkout:-}" && -d "$bootstrap_pending_checkout" ]]; then /bin/rm -rf "$bootstrap_pending_checkout"; fi; if (( result != 0 )); then printf "Setup stopped. Complete any pending permissions, then rerun the same command; completed installation stages are retained.\n" >&2; fi' EXIT
  bootstrap_dependencies
  local clone_options=()
  [[ -z "$branch" ]] || clone_options+=(--branch "$branch")
  if [[ -e "$checkout" || -L "$checkout" ]]; then
    [[ -d "$checkout/.git" && ! -L "$checkout" ]] || { printf 'Checkout path is not a regular Git checkout.\n' >&2; return 1; }
    [[ $(bootstrap_git -C "$checkout" config --get remote.origin.url) == "$url" ]] || { printf 'Checkout belongs to a different repository.\n' >&2; return 1; }
    [[ -z $(bootstrap_git -C "$checkout" status --porcelain --untracked-files=all) ]] || { printf 'Checkout has local changes; preserve/resolve them before rerunning.\n' >&2; return 1; }
    if [[ -n "$branch" && $(bootstrap_git -C "$checkout" branch --show-current) != "$branch" ]]; then
      printf 'Existing checkout uses another branch; choose another --checkout.\n' >&2; return 1
    fi
    bootstrap_git -C "$checkout" fetch --prune origin
    bootstrap_git -C "$checkout" merge --ff-only '@{upstream}'
  else
    /bin/mkdir -p "$(/usr/bin/dirname "$checkout")"
    # Publish only a completed checkout, so an interrupted clone cannot block
    # the next invocation by leaving an unusable destination directory.
    bootstrap_pending_checkout=$(/usr/bin/mktemp -d "${checkout}.partial.XXXXXX")
    bootstrap_git clone ${clone_options[@]+"${clone_options[@]}"} "$url" "$bootstrap_pending_checkout" || return
    [[ -f "$bootstrap_pending_checkout/lib/install-cli.rb" && -f "$bootstrap_pending_checkout/install.sh" ]] || { printf 'Repository is missing the VM installer.\n' >&2; return 1; }
    /usr/bin/ruby -e 'File.rename(ARGV[0], ARGV[1])' "$bootstrap_pending_checkout" "$checkout" || return
    bootstrap_pending_checkout=''
  fi
  [[ -f "$checkout/lib/install-cli.rb" && -f "$checkout/install.sh" ]] || { printf 'Repository is missing the VM installer.\n' >&2; return 1; }
  bootstrap_install "$checkout" ${options[@]+"${options[@]}"}
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then bootstrap_main "$@"; fi
