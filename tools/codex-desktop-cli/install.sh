#!/bin/zsh

set -eu

TOOL_DIR="${0:A:h}"
SOURCE="$TOOL_DIR/bin/codex-desktop-cli.mjs"

if [[ ! -x "$SOURCE" ]]; then
    echo "codex-desktop-cli executable not found: $SOURCE" >&2
    exit 1
fi

if [[ -n "${CODEX_DESKTOP_CLI_INSTALL_DIR:-}" ]]; then
    INSTALL_DIR="$CODEX_DESKTOP_CLI_INSTALL_DIR"
elif command -v brew > /dev/null 2>&1; then
    INSTALL_DIR="$(brew --prefix)/bin"
else
    echo "Homebrew is required, or set CODEX_DESKTOP_CLI_INSTALL_DIR" >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"
ln -sfn "$SOURCE" "$INSTALL_DIR/codex-desktop-cli"

echo "Installed codex-desktop-cli at $INSTALL_DIR/codex-desktop-cli"
