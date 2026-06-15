#!/usr/bin/env bash
#
# setup_gdb_mcp.sh — Install & register the GDB MCP server (smadi0x86/MDB-MCP)
#
# Reproduces the GDB-MCP setup on a fresh machine:
#   1. ensures `uv` (Python package manager) is installed
#   2. ensures `gdb` / `gdb-multiarch` are present (optional auto-install)
#   3. clones MDB-MCP and syncs its dependencies into a private venv
#   4. registers it with Claude Code and/or OpenCode as the `mdb-gdb` MCP server
#
# The MCP server exposes gdb_start(gdb_path=...) so you can drive
# `gdb-multiarch` against a remote target (e.g. QEMU `target remote :1234`).
#
# Usage:
#   ./setup_gdb_mcp.sh [--scope user|local|project] [--target claude|opencode|all] [--dir PATH] [--name NAME]
#   ./setup_gdb_mcp.sh --remove [--scope user|local|project] [--target claude|opencode|all] [--dir PATH] [--name NAME]
#
# Options:
#   --remove         unregister the MCP server and delete the cloned MDB-MCP
#                      directory (reverses what this script set up)
#   --target MODE   which tool to register with: claude, opencode, or all (default: all)
#   --scope SCOPE    MCP registration scope (default: project)
#                      user    = global (available in all projects)
#                      local   = local to the current project
#                      project = project-level, shareable via config file (default)
#   --dir PATH       where to clone MDB-MCP (default: <project-root>/mcp/MDB-MCP)
#   --name NAME      MCP server name registered with Claude (default: mdb-gdb)
#   -h, --help       show this help
#
set -euo pipefail

# ---- defaults ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
REPO_URL="https://github.com/smadi0x86/MDB-MCP.git"
INSTALL_DIR="${PROJECT_ROOT}/mcp/MDB-MCP"
MCP_NAME="mdb-gdb"
MCP_SCOPE="project"
REMOVE=0
TARGET_MODE="all"

# ---- arg parsing ------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --remove)       REMOVE=1 ;;
        --target)       TARGET_MODE="${2:?--target needs a value}"; shift ;;
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

    if command -v apt-get >/dev/null 2>&1; then
        log "Installing missing packages: ${missing[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y "${missing[@]}"
    else
        warn "Missing: ${missing[*]}"
        warn "Install them, e.g.:  sudo apt-get install ${missing[*]}"
        warn "At least plain 'gdb' is required for MDB-MCP to register."
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

