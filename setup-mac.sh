#!/bin/zsh

# Exit immediately if any command exits with a non-zero status
set -e

echo "Starting bootstrapping"

function reload_shell()
{
    echo "Reloading shell"
    source ~/.zprofile
}

function command_exists()
{
    echo "Checking command $1 exists"
    command -v $1 &> /dev/null
}

echo "Copying dotfiles"
rsync -av --progress --exclude=.DS_Store ./dotfiles/ ~/

# Check if Oh My Zsh is already installed by looking for the ~/.oh-my-zsh directory
if [ -d "$HOME/.oh-my-zsh" ]; then
    echo "Oh My Zsh is already installed."
else
    echo "Oh My Zsh is not installed. Installing Oh My Zsh..."
    
    # Install Oh My Zsh
    RUNZSH=no /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

echo "Installing zsh extras"
function install_zsh_extra() {
    local repo=$1
    local dest_dir=${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/$2

    if [ -d "$dest_dir" ]; then
        echo "$2 is already installed at $dest_dir."
    else
        echo "Installing $2..."
        git clone $repo $dest_dir
        echo "$2 has been installed successfully."
    fi
}

install_zsh_extra "https://github.com/zsh-users/zsh-syntax-highlighting.git" "plugins/zsh-syntax-highlighting"
install_zsh_extra "https://github.com/zsh-users/zsh-autosuggestions.git" "plugins/zsh-autosuggestions"
install_zsh_extra "https://github.com/romkatv/powerlevel10k.git" "themes/powerlevel10k"

# Homebrew
if command_exists brew; then
    echo "Homebrew already installed - skipping"
else
    echo "Installing homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

brew update

PACKAGES=(  
    git
    python3
    nvm
    p7zip
    watchman
    awscli
    git-delta
)

echo "Installing packages..."
brew install ${PACKAGES[@]}

# NVM
mkdir -p ~/.nvm

reload_shell

CASKS=(
    iterm2
    brave-browser
    docker
    rectangle
    visual-studio-code
    postman
    spotify
    notunes
    aws-vault
    1password
    grammarly-desktop
)

echo "Installing cask apps..."
brew install --cask ${CASKS[@]}

echo "Cleaning up..."
brew cleanup

# Set Brave as the default browser
echo "Setting Brave as the default browser"
open -a "Brave Browser" --args --make-default-browser

echo "Set startup items"

function add_login_item_if_not_exists() 
{
    APP_NAME=$1

    echo "Checking if $APP_NAME is already a login item."
    LOGIN_ITEMS=$(osascript -e "tell application \"System Events\" to get the name of every login item" | tr -d '\n')

    # Assuming app is located in /Applications/<AppName>.app
    APP_PATH="/Applications/$APP_NAME.app"

    if [ ! -d "$APP_PATH" ]; then
        echo "App $APP_NAME not found in /Applications, skipping."
        return
    fi

    # Only add the app if it is NOT already a login item
    if echo "$LOGIN_ITEMS" | grep -i -w "$APP_NAME" > /dev/null; then
        echo "$APP_NAME is already a login item."
    else
        echo "Adding $APP_NAME to login items."
        osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$APP_PATH\", hidden:false}"
    fi
}

# Add startup items assuming they are in /Applications
add_login_item_if_not_exists "Rectangle"
add_login_item_if_not_exists "noTunes"

echo "Configuring MacOS settings"

sudo languagesetup -langspec "English (UK)"

# Showing all filename extensions in Finder by default
defaults write NSGlobalDomain AppleShowAllExtensions -bool true

echo "Configuring Finder settings"

# Show hidden files
defaults write com.apple.finder AppleShowAllFiles TRUE

# Disabling the warning when changing a file extension
defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false

# Disable the Recent Tags section in Finder sidebar
defaults write com.apple.finder ShowRecentTags -bool false

echo "Configuring Dock settings"

# Remove all items from Dock
if defaults read com.apple.dock persistent-apps > /dev/null 2>&1; then
    echo "Removing all items from Dock"
    defaults delete com.apple.dock persistent-apps
else
    echo "No persistent apps found in the Dock to remove."
fi

#"Setting Dock to auto-hide and removing the auto-hiding delay"
echo "Setting Dock to auto-hide and removing the auto-hiding delay"
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock autohide-delay -float 0
defaults write com.apple.dock autohide-time-modifier -float 0

#"Setting screenshots location"
echo "Setting screenshots location"
mkdir -p "$HOME/Documents/screenshots"
defaults write com.apple.screencapture location -string "$HOME/Documents/screenshots"

# Disable the “Are you sure you want to open this application?” dialog
defaults write com.apple.LaunchServices LSQuarantine -bool false

# Disable Notification Center and remove the menu bar icon
launchctl unload -w /System/Library/LaunchAgents/com.apple.notificationcenterui.plist 2> /dev/null

echo "Setting bottom-right corner of the trackpad to right-click"

# For MacBook trackpads
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadCornerSecondaryClick -int 2
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadRightClick -bool true

# For Magic Trackpads (external trackpads)
defaults write com.apple.AppleMultitouchTrackpad TrackpadCornerSecondaryClick -int 2
defaults write com.apple.AppleMultitouchTrackpad TrackpadRightClick -bool true

/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u

# Finder: allow quitting via ⌘ + Q; doing so will also hide desktop icons
defaults write com.apple.finder QuitMenuItem -bool true

# Show icons for hard drives, servers, and removable media on the desktop
defaults write com.apple.finder ShowExternalHardDrivesOnDesktop -bool true
defaults write com.apple.finder ShowHardDrivesOnDesktop -bool true
defaults write com.apple.finder ShowMountedServersOnDesktop -bool true
defaults write com.apple.finder ShowRemovableMediaOnDesktop -bool true

# Finder: show path bar
defaults write com.apple.finder ShowPathbar -bool true

# Display full POSIX path as Finder window title
defaults write com.apple.finder _FXShowPosixPathInTitle -bool true

# Use list view in all Finder windows by default
# Four-letter codes for the other view modes: `icnv`, `clmv`, `glyv`
defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv"

# Expand the following File Info panes:
# “General”, “Open with”, and “Sharing & Permissions”
defaults write com.apple.finder FXInfoPanesExpanded -dict \
	General -bool true \
	OpenWith -bool true \
	Privileges -bool true

# Don’t display the annoying prompt when quitting iTerm
defaults write com.googlecode.iterm2 PromptOnQuit -bool false

# Use function keys on external keyboard
defaults write "Apple Global Domain" com.apple.keyboard.fnState -bool true

# Nothing on desktop
defaults write com.apple.finder CreateDesktop false

echo "Configuring sound settings"

# Turn off System Audio
sudo nvram SystemAudioVolume=" "

# Disable sound effects when changing volume
defaults write NSGlobalDomain com.apple.sound.beep.feedback -integer 0

# Disable sounds effects for user interface changes
defaults write NSGlobalDomain com.apple.sound.uiaudio.enabled -int 0

# Set alert volume to 0
defaults write NSGlobalDomain com.apple.sound.beep.volume -float 0.0

# Disable the boot sound
sudo nvram StartupMute=%01

echo "Manual tasks"
echo "============"

echo "- Set Region"
echo "- Set Keyboard Layout Input Source to British"
echo "- Sync Brave Browser settings"
echo "- Sign into VS Code to sync settings"
echo "- Set Accessibility settings to allow Rectangle and 1Password to control your computer"

killall Finder
killall Dock
killall SystemUIServer