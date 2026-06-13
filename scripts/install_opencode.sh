#!/usr/bin/env bash
set -e

NVM_VERSION="${NVM_VERSION:-v0.40.3}"
NODE_VERSION="${NODE_VERSION:-20}"

echo "[INFO] NVM_VERSION=${NVM_VERSION}"
echo "[INFO] NODE_VERSION=${NODE_VERSION}"

export NVM_DIR="$HOME/.nvm"

echo "[INFO] Install nvm if needed..."

if [ ! -d "$NVM_DIR" ]; then
    curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
else
    echo "[INFO] nvm already exists: $NVM_DIR"
fi

echo "[INFO] Load nvm..."

if [ -s "$NVM_DIR/nvm.sh" ]; then
    . "$NVM_DIR/nvm.sh"
else
    echo "[ERROR] nvm.sh not found: $NVM_DIR/nvm.sh"
    exit 1
fi

echo "[INFO] Install Node.js ${NODE_VERSION}..."

nvm install "$NODE_VERSION"
nvm use "$NODE_VERSION"
nvm alias default "$NODE_VERSION"

echo "[INFO] Check node/npm..."

node -v
npm -v

echo "[INFO] Install OpenCode..."

npm install -g opencode-ai@latest

echo "[INFO] Check opencode..."

which opencode
opencode --version || true

echo "[INFO] Done"
echo "[INFO] You can run: opencode"
