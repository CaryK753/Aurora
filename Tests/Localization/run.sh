#!/usr/bin/env bash
# 翻译表重复键检查。
# Swift 的字典字面量遇到重复键会在**运行时**直接 abort，而这张表是懒加载的：
# 只有界面切到英文时才会炸，编译和默认语言下都看不出来。所以在测试里先扫一遍。

set -euo pipefail
cd "$(dirname "$0")/../.."

python3 - <<'PY'
import re, sys, glob

pattern = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*:')
files = sorted(glob.glob("Sources/Aurora/*Translations.swift") + ["Sources/Aurora/Localization.swift"])
bad = 0
total = 0
for path in files:
    seen = {}
    for number, line in enumerate(open(path, encoding="utf-8"), 1):
        match = pattern.match(line)
        if not match:
            continue
        key = match.group(1)
        total += 1
        if key in seen:
            print(f"{path}:{number}: 重复键 {key!r}（首次出现在第 {seen[key]} 行）")
            bad += 1
        else:
            seen[key] = number

print(f"检查 {len(files)} 个文件、{total} 条文案，重复 {bad} 处")
sys.exit(1 if bad else 0)
PY
