# Linux Kernel Agent

A workspace for building, running, and debugging the Linux kernel under QEMU,
driven by Claude Code.

## Project Structure

```
linux/    # kernel source (build.sh, run-qemu.sh, run-gdb.sh symlinked in)
rootfs/   # QEMU Debian disk images
scripts/  # setup + linux/ helper scripts
  install-cc-connect.sh   # cc-connect install wizard (Feishu / WeChat)
user/     # all generated output (modules / programs / markdown)
```

## Installation

```bash
# 1. Install Claude Code (nvm + Node 20 + @anthropic-ai/claude-code)
./scripts/install_claude.sh
claude doctor

# 2. Install toolchain, clone kernel, fetch rootfs images, link scripts
./scripts/setup_linux.sh

# 3. Create the output directories
mkdir -p user/modules user/programs user/markdown
```

Run the helpers from inside `linux/`.

### `build.sh <command>`

```bash
cd linux/

./build.sh build                   # build kernel (host arch auto-detected)
ARCH=arm64 ./build.sh build        # cross build (ARCH=x86|arm64|riscv)
ARCH=arm64 CROSS_COMPILE=... build # override the auto-picked toolchain
./build.sh clean                   # make clean   (arch from .config)
./build.sh mrproper                # make mrproper (arch from .config)
```

`build` writes a `defconfig`, enables the project configs (9pfs, virtio, debug
info, GDB scripts, …), then builds the kernel image + modules. `CROSS_COMPILE`
defaults to `aarch64-linux-gnu-` / `riscv64-linux-gnu-` / `x86_64-linux-gnu-`.

### `run-qemu.sh [OPTIONS]`

```bash
./run-qemu.sh                      # foreground (arch auto-detected from vmlinux)
./run-qemu.sh --bg                 # detached; writes qemu.pid, qemu-boot.log
./run-qemu.sh --bg --wait-ssh      # detached, block until SSH is reachable
./run-qemu.sh --wait-gdb           # freeze CPU at boot, wait for GDB to connect (-S)
./run-qemu.sh --shutdown-bg        # graceful poweroff of a --bg instance
./run-qemu.sh --serial=stdio       # serial backend: stdio (fg default) or pty (--bg default)
./run-qemu.sh --logfile=PATH       # serial log file (default: serial.log)
./run-qemu.sh --help               # full option list
```

2 GB / 2 vCPUs, project root shared at `/mnt` via 9pfs, SSH on host port 2222,
and the GDB stub always on `:1234` (`nokaslr` set for stable addresses).

### `run-gdb.sh`

```bash
./run-gdb.sh                       # run after QEMU is up
```

Launches `gdb-multiarch` against `:1234`, sets the arch from `vmlinux`, sources
`vmlinux-gdb.py` (the `lx-*` helpers), and breaks at `start_kernel`.

## Enable QEMU SSH

The skills drive the guest over SSH (host port 2222). Set it up once:

```bash
# 1. In the guest VM
apt update && apt install -y openssh-server
echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
systemctl restart ssh
passwd                              # set a root password

# 2. On the host
ssh-keygen                          # skip if you already have a key
ssh-copy-id -p 2222 root@localhost

# 3. Connect
ssh -p 2222 root@localhost
```

## Using Claude

Inside a Claude Code session in this repo, two skills automate the loop:

- **`run-ko`** — build, `insmod`/`rmmod`, run, and debug a kernel module in the
  guest. It boots `run-qemu.sh --bg`, drives the module over SSH, and reads
  `serial.log` for dmesg. Just ask, e.g. *"build and load my hello module"*.

- **`debug-linux`** — source-level kernel debugging through the `mdb-gdb` MCP
  server (breakpoints, stepping, inspecting structs, panic/Oops/hang analysis).
  The MCP server is installed automatically on first use, then ask, e.g.
  *"set a breakpoint at do_sys_open and step through it"*.

## Install cc-connect (IM Bridge)

[cc-connect](https://github.com/chenhg5/cc-connect) bridges Claude Code to messaging platforms so you can chat with the agent from Feishu or WeChat.

### Install

```bash
bash scripts/install-cc-connect.sh [--backend claude|opencode]
```

The wizard installs the binary from GitHub, prompts for platform credentials, and writes `~/.cc-connect/config.toml`.

### Options

```
--backend <claude|opencode>         Set AI backend (skips interactive prompt)
--switch-backend <claude|opencode>  Switch backend in existing config without reinstalling
--remove                            Uninstall cc-connect binary and config
--help                              Show help
```

### Start

```bash
cc-connect
```

Config file: `~/.cc-connect/config.toml`

### Feishu setup (WebSocket — no public IP needed)

1. Create an enterprise app at https://open.feishu.cn/
2. Add permissions: `contact:user.base:readonly`, `im:message.p2p_msg:readonly`, `im:message.group_at_msg:readonly`, `im:message:send_as_bot`
3. Event subscription → **long connection** → add event `im.message.receive_v1` and callback `card.action.trigger`
4. Publish the app

### WeChat setup (ilink gateway)

After `cc-connect` is running:

```bash
cc-connect weixin setup --project linux-cc
```

Scan the QR code with WeChat to obtain and bind the token.

## Todo List

- Kdump and crash analysis
- Git log and lwn knowledge
- Mailling list / lore patch run
