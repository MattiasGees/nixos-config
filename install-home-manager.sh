#!/usr/bin/env bash
# Install home-manager configuration for existing user
# Usage: Run as the mattias user
#   curl -L https://raw.githubusercontent.com/YOUR_REPO/master/install-home-manager.sh | bash

set -e

USERNAME="mattias"

if [ "$USER" != "$USERNAME" ]; then
    echo "Error: This script must be run as user $USERNAME"
    echo "Current user: $USER"
    exit 1
fi

echo "==> Installing Nix and home-manager for $USERNAME"

# Install Nix if not already installed
if ! command -v nix &>/dev/null; then
    echo "==> Installing Nix"
    sh <(curl -L https://nixos.org/nix/install) --no-daemon

    # Source nix profile
    if [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
        . "$HOME/.nix-profile/etc/profile.d/nix.sh"
    fi
else
    echo "==> Nix is already installed"
fi

# Source Nix profile
if [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
elif [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
    . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
fi

# Enable experimental features for flakes
mkdir -p ~/.config/nix
cat > ~/.config/nix/nix.conf << 'EOF'
experimental-features = nix-command flakes
EOF

# Clone or update the nixos-config repo
if [ ! -d ~/.config/nixos-config ]; then
    echo "==> Cloning nixos-config repository"
    mkdir -p ~/.config
    # TODO: Update this with your actual repository URL
    git clone https://github.com/mattiasgees/nixos-config.git ~/.config/nixos-config
else
    echo "==> Updating nixos-config repository"
    cd ~/.config/nixos-config
    git pull
fi

cd ~/.config/nixos-config

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    SYSTEM="x86_64-linux"
elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    SYSTEM="aarch64-linux"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

echo "==> Detected system: $SYSTEM"
echo "==> Applying home-manager configuration"

# Apply home-manager configuration directly from flake
nix run home-manager/master -- switch --flake ".#${USERNAME}@${SYSTEM}"

echo ""
echo "==> Setup complete!"
echo "==> Configuration applied from flake: ${USERNAME}@${SYSTEM}"
echo "==> To update in the future, run:"
echo "    cd ~/.config/nixos-config && git pull && home-manager switch --flake .#${USERNAME}"
