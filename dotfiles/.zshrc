# Aliases
alias gtr='git gtr'
alias gtrprune='git gtr clean --merged --yes'
alias restart-onedrive='killall OneDrive "OneDrive Sync Service" "OneDrive File Provider" Finder && sleep 2 && open /Applications/OneDrive.app && open /System/Library/CoreServices/Finder.app'

# Function to checkout PR branch using gtr
gtrpr() {
  if [ -z "$1" ]; then
    echo "Usage: gtrpr <PR_NUMBER>"
    return 1
  fi
  
  local pr_number="$1"
  echo "Fetching branch name for PR #${pr_number}..."
  
  local branch_name=$(gh pr view "$pr_number" --json headRefName --jq '.headRefName' 2>&1 | grep -v "new release" | grep -v "To upgrade" | grep -v "https://" | xargs)
  
  if [ -z "$branch_name" ]; then
    echo "Error: Could not fetch branch name for PR #${pr_number}"
    return 1
  fi
  
  echo "Creating worktree for branch: ${branch_name}"
  gtrnew "$branch_name"
}

# Simplified function to create worktree and cd into it
# Note: node_modules copying and editor opening are now handled by gtr config hooks
gtrnew() {
  # Extract branch name from arguments (first non-flag argument)
  local branch_name=""
  local args=("$@")
  
  for arg in "${args[@]}"; do
    case "$arg" in
      --*)
        # Skip flags
        continue
        ;;
      *)
        # First non-flag argument is the branch name
        if [ -z "$branch_name" ]; then
          branch_name="$arg"
        fi
        ;;
    esac
  done
  
  if [ -z "$branch_name" ]; then
    echo "Error: Branch name required"
    echo "Usage: gtrnew <branch> [options...]"
    return 1
  fi
  
  # Create the worktree (gtr config handles node_modules copying and editor opening)
  if ! gtr new "$@"; then
    echo "Error: Failed to create worktree"
    return 1
  fi
  
  # Get worktree path and cd into it
  # Note: We still need to cd manually since hooks run in subshells
  local worktree_path
  worktree_path=$(gtr go "$branch_name" 2>/dev/null)
  
  if [ -z "$worktree_path" ] || [ ! -d "$worktree_path" ]; then
    echo "Error: Could not find worktree path for branch: $branch_name"
    return 1
  fi
  
  # Change directory to worktree
  cd "$worktree_path" || {
    echo "Warning: Failed to change directory to $worktree_path"
    return 1
  }
  
  # Open in configured editor
  gtr editor "$branch_name"
}

# Automatically switch Node.js version when entering directory with .nvmrc
autoload -U add-zsh-hook
load-nvmrc() {
  local nvmrc_path="$(nvm_find_nvmrc)"

  if [ -n "$nvmrc_path" ]; then
    local nvmrc_node_version=$(nvm version "$(cat "${nvmrc_path}")")

    if [ "$nvmrc_node_version" = "N/A" ]; then
      echo "Node version specified in .nvmrc is not installed. Installing..."
      nvm install
    elif [ "$nvmrc_node_version" != "$(nvm version)" ]; then
      echo "Switching to Node.js version: $(cat "${nvmrc_path}")"
      nvm use
    fi
  elif [ -n "$(PWD=$OLDPWD nvm_find_nvmrc)" ] && [ "$(nvm version)" != "$(nvm version default)" ]; then
    echo "Reverting to nvm default version"
    nvm use default
  fi
}
add-zsh-hook chpwd load-nvmrc
load-nvmrc
