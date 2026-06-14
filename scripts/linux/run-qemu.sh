#!/bin/bash
set -e

# Paths
VMLINUX="vmlinux"
ROOT_DIR=".."
ROOTFS_DIR="../rootfs"

# Help
HELP="Usage: ./run-qemu.sh [OPTIONS]

Options:
  --bg              Run QEMU in background
  --wait-ssh        Wait for SSH ready after --bg start
  --wait-gdb        Freeze CPU at startup, wait for GDB to connect and continue
  --shutdown-bg     Shut down background running QEMU
  --serial=MODE     Serial backend: stdio(default) or pty(--bg default)
  --logfile=PATH    Serial log file (default: serial.log)
  --help            Show this help"

# VM SSH
SSH_HOST="root@localhost"
SSH_PORT=2222
SSH_ARGS=(-o StrictHostKeyChecking=no -o ConnectTimeout=3)

# Options
SERIAL_LOG="serial.log"
SERIAL_MODE=""
RUN_BG=0
SHUTDOWN_BG=0
WAIT_SSH=0
WAIT_GDB=0
PID_FILE="qemu.pid"

for arg in "$@"; do
    case "$arg" in
        --logfile=*)    SERIAL_LOG="${arg#--logfile=}" ;;
        --serial=*)     SERIAL_MODE="${arg#--serial=}" ;;
        --bg)           RUN_BG=1 ;;
        --shutdown-bg)  SHUTDOWN_BG=1 ;;
        --wait-ssh)     WAIT_SSH=1 ;;
        --wait-gdb)     WAIT_GDB=1 ;;
        --help)         echo "$HELP"; exit 0 ;;
    esac
done

# Select serial
if [ -z "$SERIAL_MODE" ]; then
    if [ "$RUN_BG" = "1" ]; then
        SERIAL_MODE="pty"
    else
        SERIAL_MODE="stdio"
    fi
fi

# Functions
wait_ssh_ready() {
    local i=0
    while [ $i -lt 10 ]; do
        ssh -p "$SSH_PORT" "${SSH_ARGS[@]}" "$SSH_HOST" true 2>/dev/null && return 0
        sleep 1; i=$((i+1))
    done
    return 1
}

wait_qemu_exit() {
    local pid=$1 i=0
    while kill -0 "$pid" 2>/dev/null && [ $i -lt 30 ]; do
        sleep 1; i=$((i+1))
    done
    ! kill -0 "$pid" 2>/dev/null
}

qemu_shutdown_bg() {
    if [ ! -f "$PID_FILE" ]; then
        echo "No $PID_FILE found."
        return 1
    fi
    local pid name curr_name
    pid=$(sed -n '1p' "$PID_FILE")
    name=$(sed -n '2p' "$PID_FILE")
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "QEMU is not running."
        rm -f "$PID_FILE"
        return 1
    fi
    curr_name=$(ps -p "$pid" -o comm= 2>/dev/null || true)
    if [ "$curr_name" != "${name:0:${#curr_name}}" ]; then
        echo "PID $pid name not match: '$curr_name' != '$name', ignored."
        rm -f "$PID_FILE"
        return 1
    fi

    echo "QEMU process matched: $name, PID $pid"

    echo "Shutting down QEMU..."

    while :; do
        echo "Waiting for SSH ready..."
        wait_ssh_ready || { echo "ERROR: SSH not ready."; break; }
        echo "Send poweroff..."
        ssh -p "$SSH_PORT" "${SSH_ARGS[@]}" "$SSH_HOST" poweroff 2>/dev/null || { echo "ERROR: Send poweroff failed."; break; }
        echo "Wait QEMU terminate..."
        wait_qemu_exit "$pid" || { echo "ERROR: Wait terminate timeout."; break; }
        rm -f "$PID_FILE"
        echo "QEMU exited."
        return 0
    done

    echo "Sending SIGTERM..."
    kill -TERM "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "QEMU terminated."
}

# Routine start
if [ "$SHUTDOWN_BG" = "1" ]; then
    qemu_shutdown_bg
    exit $?
fi

case "$SERIAL_MODE" in
    stdio)
        SERIAL_ARGS=(
            -chardev stdio,id=char0,logfile="$SERIAL_LOG",mux=on
            -serial chardev:char0
            -mon chardev=char0
        )
        ;;
    pty)
        SERIAL_ARGS=(
            -chardev pty,id=char0,logfile="$SERIAL_LOG"
            -serial chardev:char0
        )
        ;;
    *) echo "ERROR: Invalid --serial parameter: must be stdio or pty"; exit 1 ;;
esac

if [ ! -f "$VMLINUX" ]; then
    echo "ERROR: $VMLINUX not found. Try build kernel first."
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
        echo "ERROR: Unsupported vmlinux arch:"
        echo "$VMLINUX_INFO"
        exit 1
        ;;
esac

if [ ! -f "$KERNEL_IMAGE" ]; then
    echo "ERROR: Kernel image not found: $KERNEL_IMAGE"
    exit 1
fi

if [ ! -f "$ROOTFS_IMAGE" ]; then
    echo "ERROR: Rootfs image not found: $ROOTFS_IMAGE"
    exit 1
fi

echo "VMLINUX: $VMLINUX_INFO"
echo "ARCH: $ARCH"
echo "QEMU: $QEMU"
echo "KERNEL_IMAGE: $KERNEL_IMAGE"
echo "ROOTFS_IMAGE: $ROOTFS_IMAGE"

QEMU_CMD=(
    "$QEMU"
    -m 2048
    -smp 2
    -machine "$MACHINE"
    "${EXTRA_QEMU_ARGS[@]}"
    -kernel "$KERNEL_IMAGE"
    -drive file="$ROOTFS_IMAGE",if=virtio,format=qcow2
    -virtfs local,path="$ROOT_DIR",mount_tag=hostshare,security_model=mapped-xattr,id=hostshare
    -netdev user,id=net0,hostfwd=tcp::2222-:22
    -device virtio-net-pci,netdev=net0
    -append "root=$ROOT_DEV rw console=$CONSOLE $EXTRA_APPEND systemd.show_status=false"
    "${SERIAL_ARGS[@]}"
    -nographic
    -s
)

if [ "$WAIT_GDB" = "1" ]; then
    QEMU_CMD+=(-S)
fi

if [ "$RUN_BG" = "1" ]; then
    if [ -f "$PID_FILE" ]; then
        qemu_shutdown_bg 2>/dev/null || true
    fi
    BOOT_LOG="qemu-boot.log"
    "${QEMU_CMD[@]}" </dev/null >"$BOOT_LOG" 2>&1 &
    QEMU_PID=$!
    printf '%s\n%s\n' "$QEMU_PID" "$QEMU" > "$PID_FILE"
    echo "QEMU started. (PID: $QEMU_PID)"
    if [ "$SERIAL_MODE" = "pty" ]; then
        sleep 1
        PTY_LINE=$(grep -m1 "char device redirected to" "$BOOT_LOG" 2>/dev/null)
        if [ -n "$PTY_LINE" ]; then
            echo "Serial: $PTY_LINE"
        else
            echo "WARNING: serial pty not found in $BOOT_LOG."
        fi
    fi
    if [ "$WAIT_SSH" = "1" ]; then
        echo "Wait for SSH ready..."
        if wait_ssh_ready; then
            echo "SSH is ready: ssh -p $SSH_PORT $SSH_HOST"
        else
            echo "ERROR: SSH timeout."
        fi
    fi
else
    "${QEMU_CMD[@]}"
fi
