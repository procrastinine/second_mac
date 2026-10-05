#!/bin/bash
set -euo pipefail
source "$HOME/.profile"
share=${1:?Pass the guest shared-directory path}
share=$(cd -- "$share" && pwd)
work=$(mktemp -d "$share/.agent-vm-check.XXXXXX")
trap 'rm -rf "$work"' EXIT
cd "$work"
printf '#include <stdio.h>\nint main(void) { puts("compiler-ok"); return 0; }\n' > hello.c
cc hello.c -o hello
test "$(./hello)" = compiler-ok
ln -s hello relative-link
test "$(./relative-link)" = compiler-ok
ln -s "$work/hello" absolute-link
test "$(./absolute-link)" = compiler-ok
ln -s not-created-yet dangling-link
test -L dangling-link && ! test -e dangling-link
git init -q
git -c user.name='VM test' -c user.email='test@example.invalid' add hello.c relative-link
git -c user.name='VM test' -c user.email='test@example.invalid' commit -qm 'Filesystem check'
git mv hello.c renamed.c
git diff --cached --exit-code --quiet && exit 1
uv venv .venv
uv pip install --python .venv/bin/python markupsafe
.venv/bin/python -c 'from markupsafe import escape; assert str(escape("<ok>")) == "&lt;ok&gt;"'
printf '{"private":true,"allowScripts":{"esbuild":true}}\n' > package.json
npm install --no-audit --no-fund esbuild
./node_modules/.bin/esbuild --version
printf 'Guest compiler, executable links, Git, uv venv, native Python wheel and npm binary checks passed.\n'
