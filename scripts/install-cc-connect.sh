#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[info]${NC} $*"; }
success() { echo -e "${GREEN}[ok]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC} $*"; }
die()     { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}==> $*${NC}"; }

prompt() {
    local var_name="$1" message="$2" default="${3:-}" input
    if [[ -n "$default" ]]; then
        echo -en "${BOLD}${message}${NC} [${default}]: "
    else
        echo -en "${BOLD}${message}${NC}: "
    fi
    read -r input
    [[ -z "$input" && -n "$default" ]] && input="$default"
    printf -v "$var_name" '%s' "$input"
}

prompt_secret() {
    local var_name="$1" message="$2" input
    echo -en "${BOLD}${message}${NC}: "
    read -rs input
    echo
    printf -v "$var_name" '%s' "$input"
}

prompt_nonempty() {
    local var_name="$1" message="$2" default="${3:-}"
    prompt "$var_name" "$message" "$default"
    while [[ -z "${!var_name}" ]]; do
        warn "不能为空"
        prompt "$var_name" "$message" "$default"
    done
}

prompt_secret_nonempty() {
    local var_name="$1" message="$2"
    prompt_secret "$var_name" "$message"
    while [[ -z "${!var_name}" ]]; do
        warn "不能为空"
        prompt_secret "$var_name" "$message"
    done
}

confirm() {
    local message="$1" default="${2:-y}" yn
    if [[ "$default" == "y" ]]; then
        echo -en "${BOLD}${message}${NC} [Y/n]: "
    else
        echo -en "${BOLD}${message}${NC} [y/N]: "
    fi
    read -r yn
    yn="${yn:-$default}"
    [[ "$yn" =~ ^[Yy]$ ]]
}

select_option() {
    local var_name="$1" message="$2"
    shift 2
    local options=("$@")
    echo -e "${BOLD}${message}${NC}"
    for i in "${!options[@]}"; do
        echo "  $((i+1))) ${options[$i]}"
    done
    local choice
    while true; do
        echo -en "请输入序号 [1-${#options[@]}]: "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            printf -v "$var_name" '%s' "${options[$((choice-1))]}"
            return
        fi
        warn "请输入有效序号"
    done
}

detect_platform() {
    local os arch
    case "$(uname -s)" in
        Linux)  os="linux"  ;;
        Darwin) os="darwin" ;;
        *) die "不支持的操作系统：$(uname -s)" ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) die "不支持的架构：$(uname -m)" ;;
    esac
    echo "${os}-${arch}"
}

install_from_github() {
    local install_dir="${1:-/usr/local/bin}"
    local repo="chenhg5/cc-connect"

    info "从 GitHub 获取最新版本..."
    local latest
    latest=$(curl -fsSL "https://api.github.com/repos/${repo}/releases" \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": "\(.*\)".*/\1/')
    [[ -z "$latest" ]] && die "无法获取最新版本，请检查网络"
    info "最新版本：${latest}"

    local platform filename download_url
    platform=$(detect_platform)
    filename="cc-connect-${latest}-${platform}.tar.gz"
    download_url="https://github.com/${repo}/releases/download/${latest}/${filename}"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' EXIT

    info "下载 ${filename}..."
    curl -fsSL --progress-bar "$download_url" -o "${tmp_dir}/${filename}" \
        || die "下载失败：${download_url}"

    info "解压..."
    tar -xzf "${tmp_dir}/${filename}" -C "$tmp_dir"

    local binary
    binary=$(find "$tmp_dir" -name "cc-connect*" -type f | head -1)
    [[ -f "$binary" ]] || die "解压后未找到 cc-connect 可执行文件"
    chmod +x "$binary"

    if [[ -w "$install_dir" ]]; then
        mv "$binary" "${install_dir}/cc-connect"
    else
        info "需要 sudo 权限安装到 ${install_dir}..."
        sudo mv "$binary" "${install_dir}/cc-connect"
    fi

    success "cc-connect ${latest} 已安装到 ${install_dir}/cc-connect"
}

CONFIG_DIR="$HOME/.cc-connect"

# ── 切换 backend ─────────────────────────────────────────────────────────────

do_switch_backend() {
    local backend="$1"
    local agent_type
    case "$backend" in
        claude)   agent_type="claudecode" ;;
        opencode) agent_type="opencode"   ;;
        *) die "--switch-backend 必须是 claude 或 opencode" ;;
    esac

    [[ -f "$CONFIG_DIR/config.toml" ]] || die "未找到配置文件：$CONFIG_DIR/config.toml"

    local current
    current=$(grep '^type = ' "$CONFIG_DIR/config.toml" | grep -E 'claudecode|opencode' | head -1 | sed 's/type = "\(.*\)"/\1/')

    if [[ "$current" == "$agent_type" ]]; then
        info "当前已经是 ${backend}（${agent_type}），无需切换"
        exit 0
    fi

    sed -i "s/^type = \"${current}\"/type = \"${agent_type}\"/" "$CONFIG_DIR/config.toml"
    success "已从 ${current} 切换为 ${agent_type}"
    exit 0
}

