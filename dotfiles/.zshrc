# Aliases
alias gtr='git gtr'

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
  gtr new "$branch_name"
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
