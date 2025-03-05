export ZSH=$HOME/.oh-my-zsh

plugins=(git)

source $ZSH/oh-my-zsh.sh

add_timestamp() {
  while IFS= read -r line; do
    echo "$(date '+%H:%M:%S') $line"
  done
}

exec_with_timestamp() {
  "$@" | add_timestamp
}

alias timestamp='exec_with_timestamp'