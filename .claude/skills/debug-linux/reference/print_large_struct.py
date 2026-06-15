# GDB Python script: bulk-read a struct from remote target, parse fields locally,
# write to a file.  Use when `print *(struct foo *)` times out over :1234.
#
# Usage (inside GDB, after sourcing lx-* and hitting a breakpoint):
#   python gdb.execute("source /path/to/print-struct.py")
# Or inline adapt the ADDR / TYPE_NAME and paste between `python` / `end`.

import gdb

# --- CONFIG ----------------------------------------------------------------
STRUCT_TYPE = "struct task_struct"        # e.g. struct mm_struct, struct files_struct
ADDR_EXPR   = "$lx_current()"            # e.g. $lx_current().mm, 0xffff888001234000
OUTFILE     = "/tmp/struct_dump.txt"
# ---------------------------------------------------------------------------

t = gdb.parse_and_eval(ADDR_EXPR)
tsk_type = gdb.lookup_type(STRUCT_TYPE)
size = tsk_type.sizeof
addr = int(t)

inferior = gdb.selected_inferior()
raw = inferior.read_memory(addr, size)

TC_PTR     = gdb.TYPE_CODE_PTR
TC_ARRAY   = gdb.TYPE_CODE_ARRAY
TC_STRUCT  = gdb.TYPE_CODE_STRUCT
TC_UNION   = gdb.TYPE_CODE_UNION
TC_ENUM    = gdb.TYPE_CODE_ENUM
TC_INT     = gdb.TYPE_CODE_INT
TC_FLAGS   = gdb.TYPE_CODE_FLAGS
TC_TYPEDEF = gdb.TYPE_CODE_TYPEDEF
TC_BOOL    = gdb.TYPE_CODE_BOOL

def resolve(ftype):
    while ftype.code == TC_TYPEDEF:
        ftype = ftype.target()
    return ftype

def extract(b, fsize, ftype):
    ftype = resolve(ftype)
    code = ftype.code
    if code == TC_INT:
        name = str(ftype)
        if 'char' in name:
            return repr(b[0]) if fsize == 1 else repr(bytes(b).split(b"\0")[0])
        return int.from_bytes(b, 'little', signed=True)
    elif code == TC_PTR:
        return f"0x{int.from_bytes(b, 'little'):016x}"
    elif code == TC_BOOL:
        return 'true' if b[0] else 'false'
    elif code == TC_ENUM or code == TC_FLAGS:
        return int.from_bytes(b, 'little')
    elif code == TC_ARRAY:
        et = resolve(ftype.target())
        if et.code == TC_INT and str(et) == 'char':
            return "\"" + bytes(b).split(b"\0")[0].decode("ascii", errors="replace") + "\""
        return f"<array[{ftype.range()[1]+1}]>"
    elif code in (TC_STRUCT, TC_UNION):
        return f"<{ftype.name}, {fsize}B>"
    else:
        return f"<code={code}, {fsize}B>"

with open(OUTFILE, "w") as f:
    for field in tsk_type.fields():
        off = field.bitpos // 8
        fsize = field.type.sizeof
        chunk = raw[off:off+fsize]
        val = extract(chunk, fsize, field.type)
        f.write(f"[+0x{off:04x}] {field.name}: {val}\n")

gdb.write(f"Written {tsk_type.name} ({size}B, {len(list(tsk_type.fields()))} fields) -> {OUTFILE}\n")
