#!/bin/bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

if ! groups | grep -q '\bkvm\b'; then
    echo "Adding $USER to kvm group..."
    sudo usermod -aG kvm "$USER"
fi

if [ -e /dev/kvm ] && [ ! -r /dev/kvm ]; then
    echo "Granting temporary read access to /dev/kvm..."
    sudo chmod 0666 /dev/kvm
fi

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

    local need_download=true
    if [ -f "$img_path" ] && qemu-img check "$img_path" >/dev/null 2>&1; then
        echo "$img already exists and passed integrity check, download skipped."
        need_download=false
    elif [ -f "$img_path" ]; then
        echo "$img exists but failed integrity check, re-downloading..."
    fi

    if $need_download; then
        echo "Download $arch rootfs..."
        wget -c --tries=3 --waitretry=5 -O "$img_path" "$url"
        echo "Verifying downloaded image..."
        if ! qemu-img check "$img_path" >/dev/null 2>&1; then
            echo "ERROR: $img_path failed integrity check after download."
            rm -f "$img_path"
            exit 1
        fi
        echo "$arch rootfs download verified."
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

# Link build.sh
echo "Link build.sh"
ln -sf "../scripts/linux/build.sh" "$KERNEL_SRC/build.sh"

# Link run-qemu.sh
echo "Link run-qemu.sh"
ln -sf "../scripts/linux/run-qemu.sh" "$KERNEL_SRC/run-qemu.sh"

# Link run-gdb.sh
echo "Link run-gdb.sh"
ln -sf "../scripts/linux/run-gdb.sh" "$KERNEL_SRC/run-gdb.sh"

echo "-----------------------------------------------------"
echo
echo "Kernel source"
echo "  cd $KERNEL_SRC"
echo
echo "Build kernel"
echo "  ARCH=[x86|arm64|riscv] ./build.sh build"
echo
echo "Start QEMU"
echo "  ./run-qemu.sh"
echo "  ./run-qemu.sh --help"
echo
echo "Debug with GDB"
echo "  ./run-gdb.sh"
echo
echo "====================================================="
echo "  Enable SSH access to guest VM  (manual steps)"
echo "====================================================="
echo "1. Setup ssh server in guest VM"
echo "    apt update"
echo "    apt install -y openssh-server"
echo "    echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config"
echo "    systemctl restart ssh"
echo "    passwd  # set a root password"
echo
echo "2. Generate ssh-key on HOST"
echo "    ssh-keygen  (bypass if you already have one)"
echo
echo "3. Copy the key guest VM"
echo "    ssh-copy-id -p 2222 root@localhost"
echo
echo "4. Connect to guest VM"
echo "    ssh -p 2222 root@localhost"
echo "-----------------------------------------------------"
echo "Done."
