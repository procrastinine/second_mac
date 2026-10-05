HISTFILE=$HOME/.zsh_history
HISTSIZE=50000
SAVEHIST=50000
setopt APPEND_HISTORY INC_APPEND_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE
setopt AUTO_CD INTERACTIVE_COMMENTS
fpath=($HOME/.local/share/agent-vm /opt/homebrew/share/zsh-completions /opt/homebrew/share/zsh/site-functions $fpath)
autoload -Uz compinit
compinit -d "$HOME/.cache/zsh/zcompdump"
zstyle ':completion:*' menu select
bindkey -e
PROMPT='%F{green}%n@%m%f %F{blue}%~%f %# '
source /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
eval "$(fzf --zsh)"
eval "$(zoxide init zsh)"
