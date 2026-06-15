#!/usr/bin/env bash
set -e

PORT="${OPENCODE_WEB_PORT:-8899}"
HOSTNAME="${OPENCODE_WEB_HOSTNAME:-0.0.0.0}"

USERNAME="${OPENCODE_SERVER_USERNAME:-opencode}"
PASSWORD="${OPENCODE_SERVER_PASSWORD:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="${OPENCODE_WORKSPACE:-$ROOT_DIR}"

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --port PORT         Server port (default: 8899, env: OPENCODE_WEB_PORT)"
    echo "  --hostname HOST     Bind hostname (default: 0.0.0.0 for LAN access)"
    echo "  --workspace DIR     Workspace directory (default: project root)"
    echo "  --mdns              Enable mDNS discovery"
    echo "  --cors URL          Allow CORS for additional domain"
    echo "  --username USER     Login username (default: opencode, env: OPENCODE_SERVER_USERNAME)"
    echo "  --password PASS     Login password (env: OPENCODE_SERVER_PASSWORD)"
    echo "  -h, --help          Show this help"
    echo ""
    echo "Password can also be set via OPENCODE_SERVER_PASSWORD env var."
    exit 1
}

CORS=""
MDNS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)       PORT="$2"; shift 2 ;;
        --hostname)   HOSTNAME="$2"; shift 2 ;;
        --workspace)  WORKSPACE="$2"; shift 2 ;;
        --mdns)       MDNS="--mdns"; HOSTNAME="0.0.0.0"; shift ;;
        --cors)       CORS="--cors $2"; shift 2 ;;
        --username)   USERNAME="$2"; shift 2 ;;
        --password)   PASSWORD="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *)            echo "Unknown option: $1"; usage ;;
    esac
done

if ! command -v opencode &>/dev/null; then
    echo "Error: opencode not found. Install it first: npm install -g opencode-ai@latest"
    exit 1
fi

if [ -z "$PASSWORD" ]; then
    echo "Error: No password set. Use --password or OPENCODE_SERVER_PASSWORD env var."
    echo ""
    usage
fi

export OPENCODE_SERVER_USERNAME="$USERNAME"
export OPENCODE_SERVER_PASSWORD="$PASSWORD"

if ! command -v xdg-open &>/dev/null; then
    XDG_STUB_DIR="$(mktemp -d)"
    cat > "$XDG_STUB_DIR/xdg-open" <<'EOF'
#!/bin/sh
echo "[opencode] Browser URL: ${1:-}" >&2
EOF
    chmod +x "$XDG_STUB_DIR/xdg-open"
    export PATH="$XDG_STUB_DIR:$PATH"
    trap "rm -rf $XDG_STUB_DIR" EXIT
fi

echo "=== OpenCode Web Server ==="
echo "  Username:  $USERNAME"
echo "  Password:  (set)"
echo "  Workspace: $WORKSPACE"
echo "  Bind:      $HOSTNAME:$PORT"
echo ""

cd "$WORKSPACE"
opencode web --port "$PORT" --hostname "$HOSTNAME" $MDNS $CORS
