#!/bin/bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Kernel source
KERNEL_SRC="$ROOT_DIR/linux"
KERNEL_GIT="https://kernel.googlesource.com/pub/scm/linux/kernel/git/stable/linux.git"
KERNEL_TAG=""

# Debian rootfs
ROOTFS_DIR="$ROOT_DIR/rootfs"
ROOTFS_LIST=(
    "x86:debian-12-nocloud-amd64.qcow2:https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-amd64.qcow2"
    "arm64:debian-12-nocloud-arm64.qcow2:https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-arm64.qcow2"
    "riscv:debian-sid-nocloud-riscv64-daily.qcow2:https://cdimage.debian.org/images/cloud/sid/daily/latest/debian-sid-nocloud-riscv64-daily.qcow2"
)

# Install dependencies
echo "Installing dependencies..."
sudo apt-get update
sudo apt-get install -y \
    git \
    wget \
    curl \
    ca-certificates \
    make \
    gcc \
    g++ \
    libc6-dev \
    flex \
    bison \
    bc \
    perl \
    python3 \
    python3-pip \
    python3-setuptools \
    libssl-dev \
    libelf-dev \
    libncurses-dev \
    libncurses5-dev \
    libncursesw5-dev \
    dwarves \
    pahole \
    cpio \
    rsync \
    xz-utils \
    zstd \
    kmod \
    file \
    qemu-system-x86 \
    qemu-system-arm \
    qemu-system-misc \
    qemu-utils \
    libguestfs-tools \
    gdb \
    gdb-multiarch \
    gcc-aarch64-linux-gnu \
    gcc-riscv64-linux-gnu

export LIBGUESTFS_BACKEND=direct

# Download kernel source
if [ ! -d "$KERNEL_SRC" ] || [ ! -d "$KERNEL_SRC/.git" ]; then
    echo "Clone kernel source: $KERNEL_GIT"
    git clone "$KERNEL_GIT" "$KERNEL_SRC"
else
    echo "Linux source already exists at $KERNEL_SRC, clone skipped."
fi

cd "$KERNEL_SRC"

if [ -n "$KERNEL_TAG" ]; then
    echo "Fetch kernel tags..."
    git fetch --tags origin

    echo "Checkout kernel tag: $KERNEL_TAG"
    git -c advice.detachedHead=false checkout "$KERNEL_TAG"
else
    echo "KERNEL_TAG is empty, checkout skipped."
fi

# Download debian rootfs and update
mkdir -p "$ROOTFS_DIR"

echo "Checking /boot/vmlinuz-* read permission..."
if find /boot -maxdepth 1 -name 'vmlinuz-*' -readable 2>/dev/null | grep -q .; then
    echo "/boot/vmlinuz-* is readable, skipped."
else
    echo "Granting read permission on /boot/vmlinuz-* (needed by libguestfs)..."
    if ls /boot/vmlinuz-* >/dev/null 2>&1; then
        sudo chmod +r /boot/vmlinuz-*
    else
        echo "WARNING: /boot/vmlinuz-* not found, continue."
    fi
fi

update_mirror() {
    local mount_dir="$1"
    local rel_file="$2"
    local url="$3"
    local file="$mount_dir$rel_file"

    if [ ! -f "$file" ]; then
        echo "$rel_file not found, skipping."
    elif [ "$(cat "$file")" = "$url" ]; then
        echo "$rel_file already set, skipped."
    else
        echo "$url" > "$file"
        echo "Update $rel_file to $url."
    fi
}