# ---- 4a. register with OpenCode (opencode.jsonc) -------------------------------
register_opencode_mcp() {
    local config_file
    if [ "$MCP_SCOPE" = "user" ]; then
        config_file="$HOME/.config/opencode/opencode.jsonc"
    else
        config_file="$PROJECT_ROOT/opencode.jsonc"
    fi

    log "Registering '$MCP_NAME' with OpenCode (scope: $MCP_SCOPE, config: $config_file)"

    "$VENV_PY" -c "
import sys, os, json, subprocess

CONFIG_FILE = os.path.expanduser(os.path.expandvars('$config_file'))
MCP_NAME = '$MCP_NAME'
VENV_PY = '$VENV_PY'
INSTALL_DIR = '$INSTALL_DIR'

try:
    import json5 as jp
except ImportError:
    subprocess.check_call(['uv', 'pip', 'install', '-q', 'json5',
                           '--python', VENV_PY],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    import json5 as jp

config = {}
if os.path.exists(CONFIG_FILE):
    with open(CONFIG_FILE) as f:
        try:
            config = jp.load(f)
        except Exception:
            config = {}

config.setdefault('mcp', {})
config['mcp'][MCP_NAME] = {
    'type': 'local',
    'command': [VENV_PY, os.path.join(INSTALL_DIR, 'server.py')],
    'enabled': True
}

os.makedirs(os.path.dirname(CONFIG_FILE) or '.', exist_ok=True)
with open(CONFIG_FILE, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
print(f'  MCP entry written to {CONFIG_FILE}')
"
    log "OpenCode registration done"
}

# ---- 4b. remove from OpenCode ------------------------------------------------
remove_opencode_mcp() {
    local config_file
    if [ "$MCP_SCOPE" = "user" ]; then
        config_file="$HOME/.config/opencode/opencode.jsonc"
    else
        config_file="$PROJECT_ROOT/opencode.jsonc"
    fi

    if [ ! -f "$config_file" ]; then
        warn "OpenCode config not found: $config_file (already removed?)"
        return
    fi

    log "Unregistering '$MCP_NAME' from OpenCode (config: $config_file)"

    python3 -c "
import sys, os, json

CONFIG_FILE = os.path.expanduser(os.path.expandvars('$config_file'))
MCP_NAME = '$MCP_NAME'

try:
    import json5 as jp
except ImportError:
    jp = json

with open(CONFIG_FILE) as f:
    try:
        config = jp.load(f)
    except Exception:
        print(f'  Failed to parse {CONFIG_FILE}, skipping', file=sys.stderr)
        sys.exit(0)

mcp = config.get('mcp', {})
if MCP_NAME in mcp:
    del mcp[MCP_NAME]
    if not mcp:
        config.pop('mcp', None)
    with open(CONFIG_FILE, 'w') as f:
        json.dump(config, f, indent=2)
        f.write('\n')
    print(f'  Removed {MCP_NAME} from {CONFIG_FILE}')
else:
    print(f'  MCP entry {MCP_NAME} not found in {CONFIG_FILE} (already removed?)')
" || warn "Failed to update OpenCode config"
}

# ---- 4c. register with Claude Code ------------------------------------------
register_claude_mcp() {
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

register_mcp() {
    case "$TARGET_MODE" in
        claude)   register_claude_mcp ;;
        opencode) register_opencode_mcp ;;
        all)      register_claude_mcp; register_opencode_mcp ;;
    esac
}

# ---- remove -----------------------------------------------------------------
remove_claude_mcp() {
    if command -v claude >/dev/null 2>&1; then
        log "Unregistering '$MCP_NAME' from Claude Code (scope: $MCP_SCOPE)"
        claude mcp remove "$MCP_NAME" --scope "$MCP_SCOPE" >/dev/null 2>&1 \
            && log "Removed MCP registration '$MCP_NAME'" \
            || warn "No registration '$MCP_NAME' found at scope '$MCP_SCOPE' (already gone?)"
    else
        warn "Claude Code CLI ('claude') not found — skipping unregistration."
        warn "Remove manually later with:  claude mcp remove $MCP_NAME --scope $MCP_SCOPE"
    fi
}

remove_mcp() {
    case "$TARGET_MODE" in
        claude)   remove_claude_mcp ;;
        opencode) remove_opencode_mcp ;;
        all)      remove_claude_mcp; remove_opencode_mcp ;;
    esac

    if [ -d "$INSTALL_DIR" ]; then
        log "Deleting $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    else
        warn "Directory not found: $INSTALL_DIR (already deleted?)"
    fi

    cat <<EOF

$(log "Removed.")
  MCP server : $MCP_NAME  (scope: $MCP_SCOPE, target: $TARGET_MODE)
  Location   : $INSTALL_DIR (deleted)

  >>> Restart your tool so the mcp__${MCP_NAME//-/_}__* tools unload. <<<
EOF
}

# ---- run --------------------------------------------------------------------
main() {
    case "$TARGET_MODE" in
        claude|opencode|all) ;;
        *) die "Invalid --target: '$TARGET_MODE' (must be claude, opencode, or all)" ;;
    esac

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
  MCP server : $MCP_NAME  (scope: $MCP_SCOPE, target: $TARGET_MODE)
  Location   : $INSTALL_DIR
  gdb-multiarch: $(command -v gdb-multiarch 2>/dev/null || echo 'NOT FOUND')

  >>> Restart your tool so the mcp__${MCP_NAME//-/_}__* tools load. <<<

  Typical aarch64 kernel debug flow:
    gdb_start(gdb_path="\$(command -v gdb-multiarch)")  -> session_id
    gdb_command(sid, "file /path/to/vmlinux")
    gdb_command(sid, "set architecture aarch64")
    gdb_command(sid, "target remote :1234")
    gdb_command(sid, "break schedule")
EOF
}

main
