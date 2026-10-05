#!/bin/bash
set -euo pipefail
base="$(cd -- "$(dirname -- "$0")" && pwd)"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/Library/TeX/texbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
source "$base/privacy.env"
mkdir -p "$HOME/.local/bin" "$HOME/.config" "$HOME/.cache/zsh" "$HOME/.local/share/agent-vm" "$HOME/tools"
plan="$base/profile-plan"
/usr/bin/ruby "$base/../lib/profile-plan.rb" "$base/config.json" "$base/../packages" "$plan" "$@"
has_profile() { /usr/bin/grep -qx "$1" "$plan/profiles"; }

if [[ ! -x /opt/homebrew/bin/brew ]]; then
  HOMEBREW_NO_SUDO=1 NONINTERACTIVE=1 /bin/bash "$base/homebrew-install.sh"
fi
brew analytics off
brew update
if has_profile latex; then
  [[ -r /etc/agent-vm/admin-password ]] || { printf 'Guest administrator credential missing; run vm apply before adding LaTeX.\n' >&2; exit 1; }
  # Homebrew uses sudo -A when SUDO_ASKPASS is set. The helper only reads the
  # existing private guest credential; no password enters argv or logs.
  printf '#!/bin/sh\nexec /bin/cat /etc/agent-vm/admin-password\n' > "$plan/sudo-askpass"
  chmod 700 "$plan/sudo-askpass"
  trap 'rm -f "$plan/sudo-askpass"' EXIT
  export SUDO_ASKPASS="$plan/sudo-askpass"
  if [[ ! -x /Library/TeX/texbin/pdflatex ]]; then
    printf 'Full TeX Live is a multi-gigabyte download plus installation; this optional profile can take a while.\n'
  fi
fi
brew bundle --no-upgrade --file="$plan/Brewfile"
unset SUDO_ASKPASS

if [[ ! -x "$HOME/tools/python/bin/python" ]]; then
python_selector=$(/usr/bin/ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("python")' "$base/config.json")
python_version=$(uv python list --only-downloads --all-versions --output-format json "$python_selector" |
  /usr/bin/ruby "$base/../lib/python-version.rb")
uv python install "$python_version" --default
desired_python=$(uv python find --managed-python --system --no-project "$python_version")
uv venv --python "$desired_python" "$HOME/tools/python"
fi
# Keep default Python checks importable as well as executable. Project virtual
# environments remain separate and supply their own development dependencies.
uv pip install --python "$HOME/tools/python/bin/python" -r "$plan/python.txt"

packages=()
while IFS= read -r package; do
  [[ -z "$package" || "$package" == \#* ]] && continue
  # Adding a profile must not upgrade unrelated tools already installed.
  [[ -f "/opt/homebrew/lib/node_modules/$package/package.json" ]] || packages+=("$package@latest")
done < "$plan/npm.txt"
if (( ${#packages[@]} )); then
  npm install -g --include=optional --allow-scripts=bun,pnpm,esbuild "${packages[@]}"
fi
if has_profile build; then
  rustup set profile default
  rustup default stable
  rustup component add rustfmt clippy
  git lfs install --skip-repo
fi

"$HOME/tools/python/bin/python" "$base/privacy-user.py"
"$HOME/tools/python/bin/python" "$base/configure.py" "$base/config.json"
# On a profile addition agent versions remain under their own management.
if (( $# == 0 )); then /bin/bash "$base/install-agents.sh"; fi
uv generate-shell-completion zsh > "$HOME/.local/share/agent-vm/_uv"
chmod go-w /opt/homebrew/share
if has_profile latex; then
  # The successful package installation leaves a multi-gigabyte download.
  # Scope cleanup to this cask; keep other guest package caches untouched.
  brew cleanup --prune=all mactex-no-gui
fi

{
  date -u
  sw_vers
  brew list --versions
  npm list -g --depth=0
  "$HOME/tools/python/bin/python" --version
  uv pip freeze --python "$HOME/tools/python/bin/python"
  if command -v rustc >/dev/null; then rustc --version; fi
} > "$HOME/.local/share/agent-vm/versions.txt"
printf 'Selected tool profiles installed.\n'
