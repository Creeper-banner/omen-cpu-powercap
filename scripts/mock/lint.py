#!/usr/bin/env python3
"""lint：检查未闭合的 ${VAR:+...}。
为什么需要它：${TAU:+ TAU=${TAU}s"  少一个 } → 展开吞掉后面的引号 →
bash 报「寻找匹配的引号时遇到 EOF」，而 `bash -n a.sh b.sh` 只检查第一个文件（假绿）。
用法: python3 lint.py 目录   （发现问题→打印并 exit 1）"""
import re, sys, glob, os

d = sys.argv[1] if len(sys.argv) > 1 else "."
bad = 0
for f in sorted(glob.glob(os.path.join(d, "*.sh"))):
    for i, line in enumerate(open(f, encoding="utf-8"), 1):
        if line.lstrip().startswith("#"):
            continue
        for m in re.finditer(r"\$\{[A-Za-z_][A-Za-z0-9_]*:[+?=-]", line):
            k, depth = m.start() + 1, 0   # 从 \${ 后面的 { 开始数
            while k < len(line):
                if line[k] == "{":
                    depth += 1
                elif line[k] == "}":
                    depth -= 1
                    if depth == 0:
                        break
                k += 1
            if depth != 0:
                print(f"{f}:{i}: 未闭合的 ${{VAR:+...}} → {line.strip()[:90]}")
                bad += 1
sys.exit(1 if bad else 0)
