#!/bin/bash

# Get the directory where the current script is located
SCRIPT_DIR=$(dirname "$0")

# Path to the git folder
GIT_DIR=~/git

# Output file (script that will be used to clone the repositories on the new machine)
OUTPUT_SCRIPT="$SCRIPT_DIR/clone-git-repos.sh"

# Create a new file or overwrite if it already exists
echo "#!/bin/bash" > $OUTPUT_SCRIPT
echo "" >> $OUTPUT_SCRIPT

# Function to recursively find all git repositories and generate clone commands
find_git_repos() {
    for dir in "$1"/*; do
        if [ -d "$dir" ]; then
            if [ -d "$dir/.git" ]; then
                # Check if the repository has a remote named 'origin'
                if git -C "$dir" remote | grep -q "^origin$"; then
                    # Get the git remote URL
                    REPO_URL=$(git -C "$dir" remote get-url origin)
                    # Get the relative path of the directory inside ~/git
                    RELATIVE_PATH=${dir#"$GIT_DIR/"}

                    # Add the clone command to the output script
                    echo "echo Cloning $REPO_URL into ~/git/$RELATIVE_PATH" >> $OUTPUT_SCRIPT
                    echo "mkdir -p ~/git/$(dirname "$RELATIVE_PATH")" >> $OUTPUT_SCRIPT
                    echo "git clone $REPO_URL ~/git/$RELATIVE_PATH" >> $OUTPUT_SCRIPT
                    echo "" >> $OUTPUT_SCRIPT
                else
                    # Log repositories without an 'origin' remote
                    echo "No remote 'origin' found for $dir. Skipping..." >> $OUTPUT_SCRIPT
                fi
            else
                # Not a git repo, search recursively in this directory
                find_git_repos "$dir"
            fi
        fi
    done
}

# Start the recursive search in the root of ~/git
find_git_repos "$GIT_DIR"

# Make the generated script executable
chmod +x $OUTPUT_SCRIPT

echo "Clone script generated at $OUTPUT_SCRIPT. You can transfer and run this script on the new machine."
