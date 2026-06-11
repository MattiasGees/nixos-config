#!/usr/bin/env bash
# Bootstrap script for setting up mattias user and nix on non-NixOS servers
# Usage: curl -L https://raw.githubusercontent.com/YOUR_REPO/master/bootstrap-server.sh | sudo bash

set -e

USERNAME="mattias"
USER_HOME="/home/$USERNAME"

echo "==> Setting up server environment for $USERNAME"

# Create user if it doesn't exist
if ! id "$USERNAME" &>/dev/null; then
    echo "==> Creating user $USERNAME"
    useradd -m -s /bin/bash -G sudo "$USERNAME"
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME
    chmod 0440 /etc/sudoers.d/$USERNAME

    # Set a temporary password (user should change this)
    echo "$USERNAME:changeme" | chpasswd
    echo "==> User $USERNAME created with password 'changeme' - please change it!"
else
    echo "==> User $USERNAME already exists"
fi

# Install Nix if not already installed
if ! command -v nix &>/dev/null; then
    echo "==> Installing Nix"
    sudo -u "$USERNAME" bash -c 'sh <(curl -L https://nixos.org/nix/install) --daemon'
else
    echo "==> Nix is already installed"
fi

# Source nix profile
if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
    . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
fi

# Install home-manager
echo "==> Installing home-manager for $USERNAME"
sudo -u "$USERNAME" bash << 'EOF'
# Source Nix
if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
    . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
fi

# Add experimental features to allow flakes
mkdir -p ~/.config/nix
cat > ~/.config/nix/nix.conf << 'NIXCONF'
experimental-features = nix-command flakes
NIXCONF

# Clone or update the nixos-config repo
if [ ! -d ~/.config/nixos-config ]; then
    echo "==> Cloning nixos-config repository"
    mkdir -p ~/.config
    # TODO: Update this with your actual repository URL
    git clone https://github.com/mattiasgees/nixos-config.git ~/.config/nixos-config
else
    echo "==> nixos-config repository already exists"
fi

# Install home-manager
if ! command -v home-manager &>/dev/null; then
    echo "==> Installing home-manager"
    nix run home-manager/master -- init --switch
fi

# Apply home-manager configuration
cd ~/.config/nixos-config
echo "==> Applying home-manager configuration"
home-manager switch --flake .#mattias

echo "==> Setup complete!"
echo "==> Please change the password for user mattias"
echo "==> Log out and log back in for changes to take effect"
EOF
