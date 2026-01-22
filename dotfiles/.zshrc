# Aliases
alias gtr='git gtr'
alias gtrprune='git gtr clean --merged'
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

# Function to create worktree with auto-behaviors (copy node_modules, cd, open editor)
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
  
  # Create the worktree
  if ! gtr new "$@"; then
    echo "Error: Failed to create worktree"
    return 1
  fi
  
  # Get repo root and worktree path
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
  
  if [ -z "$repo_root" ]; then
    echo "Error: Not in a git repository"
    return 1
  fi
  
  local worktree_path
  worktree_path=$(gtr go "$branch_name" 2>/dev/null)
  
  if [ -z "$worktree_path" ] || [ ! -d "$worktree_path" ]; then
    echo "Error: Could not find worktree path for branch: $branch_name"
    return 1
  fi
  
  # Clone node_modules if it exists in main repo (fast on APFS via copy-on-write)
  if [ -d "$repo_root/node_modules" ] && [ ! -e "$worktree_path/node_modules" ]; then
    echo "Cloning node_modules..."
    cp -cR "$repo_root/node_modules" "$worktree_path/node_modules" 2>/dev/null || \
      cp -R "$repo_root/node_modules" "$worktree_path/node_modules" 2>/dev/null || \
      echo "Warning: Failed to copy node_modules"
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
