#!/bin/bash
set -e

VMLINUX="vmlinux"

if [ ! -f "$VMLINUX" ]; then
    echo "ERROR: $VMLINUX not found. Please build kernel first."
    exit 1
fi

VMLINUX_INFO="$(file "$VMLINUX")"

case "$VMLINUX_INFO" in
    *"x86-64"*)
        ARCH="x86"
        GDB_ARCH="i386:x86-64"
        ;;
    *"aarch64"*|*"ARM aarch64"*)
        ARCH="arm64"
        GDB_ARCH="aarch64"
        ;;
    *"RISC-V"*)
        ARCH="riscv"
        GDB_ARCH="riscv:rv64"
        ;;
    *)
        echo "ERROR: unsupported vmlinux arch:"
        echo "$VMLINUX_INFO"
        exit 1
        ;;
esac

echo "VMLINUX: $VMLINUX_INFO"
echo "ARCH: $ARCH"
echo "GDB_ARCH: $GDB_ARCH"

GDB_CMDS=(
    "-ex" "set architecture $GDB_ARCH"
    "-ex" "set disassemble-next-line on"
    "-ex" "target remote :1234"
    "-ex" "b start_kernel"
    "-ex" "c"
)

exec gdb-multiarch "$VMLINUX" "${GDB_CMDS[@]}"
