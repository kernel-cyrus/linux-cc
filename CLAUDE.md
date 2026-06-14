# Linux Kernel Agent

This workspace is used for organizing kernel workflows, testing kernel features, and answering kernel-related questions.

## Directory Structure

```
linux-cc/
├── linux/          # Kernel source code (reference for all kernel questions)
├── rootfs/         # QEMU disk images (amd64 / arm64 / riscv64 Debian)
├── scripts/        # Setup scripts
│   └── linux/      # build.sh, run-qemu.sh, run-gdb.sh (symlinked into linux/)
├── .claude/skills/debug-linux/  # debug-linux skill + setup_gdb_mcp.sh (installs the mdb-gdb GDB MCP server)
├── mcp/            # Cloned MCP servers (gitignored; MDB-MCP lives here)
└── user/           # All user-created output goes here
    ├── modules/    # Kernel modules (.ko and their source)
    ├── programs/   # Userspace test programs
    └── markdown/   # Notes, analysis, and documentation
```

## Scripts (run from linux/ directory)

`build.sh`, `run-qemu.sh`, and `run-gdb.sh` live in `scripts/linux/` and are
symlinked into `linux/`, so run them from there. Edit only the real files under
`scripts/linux/`; the `linux/` entries are symlinks and reflect changes automatically.

```bash
cd linux/

# Build kernel (auto-detects host arch; set ARCH= to cross-compile)
./build.sh build
ARCH=arm64 ./build.sh build
ARCH=riscv ./build.sh build

# Clean / mrproper (arch auto-detected from .config)
./build.sh clean
./build.sh mrproper

# Start QEMU (auto-detects arch from vmlinux)
./run-qemu.sh                    # foreground, serial on stdio
./run-qemu.sh --bg --wait-ssh   # background, block until SSH is up
./run-qemu.sh --wait-gdb        # freeze CPU at boot, wait for GDB to connect
./run-qemu.sh --shutdown-bg     # graceful poweroff of a --bg instance

# Attach GDB directly (run after QEMU is started; connects to :1234)
./run-gdb.sh
```

`run-qemu.sh` options: `--bg` (detached), `--wait-ssh` (wait for SSH after `--bg`),
`--wait-gdb` (boot with `-S`, freeze CPUs until GDB connects and continues),
`--shutdown-bg` (poweroff, falling back to SIGTERM), `--serial=stdio|pty`,
`--logfile=PATH` (serial log, default `serial.log`). In `--bg` mode it writes
`qemu.pid`, logs the console to `linux/serial.log`, and boot output to
`linux/qemu-boot.log`.

## QEMU Details

- Memory: 2048 MB, 2 CPUs
- The project root (`linux-cc/`) is shared into the VM at `/mnt` via 9pfs (virtio),
  so files under `user/` are reachable in the guest at `/mnt/user/...` (no copying)
- **SSH:** host port 2222 forwards to guest :22 —
  `ssh -p 2222 -o StrictHostKeyChecking=no root@localhost '<cmd>'`
- `-s` flag enables the GDB stub on port 1234 (always on while QEMU runs)
- `nokaslr` is set on the kernel cmdline, so symbol addresses are stable
- Supported targets: x86_64, arm64 (cortex-a57), riscv64

## Kernel Debugging (GDB)

Two ways to drive GDB against the QEMU stub on `:1234`:

- **`./run-gdb.sh`** — launches `gdb-multiarch` directly, sets the arch from
  `vmlinux`, sources `vmlinux-gdb.py`, and breaks at `start_kernel`.
- **`mdb-gdb` MCP server** — drives `gdb-multiarch` through the
  `mcp__mdb-gdb__*` tools. Install/register with
  `.claude/skills/debug-linux/setup_gdb_mcp.sh --install-deps`; the tools appear only after a
  Claude Code restart. See the **debug-linux** skill for the full flow.

## Skills

- **run-ko** — build, load (`insmod`/`rmmod`), run, and debug a kernel module
  inside the QEMU guest; drives `run-qemu.sh --bg` + SSH and reads `serial.log`.
- **debug-linux** — source-level kernel debugging via the `mdb-gdb` MCP server
  (breakpoints, stepping, inspecting structures, panic/Oops/hang analysis).

## Output Conventions

Always save generated files under `user/`:

| Type | Directory |
|------|-----------|
| Kernel modules (`.ko`, `Makefile`, `.c`) | `user/modules/<module-name>/` |
| Userspace test programs | `user/programs/<program-name>/` |
| Markdown notes and analysis | `user/markdown/` |

### Module Makefile template

Every module Makefile must `include ../common.mk` instead of hardcoding `KDIR`, `ARCH`, or `CROSS_COMPILE`. `common.mk` automatically detects the kernel arch from `vmlinux` and sets those variables only when cross-compiling.

```makefile
include ../common.mk

obj-m := <module>.o

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
```

## Kernel Source Reference

When answering kernel questions, read source from `linux/`. Key locations:

- Core kernel: `linux/kernel/`
- Memory management: `linux/mm/`
- Filesystems: `linux/fs/`
- Drivers: `linux/drivers/`
- Architecture-specific: `linux/arch/<arch>/`
- Kernel headers: `linux/include/linux/`
- Documentation: `linux/Documentation/`

**Architecture alignment:** Before analyzing arch-specific code, always run `file linux/vmlinux` to determine the current build architecture, then use the matching `linux/arch/<arch>/` source path. Do not read arch-specific code for a different architecture than what vmlinux was built for.

## Build Configuration

`build.sh build` enables these configs automatically: `KALLSYMS_ALL`, `NET_9P`,
`NET_9P_VIRTIO`, `VIRTIO_BLK`, `VIRTIO_PCI`, `VIRTIO_FS`, `9P_FS`,
`9P_FS_POSIX_ACL`, `FUSE_FS`, `CUSE`, `DEBUG_INFO`, `GDB_SCRIPTS`, `READABLE_ASM`,
`FUNCTION_TRACER`. It disables `DEBUG_INFO_REDUCED` (so full debug info is kept) and
runs `make scripts_gdb` to emit `vmlinux-gdb.py` (the `lx-*` helpers).

Cross-compilers (auto-set when `ARCH` differs from the host): `aarch64-linux-gnu-`
(arm64), `riscv64-linux-gnu-` (riscv), `x86_64-linux-gnu-` (x86).
