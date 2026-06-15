---
name: debug-linux
description: Source-level debug the Linux kernel running in QEMU using GDB driven through the mdb-gdb MCP server. Use whenever the user wants to set kernel breakpoints, step through kernel code, inspect kernel data structures/registers/stacks, debug a panic/Oops/hang at the source level, or examine a live running kernel. Builds the kernel (which emits GDB scripts), boots QEMU with its :1234 GDB stub, drives gdb-multiarch via MCP, and uses SSH to trigger code paths in the guest.
---

# Debug the Linux Kernel with GDB (via mdb-gdb MCP)

Workflow for live source-level kernel debugging. QEMU always exposes a GDB stub on
`:1234` (the `-s` flag in `run-qemu.sh`), and the kernel is built with debug info +
GDB helper scripts. Debugging is driven through the `mdb-gdb` MCP server, which runs
`gdb-multiarch` and connects it to the QEMU stub.

The host project root (`linux-cc/`) is shared into the guest at `/mnt` over 9pfs, so
test programs/modules under `user/` are reachable in the guest and can be used over
SSH to trigger the kernel paths you want to break on.

## Key facts

- **Run all `build.sh` / `run-qemu.sh` commands from `linux/`.**
- **GDB stub:** always on host `localhost:1234` while QEMU is running.
- **SSH into guest:** `ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost '<cmd>'`
- **`nokaslr`** is set in the kernel cmdline, so symbol addresses are stable.
- **Always pass absolute paths to GDB** (`file`, `source`). The MCP server's CWD is
  its own install dir, not `linux/`. The kernel lives at
  `/home/cyrus/Workspace/codebase/linux-cc/linux/`.
- **Match the GDB arch to vmlinux.** Run `file linux/vmlinux` and map:
  | vmlinux says | gdb `set architecture` |
  |--------------|------------------------|
  | `x86-64`     | `i386:x86-64`          |
  | `aarch64`    | `aarch64`              |
  | `RISC-V`     | `riscv:rv64`           |
- **GDB scripts:** `build.sh` runs `make scripts_gdb`, producing
  `linux/vmlinux-gdb.py`. Sourcing it adds the `lx-*` commands (`lx-symbols`,
  `lx-dmesg`, `lx-ps`, `lx-lsmod`, `lx-mounts`, …) for kernel-aware inspection.

## Workflow

### 1. Ensure the kernel is built (with debug info + GDB scripts)

```bash
cd linux/
./build.sh build        # set ARCH=arm64 / ARCH=riscv to cross-build
```

`build.sh` enables `DEBUG_INFO` and `GDB_SCRIPTS` and runs `make scripts_gdb`, so
after a successful build `linux/vmlinux` (symbols) and `linux/vmlinux-gdb.py`
(`lx-*` helpers) both exist. Skip this step if a usable build is already present.

### 2. Ensure the mdb-gdb MCP server is installed

Check whether the GDB MCP tools are available (the `mcp__mdb-gdb__*` tools, e.g.
`mcp__mdb-gdb__gdb_start`). If they are present, skip ahead.

If they are **not** available, install and register the server, then ask the user to
restart Claude Code so the tools load:

```bash
cd /home/cyrus/Workspace/codebase/linux-cc
./.claude/skills/debug-linux/setup_gdb_mcp.sh
```

This installs `uv`, ensures `gdb` / `gdb-multiarch` (sudo apt-get if missing),
clones MDB-MCP, and registers the `mdb-gdb` MCP server with both Claude Code
and OpenCode by default. Registration defaults to **project-level** scope
(`--scope project`); use `--scope user` for global installation. Use
`--target claude` or `--target opencode` to register with a single tool:

```bash
./.claude/skills/debug-linux/setup_gdb_mcp.sh --target opencode             # project-level
./.claude/skills/debug-linux/setup_gdb_mcp.sh --target opencode --scope user # global
``` The `mcp__mdb-gdb__*` tools only appear **after** a restart —
stop here and tell the user to restart if you had to install it.

### 3. Boot QEMU in the background, wait for SSH