# ── 卸载 ─────────────────────────────────────────────────────────────────────

do_remove() {
    local binary="/usr/local/bin/cc-connect"
    local config_dir="$HOME/.cc-connect"

    echo -e "${BOLD}"
    echo "╔══════════════════════════════════════════╗"
    echo "║        cc-connect  Uninstall             ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"

    if [[ -f "$binary" ]]; then
        info "移除 cc-connect 二进制..."
        if [[ -w "$(dirname "$binary")" ]]; then
            rm -f "$binary"
        else
            sudo rm -f "$binary"
        fi
        success "二进制已移除：${binary}"
    else
        warn "未找到 cc-connect 二进制，跳过"
    fi

    if [[ -d "$config_dir" ]]; then
        if confirm "是否同时删除配置目录 ${config_dir}？" "n"; then
            rm -rf "$config_dir"
            success "配置目录已删除"
        else
            info "保留配置目录：${config_dir}"
        fi
    fi

    echo
    echo -e "${GREEN}${BOLD}✓ 卸载完成！${NC}"
    echo
    exit 0
}

# ── 参数解析 ──────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --backend <claude|opencode>         Set AI backend (skips interactive prompt)
  --switch-backend <claude|opencode>  Switch backend in existing config without reinstalling
  --remove                            Uninstall cc-connect binary and config
  --help, -h                          Show this help

Examples:
  $(basename "$0")                             Interactive install wizard
  $(basename "$0") --backend claude            Install with Claude Code backend
  $(basename "$0") --switch-backend opencode   Switch to OpenCode
  $(basename "$0") --remove                    Uninstall
EOF
    exit 0
}

BACKEND=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend)
            BACKEND="$2"
            shift 2
            ;;
        --switch-backend)
            do_switch_backend "$2"
            shift 2
            ;;
        --remove)
            do_remove
            ;;
        --help|-h)
            usage
            ;;
        *)
            die "未知参数：$1\n运行 $(basename "$0") --help 查看用法"
            ;;
    esac
done

if [[ -n "$BACKEND" && "$BACKEND" != "claude" && "$BACKEND" != "opencode" ]]; then
    die "--backend 必须是 claude 或 opencode"
fi

# ── 主流程 ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="$CONFIG_DIR/config.toml"

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════╗"
echo "║        cc-connect  Install Wizard        ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

# ── Step 1: 依赖检查 ──────────────────────────────────────────────────────────

header "Step 1 — 检查依赖"

for cmd in curl tar; do
    command -v "$cmd" &>/dev/null || die "未找到 ${cmd}，请先安装"
    success "$cmd"
done

# ── Step 2: 安装 cc-connect ───────────────────────────────────────────────────

header "Step 2 — 安装 cc-connect"

if command -v cc-connect &>/dev/null; then
    CC_VER=$(cc-connect --version 2>/dev/null || echo "unknown")
    success "cc-connect 已安装（${CC_VER}）"
    if confirm "重新安装最新版本？" "n"; then
        install_from_github "/usr/local/bin"
    fi
else
    install_from_github "/usr/local/bin"
fi

# ── Step 3: 选择 backend ──────────────────────────────────────────────────────

header "Step 3 — 选择 AI Backend"

if [[ -z "$BACKEND" ]]; then
    select_option BACKEND "使用哪个 AI 编程助手？" "claude" "opencode"
fi

case "$BACKEND" in
    claude)   AGENT_TYPE="claudecode" ;;
    opencode) AGENT_TYPE="opencode"   ;;
esac

success "Backend：${BACKEND}（agent type: ${AGENT_TYPE}）"

# ── Step 4: 项目配置 & 覆盖确认 ──────────────────────────────────────────────

header "Step 4 — 项目配置"

prompt_nonempty PROJECT_NAME "项目名称" "linux-cc"
prompt_nonempty WORK_DIR     "项目工作目录" "${PROJECT_ROOT}"

