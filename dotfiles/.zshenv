if [[ -n "${CODEX_THREAD_ID:-}" ]]; then
  eval "$(XDG_RUNTIME_DIR="${TMPDIR:-/tmp}" /opt/homebrew/bin/fnm env --shell zsh)"
  /opt/homebrew/bin/fnm use --silent-if-unchanged
fi
