
# Kiro CLI pre block. Keep at the top of this file.
[[ -f "${HOME}/Library/Application Support/kiro-cli/shell/zprofile.pre.zsh" ]] && builtin source "${HOME}/Library/Application Support/kiro-cli/shell/zprofile.pre.zsh"

# Homebrew
eval "$(/opt/homebrew/bin/brew shellenv)"

# PATH exports
export PATH="/usr/local/opt/libpq/bin:$PATH"
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"

# aws-vault: use 1Password desktop app as the credential backend
export AWS_VAULT_BACKEND="op-desktop"
export AWS_VAULT_OP_VAULT_ID="pet5nf4rvdeasbius6mxznxluy"
export AWS_VAULT_OP_DESKTOP_ACCOUNT_ID="JJ46IQ327NF27CWLNYS6YXWMJQ"


# Kiro CLI post block. Keep at the bottom of this file.
[[ -f "${HOME}/Library/Application Support/kiro-cli/shell/zprofile.post.zsh" ]] && builtin source "${HOME}/Library/Application Support/kiro-cli/shell/zprofile.post.zsh"
