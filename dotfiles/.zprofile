
# Kiro CLI pre block. Keep at the top of this file.
[[ -f "${HOME}/Library/Application Support/kiro-cli/shell/zprofile.pre.zsh" ]] && builtin source "${HOME}/Library/Application Support/kiro-cli/shell/zprofile.pre.zsh"

# Homebrew
eval "$(/opt/homebrew/bin/brew shellenv)"

# Homebrew exports FPATH. Keep completion paths unique so nested login shells
# do not accumulate Oh My Zsh's paths, and do not export the expanded fpath to
# child processes where Oh My Zsh would prepend those paths again.
typeset -aU fpath
typeset +x FPATH

# PATH exports
export PATH="$HOME/.local/bin:$PATH"
export PATH="/usr/local/opt/libpq/bin:$PATH"
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"

# aws-vault: use the login Keychain, which macOS unlocks with the user session.
export AWS_VAULT_BACKEND="keychain"
export AWS_VAULT_KEYCHAIN_NAME="login"
export AWS_VAULT_BIOMETRICS="false"

# Load the encrypted Git keys from Keychain into Apple's SSH agent.
loaded_ssh_keys="$(/usr/bin/ssh-add -L 2>/dev/null || true)"
for git_ssh_key in "$HOME/.ssh/work_git" "$HOME/.ssh/personal_git" "$HOME/.ssh/pms_prod"; do
    if [[ -f "$git_ssh_key" ]]; then
        public_key_file="${git_ssh_key}.pub"
        if [[ -f "$public_key_file" ]]; then
            public_key="$(< "$public_key_file")"
            # Compare the key type and blob, ignoring an optional comment.
            public_key="${public_key%% *} ${${public_key#* }%% *}"
            [[ "$loaded_ssh_keys" == *"$public_key"* ]] && continue
        fi
        /usr/bin/ssh-add --apple-load-keychain "$git_ssh_key" </dev/null >/dev/null 2>&1
    fi
done
unset git_ssh_key public_key_file public_key loaded_ssh_keys


# Kiro CLI post block. Keep at the bottom of this file.
[[ -f "${HOME}/Library/Application Support/kiro-cli/shell/zprofile.post.zsh" ]] && builtin source "${HOME}/Library/Application Support/kiro-cli/shell/zprofile.post.zsh"
