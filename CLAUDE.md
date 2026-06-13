# Linux Kernel Agent

This workspace is used for organizing kernel workflows, testing kernel features, and answering kernel-related questions.

## Directory Structure

```
linux-cc/
├── linux/          # Kernel source code (reference for all kernel questions)
├── rootfs/         # QEMU disk images (amd64 / arm64 / riscv64 Debian)
├── scripts/        # Setup scripts
└── user/           # All user-created output goes here
    ├── modules/    # Kernel modules (.ko and their source)
    ├── programs/   # Userspace test programs
    └── markdown/   # Notes, analysis, and documentation
```

## Scripts (run from linux/ directory)

```bash
cd linux/

# Build kernel (auto-detects host arch; set ARCH= to cross-compile)
./build.sh
ARCH=arm64 ./build.sh
ARCH=riscv ./build.sh

# Start QEMU (auto-detects arch from vmlinux)
./run-qemu.sh

# Attach GDB (run after QEMU is started; connects to :1234)
./run-gdb.sh
```

## QEMU Details

- Memory: 2048 MB, 2 CPUs
- The project root (`linux-cc/`) is shared into the VM at `/mnt` via 9pfs (virtio)
- `-s` flag enables GDB server on port 1234
- Supported targets: x86_64, arm64 (cortex-a57), riscv64

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

`build.sh` enables these configs automatically: `KALLSYMS_ALL`, `DEBUG_INFO`, `GDB_SCRIPTS`, `READABLE_ASM`, `FUNCTION_TRACER`, `NET_9P`, `VIRTIO_*`, `9P_FS`, `FUSE_FS`.

Cross-compilers: `aarch64-linux-gnu-` (arm64), `riscv64-linux-gnu-` (riscv).
