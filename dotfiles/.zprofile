
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


# Kiro CLI post block. Keep at the bottom of this file.
[[ -f "${HOME}/Library/Application Support/kiro-cli/shell/zprofile.post.zsh" ]] && builtin source "${HOME}/Library/Application Support/kiro-cli/shell/zprofile.post.zsh"
