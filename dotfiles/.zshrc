alias gtrprune='git gtr clean --merged --yes'

# Path to your oh-my-zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Disable themes to keep prompt setup minimal.
ZSH_THEME=""

# Enable plugins
plugins=(
    git 
    zsh-autosuggestions 
    zsh-syntax-highlighting
)

source $ZSH/oh-my-zsh.sh

# Load fnm (Node version manager)
eval "$(fnm env --use-on-cd)"

_gtr_init="${XDG_CACHE_HOME:-$HOME/.cache}/gtr/init-gtr.zsh"
[[ -f "$_gtr_init" ]] || eval "$(git gtr init zsh)" || true
source "$_gtr_init" 2>/dev/null || true
unset _gtr_init
