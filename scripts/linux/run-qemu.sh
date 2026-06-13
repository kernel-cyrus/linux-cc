#!/bin/bash
set -e

VMLINUX="vmlinux"
ROOTFS_DIR="../rootfs"
ROOT_DIR=".."

if [ ! -f "$VMLINUX" ]; then
    echo "ERROR: $VMLINUX not found. Please build kernel first."
    exit 1
fi

VMLINUX_INFO="$(file "$VMLINUX")"

case "$VMLINUX_INFO" in
    *"x86-64"*)
        ARCH="x86"
        QEMU="qemu-system-x86_64"
        MACHINE="accel=tcg"
        KERNEL_IMAGE="arch/x86/boot/bzImage"
        ROOTFS_IMAGE="$ROOTFS_DIR/debian-12-nocloud-amd64.qcow2"
        ROOT_DEV="/dev/vda1"
        CONSOLE="ttyS0"
        EXTRA_APPEND="earlycon=uart,io,0x3f8,115200 nokaslr"
        EXTRA_QEMU_ARGS=()
        ;;
    *"aarch64"*|*"ARM aarch64"*)
        ARCH="arm64"
        QEMU="qemu-system-aarch64"
        MACHINE="virt,accel=tcg"
        KERNEL_IMAGE="arch/arm64/boot/Image"
        ROOTFS_IMAGE="$ROOTFS_DIR/debian-12-nocloud-arm64.qcow2"
        ROOT_DEV="/dev/vda1"
        CONSOLE="ttyAMA0"
        EXTRA_APPEND="earlycon=pl011,0x09000000 nokaslr"
        EXTRA_QEMU_ARGS=(
            -cpu cortex-a57
        )
        ;;
    *"RISC-V"*)
        ARCH="riscv"
        QEMU="qemu-system-riscv64"
        MACHINE="virt"
        KERNEL_IMAGE="arch/riscv/boot/Image"
        ROOTFS_IMAGE="$ROOTFS_DIR/debian-sid-nocloud-riscv64-daily.qcow2"
        ROOT_DEV="/dev/vda1"
        CONSOLE="ttyS0"
        EXTRA_APPEND="earlycon=sbi nokaslr"
        EXTRA_QEMU_ARGS=()
        ;;
    *)
        echo "ERROR: unsupported vmlinux arch:"
        echo "$VMLINUX_INFO"
        exit 1
        ;;
esac

if [ ! -f "$KERNEL_IMAGE" ]; then
    echo "ERROR: kernel image not found: $KERNEL_IMAGE"
    exit 1
fi

if [ ! -f "$ROOTFS_IMAGE" ]; then
    echo "ERROR: rootfs image not found: $ROOTFS_IMAGE"
    exit 1
fi

echo "VMLINUX: $VMLINUX_INFO"
echo "ARCH: $ARCH"
echo "QEMU: $QEMU"
echo "KERNEL_IMAGE: $KERNEL_IMAGE"
echo "ROOTFS_IMAGE: $ROOTFS_IMAGE"

"$QEMU" \
    -m 2048 \
    -smp 2 \
    -machine "$MACHINE" \
    "${EXTRA_QEMU_ARGS[@]}" \
    -kernel "$KERNEL_IMAGE" \
    -drive file="$ROOTFS_IMAGE",if=virtio,format=qcow2 \
    -virtfs local,path="$ROOT_DIR",mount_tag=hostshare,security_model=mapped-xattr,id=hostshare \
    -append "root=$ROOT_DEV rw console=$CONSOLE $EXTRA_APPEND systemd.show_status=false" \
    -serial mon:stdio \
    -nographic \
    -s

# Mount 9pfs:
# 1. sudo mount -t 9p -o trans=virtio,version=9p2000.L hostshare /mnt
# 2. echo 'hostshare  /mnt  9p  trans=virtio,version=9p2000.L  0  0' | sudo tee -a /etc/fstab
