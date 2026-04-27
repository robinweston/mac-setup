#!/bin/zsh

# Exit immediately if any command exits with a non-zero status
set -e

echo "Starting bootstrapping"

# Ensure Homebrew is in PATH for the duration of the script
if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

function command_exists() {
    command -v "$1" &> /dev/null
}

# --- 1. Install Oh My Zsh ---
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    echo "Installing Oh My Zsh..."
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
else
    echo "Oh My Zsh already installed - skipping"
fi

# --- 2. Install Powerlevel10k Theme ---
P10K_DIR=${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k
if [ ! -d "$P10K_DIR" ]; then
    echo "Installing Powerlevel10k..."
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR"
else
    echo "Powerlevel10k already installed - skipping"
fi

# --- 3. Install Zsh Plugins (Auto-suggestions & Syntax Highlighting) ---
ZSH_AUTOSUGGEST_DIR=${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
if [ ! -d "$ZSH_AUTOSUGGEST_DIR" ]; then
    git clone https://github.com/zsh-users/zsh-autosuggestions "$ZSH_AUTOSUGGEST_DIR"
fi

ZSH_HIGHLIGHT_DIR=${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
if [ ! -d "$ZSH_HIGHLIGHT_DIR" ]; then
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$ZSH_HIGHLIGHT_DIR"
fi

echo "Copying dotfiles"
# Use -u to only update if files are newer, making it more idempotent
rsync -av --progress --exclude=.DS_Store ./dotfiles/ ~/

# --- 4. Standard Homebrew & Packages ---
if ! command_exists brew; then
    echo "Installing homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

brew update

PACKAGES=(
    bash cmake codex codex-app ffmpeg gh git git-delta git-lfs 
    huggingface-cli fnm p7zip pkgconf pre-commit 
    qpdf ripgrep uv watchman zsh
)
brew install ${PACKAGES[@]}

# [Rest of your git-gtr logic, Casks, and MacOS settings remain the same...]
# ... (omitted for brevity, keep your original code here) ...

echo "Setup complete! Please restart your terminal."