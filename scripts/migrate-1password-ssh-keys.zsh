#!/bin/zsh

set -euo pipefail
umask 077

readonly MIGRATION_TEMP_DIR="$(mktemp -d /private/tmp/ssh-keychain-migration.XXXXXX)"

cleanup() {
    rm -rf -- "$MIGRATION_TEMP_DIR"
}
trap cleanup EXIT INT TERM

for command_name in op jq openssl python3 ssh-keygen ssh-add osascript; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Required command is unavailable: $command_name" >&2
        exit 1
    fi
done

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

prompt_for_passphrase() {
    local key_label="$1"
    local first_passphrase
    local second_passphrase

    while true; do
        first_passphrase="$(osascript - "$key_label" <<'APPLESCRIPT'
on run argv
    set keyLabel to item 1 of argv
    return text returned of (display dialog "Enter a new passphrase for " & keyLabel & ". macOS Keychain will remember it." default answer "" with hidden answer buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel")
end run
APPLESCRIPT
)"
        second_passphrase="$(osascript - "$key_label" <<'APPLESCRIPT'
on run argv
    set keyLabel to item 1 of argv
    return text returned of (display dialog "Confirm the new passphrase for " & keyLabel & "." default answer "" with hidden answer buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel")
end run
APPLESCRIPT
)"

        if [[ ${#first_passphrase} -lt 16 ]]; then
            osascript -e 'display alert "Passphrase too short" message "Use at least 16 characters." as warning'
        elif [[ "$first_passphrase" != "$second_passphrase" ]]; then
            osascript -e 'display alert "Passphrases did not match" as warning'
        else
            print -rn -- "$first_passphrase"
            return
        fi
    done
}

migrate_key() {
    local item_name="$1"
    local vault_name="$2"
    local target_name="$3"
    local expected_public_key="$4"
    local target_key="$HOME/.ssh/$target_name"
    local staged_key="$MIGRATION_TEMP_DIR/$target_name.pkcs8"
    local encrypted_key="$MIGRATION_TEMP_DIR/$target_name"
    local staged_public_key="$MIGRATION_TEMP_DIR/$target_name.pub"
    local expected_fingerprint
    local actual_fingerprint
    local key_passphrase

    if [[ -e "$target_key" ]]; then
        echo "Private key already exists, leaving it untouched: $target_key"
        return
    fi

    if [[ ! -e "$expected_public_key" ]]; then
        echo "Writing the public key for $item_name"
        op item get "$item_name" \
            --vault "$vault_name" \
            --format json \
            | jq -r '.fields[] | select(.id == "public_key") | .value' \
            > "$expected_public_key"
        chmod 644 "$expected_public_key"
    fi

    echo "Reading $item_name from 1Password"
    op item get "$item_name" \
        --vault "$vault_name" \
        --format json \
        --reveal \
        | jq -j '.fields[] | select(.id == "private_key") | .value' \
        | openssl pkey 2>/dev/null \
        > "$staged_key"
    chmod 600 "$staged_key"

    expected_fingerprint="$(ssh-keygen -lf "$expected_public_key" | awk '{print $2}')"
    MIGRATION_SOURCE_KEY="$staged_key" \
        MIGRATION_PUBLIC_KEY="$staged_public_key" \
        python3 <<'PYTHON'
import os
from pathlib import Path

from cryptography.hazmat.primitives import serialization

source_path = Path(os.environ["MIGRATION_SOURCE_KEY"])
public_path = Path(os.environ["MIGRATION_PUBLIC_KEY"])
private_key = serialization.load_pem_private_key(
    source_path.read_bytes(),
    password=None,
)
public_path.write_bytes(
    private_key.public_key().public_bytes(
        serialization.Encoding.OpenSSH,
        serialization.PublicFormat.OpenSSH,
    )
    + b"\n"
)
PYTHON
    actual_fingerprint="$(ssh-keygen -lf "$staged_public_key" | awk '{print $2}')"
    if [[ "$actual_fingerprint" != "$expected_fingerprint" ]]; then
        echo "Fingerprint mismatch for $item_name" >&2
        exit 1
    fi

    key_passphrase="$(prompt_for_passphrase "$item_name")"
    MIGRATION_SOURCE_KEY="$staged_key" \
        MIGRATION_TARGET_KEY="$encrypted_key" \
        python3 <<'PYTHON'
import os
from pathlib import Path

from cryptography.hazmat.primitives import serialization

source_path = Path(os.environ["MIGRATION_SOURCE_KEY"])
target_path = Path(os.environ["MIGRATION_TARGET_KEY"])
private_key = serialization.load_pem_private_key(
    source_path.read_bytes(),
    password=None,
)
target_path.write_bytes(
    private_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.OpenSSH,
        serialization.NoEncryption(),
    )
)
PYTHON
    rm -f -- "$staged_key"
    ssh-keygen -p -q -P '' -N "$key_passphrase" -f "$encrypted_key"
    mv "$encrypted_key" "$target_key"
    chmod 600 "$target_key"

    cat > "$MIGRATION_TEMP_DIR/askpass" <<'ASKPASS'
#!/bin/sh
printf '%s\n' "$MIGRATION_KEY_PASSPHRASE"
ASKPASS
    chmod 700 "$MIGRATION_TEMP_DIR/askpass"

    DISPLAY=:0 \
        SSH_ASKPASS_REQUIRE=force \
        SSH_ASKPASS="$MIGRATION_TEMP_DIR/askpass" \
        MIGRATION_KEY_PASSPHRASE="$key_passphrase" \
        /usr/bin/ssh-add --apple-use-keychain "$target_key" </dev/null

    key_passphrase=''
    echo "Migrated $item_name as $target_key ($actual_fingerprint)"
}

migrate_key \
    'Personal GitHub' \
    'Private' \
    'personal_git' \
    "$HOME/.ssh/personal_git.pub"

migrate_key \
    'Cettire BitBucket SSH Key' \
    'Cettire' \
    'work_git' \
    "$HOME/.ssh/work_git.pub"

migrate_key \
    'Prod PMS SSH Key' \
    'Cettire' \
    'pms_prod' \
    "$HOME/.ssh/pms_prod.pub"

echo "All encrypted private keys are loaded in the macOS SSH agent."
/usr/bin/ssh-add -l
