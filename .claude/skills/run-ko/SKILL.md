---
name: run-ko
description: Build, load, run, and debug a Linux kernel module (.ko) inside the QEMU guest VM. Use whenever the user wants to test/insmod/rmmod a kernel module, observe its dmesg output, debug a module crash/panic, or iterate on module code against a running kernel. Drives run-qemu.sh in background mode with SSH and reads serial.log for kernel logs.
---

# Run & Debug Kernel Modules (.ko)

Workflow for testing a kernel module against the QEMU guest. The host project root
(`linux-cc/`) is shared into the guest at `/mnt` over 9pfs, so a module built at
`user/modules/<name>/<name>.ko` is visible in the guest at
`/mnt/user/modules/<name>/<name>.ko` — no copying needed.

## Key facts

- **Run all `run-qemu.sh` / `build.sh` commands from `linux/`.**
- **SSH into guest:** `ssh -p 2222 -o StrictHostKeyChecking=no root@localhost '<cmd>'`
- **Module path in guest:** `/mnt/user/modules/<name>/<name>.ko`
- **Kernel log on host:** `linux/serial.log` (full boot + runtime serial console).
  `dmesg` over SSH also works once the guest is up.
- The same kernel arch must be built for both the module and the VM. Check with
  `file linux/vmlinux`. Cross-compiled modules use `include ../common.mk`.

## Workflow

### 1. Build the module

```bash
cd user/modules/<name>/
make            # produces <name>.ko; common.mk auto-detects arch from vmlinux
```

### 2. Start the VM in the background, wait for SSH

```bash
cd linux/
./run-qemu.sh --bg --wait-ssh
```

This boots QEMU detached, logs the serial console to `linux/serial.log`, and blocks
until SSH is reachable (or prints an SSH-timeout error). If it times out, inspect
`linux/serial.log` and `linux/qemu-boot.log` before retrying.

### 3. Load and exercise the module over SSH

```bash
SSH='ssh -p 2222 -o StrictHostKeyChecking=no root@localhost'
$SSH 'insmod /mnt/user/modules/<name>/<name>.ko'   # add params: <name>.ko foo=1
$SSH 'lsmod | grep <name>'
$SSH 'modinfo /mnt/user/modules/<name>/<name>.ko'
$SSH 'dmesg | tail -30'                              # module's printk output
$SSH 'rmmod <name>'
```

### 4. Read kernel logs

Prefer reading `linux/serial.log` on the host (survives guest hangs/panics that
SSH won't). For live module output, `$SSH 'dmesg'` is fine while the guest is healthy.

### 5. Detecting and recovering from a panic / hang

If a load or test triggers a kernel `panic`, `BUG`, `Oops`, or the guest stops
responding to SSH:

1. **Confirm via the log** — grep `linux/serial.log` for `panic`, `BUG:`, `Oops`,
   `Call Trace`, `Unable to handle`. The serial log captures the trace even when
   SSH is dead.
2. **Reset the VM:**
   ```bash
   cd linux/
   ./run-qemu.sh --shutdown-bg     # graceful poweroff; falls back to SIGTERM
   ./run-qemu.sh --bg --wait-ssh   # fresh boot
   ```
3. Report the captured stack trace to the user, fix the module, rebuild (step 1),
   and reload.

### 6. Iterating on code

After editing the module source: rebuild (step 1), then in the *running* guest
`$SSH 'rmmod <name>'` and `$SSH 'insmod .../<name>.ko'`. A full VM restart is only
needed if the module wedged the kernel (see step 5) or you rebuilt the kernel itself.

### 7. Shut down when done

```bash
cd linux/
./run-qemu.sh --shutdown-bg
```

## GDB (optional, source-level debugging)

QEMU always exposes a GDB stub on `:1234`. To set breakpoints inside the module:

- **Quick attach:** `cd linux/ && ./run-gdb.sh` launches `gdb-multiarch`, sources
  `vmlinux-gdb.py`, and breaks at `start_kernel`. Once attached, run `lx-symbols`
  (loads symbols for all loaded modules), then `break <module_function>`. Re-run
  `lx-symbols` after each `insmod`.
- **Driven via MCP / full source-level flow:** use the **debug-linux** skill, which
  drives `gdb-multiarch` through the `mdb-gdb` MCP server (`mcp__mdb-gdb__*` tools)
  for breakpoints, stepping, and inspecting structures.

Useful for stepping through a faulting function found in a panic trace.
