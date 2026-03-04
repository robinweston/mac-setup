# Homebrew
eval "$(/opt/homebrew/bin/brew shellenv)"

# PATH exports
export PATH="/usr/local/opt/libpq/bin:$PATH"
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"
export PATH="/Applications/Autodesk/maya2026/Maya.app/Contents/MacOS:$PATH"

# Load fnm (Node version manager)
eval "$(fnm env --use-on-cd)"
