#!/bin/bash
set -e

CMD="${1:-}"

case "$(uname -m)" in
    x86_64)
        HOST_ARCH="x86"
        ;;
    aarch64|arm64)
        HOST_ARCH="arm64"
        ;;
    riscv64)
        HOST_ARCH="riscv"
        ;;
    *)
        echo "ERROR: unsupported host arch: $(uname -m)"
        exit 1
        ;;
esac

show_help() {
    echo "Usage: ./build.sh <command>"
    echo ""
    echo "Commands:"
    echo "  build      Build the kernel"
    echo "  clean      Run make clean"
    echo "  mrproper   Run make mrproper"
    echo ""
    echo "Examples:"
    echo "  ARCH=arm64 ./build.sh build  - cross build to arm64"
    echo "  ./bulid.sh buld              - arch is auto-detected"
    echo "  ./build.sh clean             - arch is auto-detected from .config"
    echo "  ./build.sh mrproper          - arch is auto-detected form .config"
}

detect_arch() {
    if [ ! -f .config ]; then
        echo "ERROR: .config not found, cannot determine arch." >&2
        exit 1
    fi
    if grep -q '^CONFIG_X86_64=y' .config; then
        echo "x86"
    elif grep -q '^CONFIG_ARM64=y' .config; then
        echo "arm64"
    elif grep -q '^CONFIG_RISCV=y' .config; then
        echo "riscv"
    else
        echo "ERROR: cannot detect arch from .config." >&2
        exit 1
    fi
}

case "$CMD" in
    build)
        ARCH="${ARCH:-$HOST_ARCH}"
        CROSS_COMPILE="${CROSS_COMPILE:-}"

        if [ "$ARCH" != "$HOST_ARCH" ] && [ -z "$CROSS_COMPILE" ]; then
            case "$ARCH" in
                arm64)  CROSS_COMPILE="aarch64-linux-gnu-" ;;
                riscv)  CROSS_COMPILE="riscv64-linux-gnu-" ;;
                x86)    CROSS_COMPILE="x86_64-linux-gnu-" ;;
            esac
            echo "Auto-set CROSS_COMPILE=$CROSS_COMPILE"
        fi

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
            VIRTIO
            VIRTIO_PCI
            VIRTIO_MMIO
            VIRTIO_BLK
            VIRTIO_NET
            VIRTIO_CONSOLE
            FUSE_FS
            CUSE
            VIRTIO_FS
            9P_FS
            9P_FS_POSIX_ACL
            EXT4_FS
            DEBUG_INFO
            GDB_SCRIPTS
            READABLE_ASM
            FUNCTION_TRACER
        )

        DISABLE_CONFIGS=(
            DEBUG_INFO_REDUCED
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

        for cfg in "${DISABLE_CONFIGS[@]}"; do
            scripts/config --disable "$cfg"
        done

        make "${MAKE_ARGS[@]}" olddefconfig

        # Disable all loadable modules (=m) to cut build time; builtin (=y) untouched
        sed -i 's/^\(CONFIG_[A-Za-z0-9_]*\)=m$/# \1 is not set/' .config
        make "${MAKE_ARGS[@]}" olddefconfig

        make "${MAKE_ARGS[@]}" -j"$(nproc)" "$IMAGE_TARGET" modules
        make "${MAKE_ARGS[@]}" scripts_gdb
        ;;
    clean)
        ARCH="$(detect_arch)"
        echo "Detected arch from .config: $ARCH"
        make ARCH="$ARCH" clean
        ;;
    mrproper)
        ARCH="$(detect_arch)"
        echo "Detected arch from .config: $ARCH"
        make ARCH="$ARCH" mrproper
        ;;
    *)
        show_help
        ;;
esac
