
# Kiro CLI pre block. Keep at the top of this file.
[[ -f "${HOME}/Library/Application Support/kiro-cli/shell/zprofile.pre.zsh" ]] && builtin source "${HOME}/Library/Application Support/kiro-cli/shell/zprofile.pre.zsh"

# Homebrew
eval "$(/opt/homebrew/bin/brew shellenv)"

# PATH exports
export PATH="/usr/local/opt/libpq/bin:$PATH"
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"

# aws-vault: use the login Keychain, which macOS unlocks with the user session.
export AWS_VAULT_BACKEND="keychain"
export AWS_VAULT_KEYCHAIN_NAME="login"
export AWS_VAULT_BIOMETRICS="false"

# Load the encrypted Git keys from Keychain into Apple's SSH agent.
for git_ssh_key in "$HOME/.ssh/work_git" "$HOME/.ssh/personal_git" "$HOME/.ssh/pms_prod"; do
    if [[ -f "$git_ssh_key" ]]; then
        /usr/bin/ssh-add --apple-load-keychain "$git_ssh_key" </dev/null >/dev/null 2>&1
    fi
done
unset git_ssh_key


# Kiro CLI post block. Keep at the bottom of this file.
[[ -f "${HOME}/Library/Application Support/kiro-cli/shell/zprofile.post.zsh" ]] && builtin source "${HOME}/Library/Application Support/kiro-cli/shell/zprofile.post.zsh"
