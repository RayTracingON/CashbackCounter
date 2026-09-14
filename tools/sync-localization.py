#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把代码里的 String.loc("…") 词条同步进 Localizable.xcstrings。

为什么需要它：Xcode 只会自动提取 `Text("字面量")` 和 `String(localized: "字面量")`。
本项目用 `String.loc(…)` 取词（原因见 AppLanguage.swift），字面量藏在函数参数里，
提取器看不见——新写的文案不会自动进字符串目录，运行时就会静默回落到中文原文。
每次新增 String.loc 文案后跑一次。

用法：
    python3 tools/sync-localization.py           # 只检查，列出缺失项
    python3 tools/sync-localization.py --add     # 把能安全推断的补进目录
"""
import argparse, itertools, json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Localizable.xcstrings"
SOURCE_DIR = ROOT / "CashbackCounter"

ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "0": "\0", "'": "'"}
# 插值里可能出现的类型 -> 格式化后的占位符。脚本无法做类型推断，
# 所以把各种组合都试一遍，只要有一种能在目录里命中就算已覆盖。
SPECIFIERS = ("%@", "%lld", "%f")


def parse_swift_literal(src: str, start: int):
    """从 src[start]（开引号的下一个字符）读一个 Swift 字符串字面量。

    返回 (段列表, 结束下标)。段是 str（文本）或 None（一处插值）。
    自己扫而不用正则：插值里可以有嵌套括号和引号，正则处理不了。
    """
    parts, buf, i = [], [], start
    while i < len(src):
        ch = src[i]
        if ch == "\\":
            nxt = src[i + 1] if i + 1 < len(src) else ""
            if nxt == "(":                       # 插值：跳到配对的右括号
                depth, i = 1, i + 2
                while i < len(src) and depth:
                    if src[i] == "(":
                        depth += 1
                    elif src[i] == ")":
                        depth -= 1
                    elif src[i] == '"':          # 插值里的字符串，整段跳过
                        i += 1
                        while i < len(src) and src[i] != '"':
                            i += 2 if src[i] == "\\" else 1
                    i += 1
                parts.append("".join(buf)); buf = []
                parts.append(None)
                continue
            buf.append(ESCAPES.get(nxt, nxt)); i += 2; continue
        if ch == '"':
            parts.append("".join(buf))
            return parts, i
        buf.append(ch); i += 1
    return None, i                                # 没闭合，多半是跨行写法，跳过


def scan():
    """返回 {(段元组): [出现位置]}。"""
    found = {}
    marker = "String.loc("
    for path in sorted(SOURCE_DIR.rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        for m in re.finditer(re.escape(marker), text):
            j = m.end()
            while j < len(text) and text[j] in " \t\n":
                j += 1
            if j >= len(text) or text[j] != '"':
                continue                          # 变量传参，不是字面量
            parts, _ = parse_swift_literal(text, j + 1)
            if parts is None:
                continue
            lineno = text.count("\n", 0, m.start()) + 1
            found.setdefault(tuple(parts), []).append(f"{path.relative_to(ROOT)}:{lineno}")
    return found


def candidate_keys(parts):
    """一处字面量可能对应的所有目录 key。"""
    slots = [i for i, p in enumerate(parts) if p is None]
    if not slots:
        return ["".join(parts)]
    keys = []
    for combo in itertools.product(SPECIFIERS, repeat=len(slots)):
        filled = list(parts)
        for slot, spec in zip(slots, combo):
            filled[slot] = spec
        keys.append("".join(filled))
    return keys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--add", action="store_true", help="把无插值的缺失词条写入目录")
    args = ap.parse_args()

    doc = json.loads(CATALOG.read_text(encoding="utf-8"))
    known = set(doc["strings"])
    found = scan()

    missing_plain, missing_interp = {}, {}
    for parts, where in found.items():
        keys = candidate_keys(parts)
        if any(k in known for k in keys):
            continue
        (missing_interp if None in parts else missing_plain)[keys[0]] = where

    if missing_plain:
        print(f"缺失（无插值，--add 可自动补）{len(missing_plain)} 条：")
        for k, where in sorted(missing_plain.items()):
            print(f"  {k!r}\n      {where[0]}")
    if missing_interp:
        print(f"\n缺失（含插值，占位符需人工核对）{len(missing_interp)} 条：")
        for k, where in sorted(missing_interp.items()):
            print(f"  {k!r}\n      {where[0]}")
    if not missing_plain and not missing_interp:
        print(f"✅ 目录已覆盖代码里全部 {len(found)} 处 String.loc 字面量")
        return 0

    if args.add and missing_plain:
        for k in missing_plain:
            doc["strings"][k] = {"extractionState": "manual", "localizations": {}}
        # 目录原本就不是按 key 排序的，别重排，否则一次 --add 会生成整份文件的 diff
        # 冒号前后各一个空格 —— 对齐 Xcode 自己的写法，否则一次写入就把整份文件重排了
        CATALOG.write_text(
            json.dumps(doc, ensure_ascii=False, indent=2, separators=(",", " : ")) + "\n",
            encoding="utf-8")
        print(f"\n已写入 {len(missing_plain)} 条，去 Xcode 里补翻译。")
        return 0

    if not args.add:
        print("\n加 --add 可自动补齐无插值的部分。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
