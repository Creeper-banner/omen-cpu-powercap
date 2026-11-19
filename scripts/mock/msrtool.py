#!/usr/bin/env python3
"""mock rdmsr/wrmsr：忠实模拟 msr-tools 的行为（包括 strtoull(base 0) 的八进制坑）。
状态存在 $MOCK_STATE/<reg> 里。用法见 selftest.sh。"""
import os, sys

state = os.environ["MOCK_STATE"]
os.makedirs(state, exist_ok=True)

def parse(argv):
    cpu = None; fld = None; rest = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "-p": cpu = argv[i+1]; i += 2; continue
        if a == "-f": fld = argv[i+1]; i += 2; continue
        if a in ("-a", "-c"): i += 2; continue
        rest.append(a); i += 1
    return cpu, fld, rest

def path(reg):
    reg = str(reg).lower().replace("0x", "")
    return os.path.join(state, reg)

def read(reg):
    p = path(reg)
    return int(open(p).read().strip(), 16) if os.path.exists(p) else 0

def write(reg, v):
    open(path(reg), "w").write("%016x\n" % (v & 0xFFFFFFFFFFFFFFFF))

def log(line):
    with open(os.path.join(state, "log"), "a") as f:
        f.write(line + "\n")

argv = sys.argv[2:]
tool = sys.argv[1]                    # 由包装脚本显式传入 rdmsr / wrmsr
cpu, fld, rest = parse(argv)

if tool == "rdmsr":
    reg = rest[0]
    v = read(reg)
    if fld:
        lo, hi = (int(x) for x in fld.split(":"))
        v = (v >> lo) & ((1 << (hi - lo + 1)) - 1)
    print("%x" % v)
    sys.exit(0)

# wrmsr：reg, value[, value...]
reg, vals = rest[0], rest[1:]
for i, s in enumerate(vals):
    log("wrmsr %s %s" % (reg, s))
    try:
        v = int(s, 0)                       # ← base 0：0 开头按八进制解析，正是踩的坑
    except ValueError:
        sys.exit("wrmsr: invalid value %r" % s)
    write(reg if len(vals) == 1 else "%s%02d" % (reg.replace("0x",""), i), v)
    # 每次写入后做合法性检查：任何裸 16 位十六进制（前导 0 且无 0x）都算回归
    if s[0] == "0" and not s.lower().startswith("0x") and len(s) == 16:
        sys.stderr.write("SELFTEST-FAIL: wrmsr 收到无前缀值 %r → 会被当八进制解析\n" % s)
        sys.exit(42)
