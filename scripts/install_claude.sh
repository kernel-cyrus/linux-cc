#!/usr/bin/env bash
set -e

NVM_VERSION="${NVM_VERSION:-v0.40.3}"
NODE_VERSION="${NODE_VERSION:-20}"

echo "[INFO] Install nvm: ${NVM_VERSION}"

export NVM_DIR="$HOME/.nvm"

if [ ! -d "$NVM_DIR" ]; then
    curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
else
    echo "[INFO] nvm already exists: $NVM_DIR"
fi

echo "[INFO] Load nvm"

if [ -s "$NVM_DIR/nvm.sh" ]; then
    . "$NVM_DIR/nvm.sh"
else
    echo "[ERROR] nvm.sh not found: $NVM_DIR/nvm.sh"
    exit 1
fi

echo "[INFO] Install Node.js: ${NODE_VERSION}"

nvm install "$NODE_VERSION"
nvm use "$NODE_VERSION"
nvm alias default "$NODE_VERSION"

echo "[INFO] Node version:"
node -v

echo "[INFO] npm version:"
npm -v

echo "[INFO] Install Claude Code"

npm install -g @anthropic-ai/claude-code

echo "[INFO] Check claude"

which claude
claude --version || true

echo "[INFO] Done"
echo "[INFO] You can run: claude doctor"