update_rootfs() {
    local arch="$1"
    local img="$2"
    local url="$3"
    local img_path="$ROOTFS_DIR/$img"
    local mount_dir

    echo
    echo "========================================"
    echo "Processing rootfs: $arch"
    echo "Image: $img"
    echo "URL: $url"
    echo "========================================"

    if [ ! -f "$img_path" ]; then
        echo "Download $arch rootfs..."
        wget -O "$img_path" "$url"
    else
        echo "$img already exists at $ROOTFS_DIR, download skipped."
    fi

    echo "Updating $arch rootfs image..."
    mount_dir="$(mktemp -d)"

    cleanup_qcow2() {
        guestunmount "$mount_dir" 2>/dev/null || true
        rmdir "$mount_dir" 2>/dev/null || true
    }

    trap cleanup_qcow2 RETURN

    echo "Mounting $img at $mount_dir..."
    guestmount -a "$img_path" -i --rw "$mount_dir"

    mkdir -p "$mount_dir/mnt"

    # Update /etc/fstab to mount 9pfs
    local fstab_line="hostshare  /mnt  9p  trans=virtio,version=9p2000.L  0  0"

    if [ -f "$mount_dir/etc/fstab" ] && grep -q '^hostshare[[:space:]]' "$mount_dir/etc/fstab"; then
        echo "fstab already set, skipped."
    else
        echo "$fstab_line" >> "$mount_dir/etc/fstab"
        echo "Add 9p mount to fstab"
    fi

    # Update apt mirrors
    update_mirror "$mount_dir" /etc/apt/mirrors/debian.list          https://mirrors.aliyun.com/debian
    update_mirror "$mount_dir" /etc/apt/mirrors/debian-security.list https://mirrors.aliyun.com/debian-security

    echo "Unmounting $mount_dir..."
    cleanup_qcow2
    trap - RETURN

    echo "$arch rootfs update done."
}

for item in "${ROOTFS_LIST[@]}"; do
    IFS=':' read -r arch img url <<< "$item"
    update_rootfs "$arch" "$img" "$url"
done

echo
echo "All rootfs images are ready in: $ROOTFS_DIR"

# Generate build.sh
echo "Generate build.sh"
cat > "$KERNEL_SRC/build.sh" <<'EOF'
#!/bin/bash
set -e

HOST_ARCH="$(uname -m)"

case "$HOST_ARCH" in
    x86_64)
        DEFAULT_ARCH="x86"
        ;;
    aarch64|arm64)
        DEFAULT_ARCH="arm64"
        ;;
    riscv64)
        DEFAULT_ARCH="riscv"
        ;;
    *)
        echo "ERROR: unsupported host arch: $HOST_ARCH"
        exit 1
        ;;
esac

ARCH="${ARCH:-$DEFAULT_ARCH}"
CROSS_COMPILE="${CROSS_COMPILE:-}"

MAKE_ARGS=(
    ARCH="$ARCH"
)

if [ -n "$CROSS_COMPILE" ]; then
    MAKE_ARGS+=(
        CROSS_COMPILE="$CROSS_COMPILE"
    )
fi

case "$ARCH" in
    x86)
        DEFCONFIG="x86_64_defconfig"
        IMAGE_TARGET="bzImage"
        ;;
    arm64)
        DEFCONFIG="defconfig"
        IMAGE_TARGET="Image"
        ;;
    riscv)
        DEFCONFIG="defconfig"
        IMAGE_TARGET="Image"
        ;;
    *)
        echo "ERROR: unsupported ARCH: $ARCH"
        exit 1
        ;;
esac

CONFIGS=(
    KALLSYMS_ALL
    NET_9P
    NET_9P_VIRTIO
    VIRTIO_BLK
    VIRTIO_PCI
    FUSE_FS
    CUSE
    VIRTIO_FS
    9P_FS
    9P_FS_POSIX_ACL
    DEBUG_INFO
    GDB_SCRIPTS
    READABLE_ASM
    FUNCTION_TRACER
)

echo "HOST_ARCH=$HOST_ARCH"
echo "ARCH=$ARCH"
echo "CROSS_COMPILE=$CROSS_COMPILE"
echo "DEFCONFIG=$DEFCONFIG"
echo "IMAGE_TARGET=$IMAGE_TARGET"

if [ ! -f .config ]; then
    make "${MAKE_ARGS[@]}" "$DEFCONFIG"
fi

for cfg in "${CONFIGS[@]}"; do
    scripts/config --enable "$cfg"
done

make "${MAKE_ARGS[@]}" olddefconfig

