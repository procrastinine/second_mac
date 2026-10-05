typeset -U path PATH
path=($HOME/tools/python/bin $HOME/.local/bin $HOME/.cargo/bin
      /opt/homebrew/opt/rustup/bin /opt/homebrew/opt/openjdk/bin
      /opt/homebrew/opt/sqlite/bin /opt/homebrew/opt/coreutils/libexec/gnubin
      /opt/homebrew/bin /opt/homebrew/sbin /Library/TeX/texbin $path)
if [[ -n ${VIRTUAL_ENV:-} && -d $VIRTUAL_ENV/bin ]]; then
  path=($VIRTUAL_ENV/bin $path)
fi
export JAVA_HOME=/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home
export HOMEBREW_NO_ANALYTICS=1 LANG=en_US.UTF-8 EDITOR=nvim MPLBACKEND=Agg
export DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib
export PLAYWRIGHT_MCP_CONFIG="$HOME/.config/playwright-brave.json"