```bash
cd linux/
./run-qemu.sh --bg --wait-ssh
```

Boots QEMU detached, logs the serial console to `linux/serial.log`, and blocks until
SSH is up. The GDB stub on `:1234` is live as soon as QEMU starts. On SSH timeout,
inspect `linux/serial.log` and `linux/qemu-boot.log`.

To debug **early boot** (before SSH or even `start_kernel`), add `--wait-gdb` so QEMU
freezes the CPUs at startup (`-S`) and only runs once GDB connects and continues:

```bash
./run-qemu.sh --bg --wait-gdb
```

`--wait-ssh` won't return here (the kernel hasn't booted), so omit it and attach GDB
first; the kernel starts executing the moment you issue `continue`.

### 4. Start a GDB session and attach to the stub

Use the MCP tools (arch shown for the common aarch64 build — adjust per the table
above). Keep the returned `session_id` for every later command.

- `mcp__mdb-gdb__gdb_start(gdb_path="gdb-multiarch")` → returns `session_id`
- `mcp__mdb-gdb__gdb_command(session_id, "file /home/cyrus/Workspace/codebase/linux-cc/linux/vmlinux")`
- `mcp__mdb-gdb__gdb_command(session_id, "set architecture aarch64")`
- `mcp__mdb-gdb__gdb_command(session_id, "target remote :1234")`

This halts the running kernel. You are now stopped in the guest CPU.

### 5. Load the kernel GDB scripts (lx-* helpers)

```
source /home/cyrus/Workspace/codebase/linux-cc/linux/vmlinux-gdb.py
```

Run via `mcp__mdb-gdb__gdb_command`. Then kernel-aware commands work, e.g.
`lx-dmesg` (kernel log), `lx-ps` (task list), `lx-lsmod` (loaded modules),
`lx-symbols` (load module symbols for module debugging).

### 6. Set breakpoints and run

Drive everything through `mcp__mdb-gdb__gdb_command(session_id, "<gdb cmd>")`:

```
break do_sys_open          # or any function / file:line
break panic                # catch crashes at the source
continue                   # let the guest run until the breakpoint
bt                         # backtrace when stopped
info registers
print <expr>  /  p *task   # inspect data structures
next / step / finish
```

To make a breakpoint fire, **trigger the path from the guest over SSH** (the guest
runs only while GDB has issued `continue`):

```bash
SSH='ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost'
$SSH 'cat /some/file'      # e.g. triggers a break on do_sys_open
```

### 7. Debugging a kernel module

Build/insmod the module (see the `run-ko` skill), then in GDB:

```
lx-symbols                 # auto-loads symbols for all loaded modules
break <module_function>
```

`lx-symbols` resolves module load addresses from the live kernel, so breakpoints in
`.ko` code resolve correctly. Re-run it after each insmod.

### 8. Debugging a panic / hang

1. If the guest is wedged, the GDB stub is still alive — attach (step 4) and run
   `bt`, `lx-dmesg`, `info registers` to capture the faulting state.
2. Cross-check `linux/serial.log` for the `panic` / `BUG:` / `Oops` / `Call Trace`
   text; the serial log survives even when SSH is dead.
3. Set `break panic` (or `break die`) **before** triggering, then `continue`, to stop
   exactly at the fault and inspect the stack.

### 9. Tear down

```
# in GDB: detach lets the guest run on; then end the session
detach
```

- `mcp__mdb-gdb__gdb_terminate(session_id)` — end the GDB session.
- Then shut the VM down:

```bash
cd linux/
./run-qemu.sh --shutdown-bg
```

## Tips

- Use `mcp__mdb-gdb__gdb_list_sessions` if you lose track of `session_id`.
- GDB must `continue` for the guest to make progress; an idle SSH command will hang
  until you continue execution.
- A `hbreak` (hardware breakpoint) helps for early-boot code or read-only text.
- Editing kernel source means a rebuild (step 1) and a fresh boot (step 3) — module
  edits only need a rebuild + `rmmod`/`insmod` + `lx-symbols`.