make "${MAKE_ARGS[@]}" -j"$(nproc)" "$IMAGE_TARGET" modules
EOF
chmod +x "$KERNEL_SRC/build.sh"

# Generate run-qemu.sh
echo "Generate run-qemu.sh"
cat > "$KERNEL_SRC/run-qemu.sh" <<EOF
#!/bin/bash
set -e

VMLINUX="vmlinux"
ROOTFS_DIR="$ROOTFS_DIR"
ROOT_DIR="$ROOT_DIR"

if [ ! -f "\$VMLINUX" ]; then
    echo "ERROR: \$VMLINUX not found. Please build kernel first."
    exit 1
fi

VMLINUX_INFO="\$(file "\$VMLINUX")"

case "\$VMLINUX_INFO" in
    *"x86-64"*)
        ARCH="x86"
        QEMU="qemu-system-x86_64"
        MACHINE="accel=tcg"
        KERNEL_IMAGE="arch/x86/boot/bzImage"
        ROOTFS_IMAGE="\$ROOTFS_DIR/debian-12-nocloud-amd64.qcow2"
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
        ROOTFS_IMAGE="\$ROOTFS_DIR/debian-12-nocloud-arm64.qcow2"
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
        ROOTFS_IMAGE="\$ROOTFS_DIR/debian-sid-nocloud-riscv64-daily.qcow2"
        ROOT_DEV="/dev/vda1"
        CONSOLE="ttyS0"
        EXTRA_APPEND="earlycon=sbi nokaslr"
        EXTRA_QEMU_ARGS=()
        ;;
    *)
        echo "ERROR: unsupported vmlinux arch:"
        echo "\$VMLINUX_INFO"
        exit 1
        ;;
esac

if [ ! -f "\$KERNEL_IMAGE" ]; then
    echo "ERROR: kernel image not found: \$KERNEL_IMAGE"
    exit 1
fi

if [ ! -f "\$ROOTFS_IMAGE" ]; then
    echo "ERROR: rootfs image not found: \$ROOTFS_IMAGE"
    exit 1
fi

echo "VMLINUX: \$VMLINUX_INFO"
echo "ARCH: \$ARCH"
echo "QEMU: \$QEMU"
echo "KERNEL_IMAGE: \$KERNEL_IMAGE"
echo "ROOTFS_IMAGE: \$ROOTFS_IMAGE"

"\$QEMU" \\
    -m 2048 \\
    -smp 2 \\
    -machine "\$MACHINE" \\
    "\${EXTRA_QEMU_ARGS[@]}" \\
    -kernel "\$KERNEL_IMAGE" \\
    -drive file="\$ROOTFS_IMAGE",if=virtio,format=qcow2 \\
    -virtfs local,path="\$ROOT_DIR",mount_tag=hostshare,security_model=mapped-xattr,id=hostshare \\
    -append "root=\$ROOT_DEV rw console=\$CONSOLE \$EXTRA_APPEND systemd.show_status=false" \\
    -serial mon:stdio \\
    -nographic \\
    -s

# Mount 9pfs:
# 1. sudo mount -t 9p -o trans=virtio,version=9p2000.L hostshare /mnt
# 2. echo 'hostshare  /mnt  9p  trans=virtio,version=9p2000.L  0  0' | sudo tee -a /etc/fstab
EOF
chmod +x "$KERNEL_SRC/run-qemu.sh"

# Generate run-gdb.sh
echo "Generate run-gdb.sh"
cat > "$KERNEL_SRC/run-gdb.sh" <<'EOF'
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
EOF
chmod +x "$KERNEL_SRC/run-gdb.sh"

echo "-----------------------------"
echo "Kernel source"
echo "  cd $KERNEL_SRC"
echo
echo "Build kernel"
echo "  ./build.sh"
echo "  ARCH=x86 ./build.sh"
echo "  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- ./build.sh"
echo "  ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- ./build.sh"
echo
echo "Start QEMU"
echo "  ./run-qemu.sh"
echo
echo "Debug with GDB"
echo "  ./run-gdb.sh"
echo "-----------------------------"
echo "Done."