WRITE_CONFIG=true
if [[ -f "$CONFIG_FILE" ]]; then
    warn "检测到已有配置文件：${CONFIG_FILE}"
    if ! confirm "覆盖现有配置？" "n"; then
        info "保留现有配置，跳过平台配置与写入步骤"
        WRITE_CONFIG=false
    fi
fi

# ── Step 5: 飞书接入 ──────────────────────────────────────────────────────────

USE_FEISHU=false
USE_WEIXIN=false

if [[ "$WRITE_CONFIG" == true ]]; then

header "Step 5 — 飞书接入"

if confirm "是否接入飞书？"; then
    USE_FEISHU=true
    echo
    echo -e "  请在飞书开放平台 ${CYAN}https://open.feishu.cn/${NC} 完成以下配置后继续："
    echo "  1. 创建企业自建应用"
    echo "  2. 添加权限："
    echo "       contact:user.base:readonly"
    echo "       im:message.p2p_msg:readonly"
    echo "       im:message.group_at_msg:readonly"
    echo "       im:message:send_as_bot"
    echo "  3. 事件订阅方式选「使用长连接接收事件」"
    echo "     添加事件  im.message.receive_v1"
    echo "     添加回调  card.action.trigger"
    echo "  4. 发布应用"
    echo
    prompt_nonempty        FEISHU_APP_ID     "飞书 App ID（cli_xxxx）"
    prompt_secret_nonempty FEISHU_APP_SECRET "飞书 App Secret"
fi

# ── Step 6: 个人微信接入 ──────────────────────────────────────────────────────

header "Step 6 — 个人微信接入"

if confirm "是否接入个人微信？" "n"; then
    USE_WEIXIN=true
    echo
    echo "  个人微信通过 ilink 机器人网关接入，需要扫码获取 Token。"
    echo "  安装完成后执行以下命令扫码绑定："
    echo -e "    ${CYAN}cc-connect weixin setup --project ${PROJECT_NAME}${NC}"
    echo "  扫码后将显示的 Token 填入下方，或留空后续手动写入配置。"
    echo
    prompt WEIXIN_TOKEN "微信 Token（留空可后续手动填写）"
fi

[[ "$USE_FEISHU" == false && "$USE_WEIXIN" == false ]] && \
    warn "未选择任何 IM 平台，将生成无平台的配置（可后续手动添加）"

fi  # WRITE_CONFIG

# ── Step 7: 写入配置 ──────────────────────────────────────────────────────────

header "Step 7 — 写入配置"

if [[ "$WRITE_CONFIG" == true ]]; then
    mkdir -p "$CONFIG_DIR"

    {
        echo 'language = "zh"'
        echo ''
        echo '[[projects]]'
        echo "name = \"${PROJECT_NAME}\""
        echo ''
        echo '[projects.agent]'
        echo "type = \"${AGENT_TYPE}\""
        echo ''
        echo '[projects.agent.options]'
        echo "work_dir = \"${WORK_DIR}\""
        echo 'mode = "auto"'

        if [[ "$USE_FEISHU" == true ]]; then
            echo ''
            echo '[[projects.platforms]]'
            echo 'type = "feishu"'
            echo ''
            echo '[projects.platforms.options]'
            echo "app_id = \"${FEISHU_APP_ID}\""
            echo "app_secret = \"${FEISHU_APP_SECRET}\""
            echo 'enable_feishu_card = true'
            echo 'thread_isolation = true'
        fi

        if [[ "$USE_WEIXIN" == true ]]; then
            echo ''
            echo '[[projects.platforms]]'
            echo 'type = "weixin"'
            echo ''
            echo '[projects.platforms.options]'
            echo "token = \"${WEIXIN_TOKEN:-}\""
            echo 'allow_from = "*"'
        fi
    } > "$CONFIG_FILE"

    success "配置已写入：${CONFIG_FILE}"
else
    info "跳过配置写入"
fi

# ── 完成提示 ──────────────────────────────────────────────────────────────────

echo
echo -e "${GREEN}${BOLD}✓ 安装完成！${NC}"
echo
echo -e "  配置文件：${CYAN}${CONFIG_FILE}${NC}"
echo
echo -e "  ${BOLD}启动：${NC}"
echo -e "    ${CYAN}cc-connect${NC}"
echo

if [[ "$USE_WEIXIN" == true && -z "${WEIXIN_TOKEN:-}" ]]; then
    warn "个人微信 Token 未填写，启动后请执行："
    echo -e "    ${CYAN}cc-connect weixin setup --project ${PROJECT_NAME}${NC}"
    echo
fi
