export ZSH=$HOME/.oh-my-zsh

if [ -d "$HOME/.oh-my-zsh/custom/themes/powerlevel10k" ]; then
    ZSH_THEME="powerlevel10k/powerlevel10k"
fi

plugins=(git zsh-syntax-highlighting)

source $ZSH/oh-my-zsh.sh

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

add_timestamp() {
  while IFS= read -r line; do
    echo "$(date '+%H:%M:%S') $line"
  done
}

exec_with_timestamp() {
  "$@" | add_timestamp
}

alias timestamp='exec_with_timestamp'