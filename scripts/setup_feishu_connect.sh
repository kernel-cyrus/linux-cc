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
    local var_name="$1"
    local message="$2"
    local default="${3:-}"
    local input

    if [[ -n "$default" ]]; then
        echo -en "${BOLD}${message}${NC} [${default}]: "
    else
        echo -en "${BOLD}${message}${NC}: "
    fi

    read -r input
    if [[ -z "$input" && -n "$default" ]]; then
        input="$default"
    fi
    printf -v "$var_name" '%s' "$input"
}

prompt_secret() {
    local var_name="$1"
    local message="$2"
    local input

    echo -en "${BOLD}${message}${NC}: "
    read -rs input
    echo
    printf -v "$var_name" '%s' "$input"
}

confirm() {
    local message="$1"
    local default="${2:-y}"
    local yn

    if [[ "$default" == "y" ]]; then
        echo -en "${BOLD}${message}${NC} [Y/n]: "
    else
        echo -en "${BOLD}${message}${NC} [y/N]: "
    fi
    read -r yn
    yn="${yn:-$default}"
    [[ "$yn" =~ ^[Yy]$ ]]
}

detect_platform() {
    local os arch
    case "$(uname -s)" in
        Linux)  os="linux"  ;;
        Darwin) os="darwin" ;;
        *)      die "不支持的操作系统：$(uname -s)" ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
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

    local platform
    platform=$(detect_platform)
    local filename="cc-connect-${latest}-${platform}.tar.gz"
    local download_url="https://github.com/${repo}/releases/download/${latest}/${filename}"

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="$HOME/.cc-connect"
CONFIG_FILE="$CONFIG_DIR/config.toml"

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════╗"
echo "║       cc-connect × 飞书 Setup Wizard     ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

header "Step 1 / 4 — 检查依赖"

for cmd in curl tar; do
    command -v "$cmd" &>/dev/null || die "未找到 ${cmd}，请先安装"
    success "$cmd"
done

header "Step 2 / 4 — 安装 cc-connect"

if command -v cc-connect &>/dev/null; then
    CC_VER=$(cc-connect --version 2>/dev/null || echo "unknown")
    success "cc-connect 已安装（${CC_VER}），跳过"
    if confirm "重新安装最新版本？" "n"; then
        install_from_github "/usr/local/bin"
    fi
else
    install_from_github "/usr/local/bin"
fi

header "Step 3 / 4 — 项目与飞书应用配置"

SKIP_CONFIG=false
if [[ -f "$CONFIG_FILE" ]]; then
    warn "检测到已有配置文件：${CONFIG_FILE}"
    if ! confirm "覆盖现有配置？"; then
        info "保留现有配置，跳过 Step 3/4"
        SKIP_CONFIG=true
    fi
fi

if [[ "$SKIP_CONFIG" == false ]]; then

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

prompt PROJECT_NAME "项目名称" "linux-cc"
prompt WORK_DIR     "项目工作目录" "${PROJECT_ROOT}"
prompt APP_ID       "飞书 App ID（cli_xxxx）"

while [[ -z "$APP_ID" ]]; do
    warn "App ID 不能为空"
    prompt APP_ID "飞书 App ID（cli_xxxx）"
done

prompt_secret APP_SECRET "飞书 App Secret"

while [[ -z "$APP_SECRET" ]]; do
    warn "App Secret 不能为空"
    prompt_secret APP_SECRET "飞书 App Secret"
done

header "Step 4 / 4 — 写入配置"

mkdir -p "$CONFIG_DIR"

cat > "$CONFIG_FILE" <<TOML
[[projects]]
name = "${PROJECT_NAME}"

[projects.agent]
type = "claudecode"

[projects.agent.options]
work_dir = "${WORK_DIR}"
mode = "auto"

[[projects.platforms]]
type = "feishu"

[projects.platforms.options]
app_id = "${APP_ID}"
app_secret = "${APP_SECRET}"
enable_feishu_card = true
thread_isolation = true
TOML

success "配置已写入：${CONFIG_FILE}"

fi  # SKIP_CONFIG

echo
echo -e "${GREEN}${BOLD}✓ 安装完成！${NC}"
echo
echo "  启动服务："
echo -e "    ${CYAN}cc-connect${NC}"
echo
echo "  或后台运行："
echo -e "    ${CYAN}nohup cc-connect > ~/.cc-connect/cc-connect.log 2>&1 &${NC}"
echo

if confirm "现在启动 cc-connect？"; then
    echo
    info "正在启动（Ctrl+C 停止）..."
    exec cc-connect
fi
