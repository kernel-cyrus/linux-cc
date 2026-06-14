#!/usr/bin/env bash
#
# setup_gdb_mcp.sh — Install & register the GDB MCP server (smadi0x86/MDB-MCP)
#
# Reproduces the GDB-MCP setup on a fresh machine:
#   1. ensures `uv` (Python package manager) is installed
#   2. ensures `gdb` / `gdb-multiarch` are present (optional auto-install)
#   3. clones MDB-MCP and syncs its dependencies into a private venv
#   4. registers it with Claude Code as the `mdb-gdb` MCP server
#
# The MCP server exposes gdb_start(gdb_path=...) so you can drive
# `gdb-multiarch` against a remote target (e.g. QEMU `target remote :1234`).
#
# Usage:
#   ./setup_gdb_mcp.sh [--install-deps] [--scope user|local|project] [--dir PATH] [--name NAME]
#   ./setup_gdb_mcp.sh --remove [--scope user|local|project] [--dir PATH] [--name NAME]
#
# Options:
#   --install-deps   apt-get install gdb / gdb-multiarch if missing (needs sudo)
#   --remove         unregister the MCP server from Claude Code and delete the
#                      cloned MDB-MCP directory (reverses what this script set up)
#   --scope SCOPE    Claude MCP registration scope (default: user)
#                      user    = available in all your projects
#                      local   = private to the current project dir
#                      project = shared via .mcp.json (committed)
#   --dir PATH       where to clone MDB-MCP (default: <project-root>/mcp/MDB-MCP)
#   --name NAME      MCP server name registered with Claude (default: mdb-gdb)
#   -h, --help       show this help
#
set -euo pipefail

# ---- defaults ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
REPO_URL="https://github.com/smadi0x86/MDB-MCP.git"
INSTALL_DIR="${PROJECT_ROOT}/mcp/MDB-MCP"
MCP_NAME="mdb-gdb"
MCP_SCOPE="user"
INSTALL_DEPS=0
REMOVE=0

# ---- arg parsing ------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --install-deps) INSTALL_DEPS=1 ;;
        --remove)       REMOVE=1 ;;
        --scope)        MCP_SCOPE="${2:?--scope needs a value}"; shift ;;
        --dir)          INSTALL_DIR="${2:?--dir needs a value}"; shift ;;
        --name)         MCP_NAME="${2:?--name needs a value}"; shift ;;
        -h|--help)      awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

log()  { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- 1. uv ------------------------------------------------------------------
ensure_uv() {
    if command -v uv >/dev/null 2>&1; then
        log "uv already installed: $(uv --version)"
        return
    fi
    if [ -x "$HOME/.local/bin/uv" ]; then
        export PATH="$HOME/.local/bin:$PATH"
        log "uv found in ~/.local/bin: $(uv --version)"
        return
    fi
    log "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    command -v uv >/dev/null 2>&1 || die "uv installation failed"
    log "uv installed: $(uv --version)"
}

# ---- 2. gdb / gdb-multiarch -------------------------------------------------
ensure_gdb() {
    # MDB-MCP auto-detects via plain `gdb --version`, so plain gdb must exist
    # for the GDB tools to register. gdb-multiarch is what we actually drive.
    local missing=()
    command -v gdb            >/dev/null 2>&1 || missing+=("gdb")
    command -v gdb-multiarch  >/dev/null 2>&1 || missing+=("gdb-multiarch")

    if [ ${#missing[@]} -eq 0 ]; then
        log "gdb: $(command -v gdb), gdb-multiarch: $(command -v gdb-multiarch)"
        return
    fi

    if [ "$INSTALL_DEPS" -eq 1 ] && command -v apt-get >/dev/null 2>&1; then
        log "Installing missing packages: ${missing[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y "${missing[@]}"
    else
        warn "Missing: ${missing[*]}"
        warn "Install them, e.g.:  sudo apt-get install ${missing[*]}"
        warn "(or re-run with --install-deps).  At least plain 'gdb' is required."
        command -v gdb >/dev/null 2>&1 || die "plain 'gdb' is required for MDB-MCP to register"
    fi
}

# ---- 3. clone + sync --------------------------------------------------------
ensure_repo() {
    if [ -d "$INSTALL_DIR/.git" ]; then
        log "MDB-MCP already cloned at $INSTALL_DIR (pulling latest)"
        git -C "$INSTALL_DIR" pull --ff-only --quiet || warn "git pull skipped"
    else
        log "Cloning MDB-MCP into $INSTALL_DIR"
        mkdir -p "$(dirname "$INSTALL_DIR")"
        git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
    fi

    log "Syncing Python dependencies (uv sync)..."
    ( cd "$INSTALL_DIR" && uv sync )

    # resolve the venv interpreter uv created
    VENV_PY="$(cd "$INSTALL_DIR" && uv run python -c 'import sys; print(sys.executable)')"
    [ -x "$VENV_PY" ] || die "venv python not found after uv sync"
    log "venv python: $VENV_PY"

    # smoke test: server imports and GDB is detected
    log "Verifying GDB detection..."
    ( cd "$INSTALL_DIR" && "$VENV_PY" -c \
        "from modules import DebuggerFactory; _,k=DebuggerFactory.create_tools(); print('  detected debugger:', k)" )
}

# ---- 4. register with Claude Code ------------------------------------------
register_mcp() {
    if ! command -v claude >/dev/null 2>&1; then
        warn "Claude Code CLI ('claude') not found on PATH — skipping registration."
        warn "Register manually later with:"
        warn "  claude mcp add $MCP_NAME --scope $MCP_SCOPE -- \"$VENV_PY\" \"$INSTALL_DIR/server.py\""
        return
    fi

    # drop any stale registration so the script is idempotent
    claude mcp remove "$MCP_NAME" --scope "$MCP_SCOPE" >/dev/null 2>&1 || true

    log "Registering '$MCP_NAME' with Claude Code (scope: $MCP_SCOPE)"
    claude mcp add "$MCP_NAME" --scope "$MCP_SCOPE" -- \
        "$VENV_PY" "$INSTALL_DIR/server.py"

    log "Health check:"
    claude mcp list 2>&1 | grep -E "(^Checking|$MCP_NAME)" || true
}

# ---- remove -----------------------------------------------------------------
remove_mcp() {
    if command -v claude >/dev/null 2>&1; then
        log "Unregistering '$MCP_NAME' from Claude Code (scope: $MCP_SCOPE)"
        claude mcp remove "$MCP_NAME" --scope "$MCP_SCOPE" >/dev/null 2>&1 \
            && log "Removed MCP registration '$MCP_NAME'" \
            || warn "No registration '$MCP_NAME' found at scope '$MCP_SCOPE' (already gone?)"
    else
        warn "Claude Code CLI ('claude') not found — skipping unregistration."
        warn "Remove manually later with:  claude mcp remove $MCP_NAME --scope $MCP_SCOPE"
    fi

    if [ -d "$INSTALL_DIR" ]; then
        log "Deleting $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    else
        warn "Directory not found: $INSTALL_DIR (already deleted?)"
    fi

    cat <<EOF

$(log "Removed.")
  MCP server : $MCP_NAME  (scope: $MCP_SCOPE)
  Location   : $INSTALL_DIR (deleted)

  >>> Restart Claude Code so the mcp__${MCP_NAME//-/_}__* tools unload. <<<
EOF
}

# ---- run --------------------------------------------------------------------
main() {
    if [ "$REMOVE" -eq 1 ]; then
        remove_mcp
        return
    fi
    ensure_uv
    ensure_gdb
    ensure_repo
    register_mcp
    cat <<EOF

$(log "Done.")
  MCP server : $MCP_NAME  (scope: $MCP_SCOPE)
  Location   : $INSTALL_DIR
  gdb-multiarch: $(command -v gdb-multiarch 2>/dev/null || echo 'NOT FOUND')

  >>> Restart Claude Code so the mcp__${MCP_NAME//-/_}__* tools load. <<<

  Typical aarch64 kernel debug flow inside Claude:
    gdb_start(gdb_path="\$(command -v gdb-multiarch)")  -> session_id
    gdb_command(sid, "file /path/to/vmlinux")
    gdb_command(sid, "set architecture aarch64")
    gdb_command(sid, "target remote :1234")
    gdb_command(sid, "break schedule")
EOF
}

main
