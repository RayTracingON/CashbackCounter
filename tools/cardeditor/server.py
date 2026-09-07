#!/usr/bin/env python3
"""CardTemplates.json 可视化编辑器。

用法:
    python3 tools/cardeditor/server.py            # 起服务，浏览器里改
    python3 tools/cardeditor/server.py --check    # 只校验，可挂 pre-push

写回时严格保持 Apple JSONSerialization(.prettyPrinted) 的排版和每个条目
原有的 key 顺序，这样 git diff 里只会出现真正改动的行。
"""
from __future__ import annotations

import argparse
import json
import sys
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
JSON_PATH = REPO / "CashbackCounter" / "CardTemplates.json"

# --- 与 Swift 侧枚举保持一致 -------------------------------------------------
# Category.swift / Region.swift / PaymentMethod.swift / CreditCard.swift
CATEGORIES = ["dining", "grocery", "travel", "digital", "anime", "streaming", "other"]
REGIONS = ["中国大陆", "香港", "美国", "日本", "新西兰", "台湾", "澳门", "英国", "欧盟"]
PAYMENTS = ["applePay", "qrCode", "offline", "online", "pulse", "gba"]
REWARD_TYPES = ["cashback", "points"]
CAP_PERIODS = ["yearly", "monthly"]
DUAL_MODES = ["secondaryAsLocal", "secondaryAsForeign"]

# 新条目用的 key 顺序（取自文件里最常见的那种）
CANONICAL_KEYS = [
    "capPeriod", "specialRate", "pictureURL", "type", "foreignBaseCap",
    "localBaseCap", "categoryCaps", "rewardType", "pointProgramKey", "region",
    "paymentCaps", "colors", "foreignCurrencyRate", "paymentMethodRates",
    "bankName", "defaultRate", "memo", "secondaryRegion", "dualCurrencyMode",
    "secondaryRate",
]

# 交替数组字段：Swift 的 Dictionary<非String键, V> 会编码成 [k, v, k, v]
PAIR_FIELDS = {
    "specialRate": CATEGORIES,
    "categoryCaps": CATEGORIES,
    "paymentMethodRates": PAYMENTS,
    "paymentCaps": PAYMENTS,
}


# --- Apple JSONSerialization(.prettyPrinted) 兼容序列化 ----------------------
def apple_dumps(obj, indent: int = 0) -> str:
    pad = " " * indent
    inner_pad = " " * (indent + 2)

    if isinstance(obj, dict):
        if not obj:
            return "{\n\n" + pad + "}"
        items = [
            f'{inner_pad}{json.dumps(k, ensure_ascii=False)} : {apple_dumps(v, indent + 2)}'
            for k, v in obj.items()
        ]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"

    if isinstance(obj, list):
        if not obj:
            return "[\n\n" + pad + "]"
        items = [inner_pad + apple_dumps(v, indent + 2) for v in obj]
        return "[\n" + ",\n".join(items) + "\n" + pad + "]"

    if isinstance(obj, bool):
        return "true" if obj else "false"
    if obj is None:
        return "null"
    if isinstance(obj, float):
        # 整数值的 Double 要写成 100 而不是 100.0，跟 Swift 输出一致
        return str(int(obj)) if obj.is_integer() else repr(obj)
    if isinstance(obj, int):
        return str(obj)
    if isinstance(obj, str):
        return json.dumps(obj, ensure_ascii=False)
    raise TypeError(f"无法序列化 {type(obj)}")


def load_templates():
    data = json.loads(JSON_PATH.read_text(encoding="utf-8"))
    key_order = {}
    for entry in data:
        key_order[(entry.get("bankName"), entry.get("type"))] = list(entry.keys())
    return data, key_order


def reorder(entry: dict, key_order: dict) -> dict:
    """按磁盘上原有的 key 顺序重建条目，新条目用 CANONICAL_KEYS。"""
    order = key_order.get((entry.get("bankName"), entry.get("type")))
    if order is None:
        order = CANONICAL_KEYS
    out = {k: entry[k] for k in order if k in entry}
    for k in entry:  # 原顺序里没有的新字段追加在后面
        if k not in out:
            out[k] = entry[k]
    return out


def dump_templates(data, key_order) -> str:
    ordered = [reorder(e, key_order) for e in data]
    return apple_dumps(ordered, 0) + "\n"


# --- 校验 -------------------------------------------------------------------
HEX = set("0123456789ABCDEF")


def _relative_luminance(hex6: str) -> float:
    def channel(v: float) -> float:
        v /= 255.0
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4

    r, g, b = (channel(int(hex6[i:i + 2], 16)) for i in (0, 2, 4))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast_with_white(hex6: str) -> float:
    return 1.05 / (_relative_luminance(hex6) + 0.05)


def midpoint(a: str, b: str) -> str:
    return "".join(
        f"{(int(a[i:i + 2], 16) + int(b[i:i + 2], 16)) // 2:02X}" for i in (0, 2, 4)
    )


def validate(data):
    """返回 (errors, warnings)。errors 会让 App 解码失败或数据明显错误。"""
    errors, warnings = [], []
    if not isinstance(data, list):
        return ["顶层必须是数组"], []

    seen = {}
    for i, e in enumerate(data):
        name = f"[{i}] {e.get('bankName', '?')} {e.get('type', '?')}"
        if not isinstance(e, dict):
            errors.append(f"{name}: 条目不是对象")
            continue

        for key in ("bankName", "type", "colors", "region", "specialRate", "defaultRate"):
            if key not in e:
                errors.append(f"{name}: 缺少必填字段 {key}")

        # templateKey 是 "bankName-type"，重复会让模板互相覆盖
        key = (e.get("bankName"), e.get("type"))
        if key in seen:
            errors.append(f"{name}: 与 [{seen[key]}] 的 bankName+type 重复，templateKey 会冲突")
        seen[key] = i

        if e.get("region") not in REGIONS:
            errors.append(f"{name}: region {e.get('region')!r} 不在 Region 枚举里")
        if e.get("rewardType", "cashback") not in REWARD_TYPES:
            errors.append(f"{name}: rewardType {e.get('rewardType')!r} 非法")

        cap = e.get("capPeriod", {"yearly": {}})
        if not isinstance(cap, dict) or len(cap) != 1 or next(iter(cap)) not in CAP_PERIODS:
            errors.append(f"{name}: capPeriod 必须是 {{\"yearly\": {{}}}} 或 {{\"monthly\": {{}}}}")

        # 交替数组：长度必须是偶数，奇数位是合法枚举名，偶数位是数字
        for field, allowed in PAIR_FIELDS.items():
            arr = e.get(field, [])
            if not isinstance(arr, list):
                errors.append(f"{name}: {field} 必须是数组")
                continue
            if len(arr) % 2 != 0:
                errors.append(f"{name}: {field} 长度必须是偶数（Swift 按 [键,值,键,值] 解码）")
                continue
            for k, v in zip(arr[::2], arr[1::2]):
                if k not in allowed:
                    errors.append(f"{name}: {field} 里的键 {k!r} 不在枚举里，合法值 {allowed}")
                if not isinstance(v, (int, float)) or isinstance(v, bool):
                    errors.append(f"{name}: {field} 里 {k} 的值 {v!r} 不是数字")

        colors = e.get("colors", [])
        if not isinstance(colors, list) or len(colors) != 2:
            errors.append(f"{name}: colors 必须正好 2 个颜色（渐变的两端）")
        else:
            for c in colors:
                if not isinstance(c, str) or len(c) != 6 or not set(c.upper()) <= HEX:
                    errors.append(f"{name}: 颜色 {c!r} 不是 6 位十六进制")
            if all(isinstance(c, str) and len(c) == 6 and set(c.upper()) <= HEX for c in colors):
                a, b = colors[0].upper(), colors[1].upper()
                mid_hex = midpoint(a, b)
                start_cr = contrast_with_white(a)
                mid_cr = contrast_with_white(mid_hex)
                # CreditCardView 把文字层写死成白色，卡号落在渐变中点
                if start_cr < 4.5:
                    warnings.append(f"{name}: 起点色 {a} 对白字对比度只有 {start_cr:.1f}，左上角图标会看不清")
                if mid_cr < 4.5:
                    warnings.append(f"{name}: 渐变中点 {mid_hex} 对白字对比度只有 {mid_cr:.1f}，卡号会看不清")

        if e.get("rewardType") == "points" and not e.get("pointProgramKey"):
            warnings.append(f"{name}: rewardType 是 points 但没有 pointProgramKey，积分不会入任何账户")

        if e.get("secondaryRegion") is not None:
            if e.get("secondaryRegion") not in REGIONS:
                errors.append(f"{name}: secondaryRegion 不在 Region 枚举里")
            mode = e.get("dualCurrencyMode")
            if mode is not None and mode not in DUAL_MODES:
                errors.append(f"{name}: dualCurrencyMode {mode!r} 非法")

    return errors, warnings


# --- HTTP -------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # 静音，只在出错时打印
        pass

    def _send(self, code, body: bytes, ctype="application/json; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            html = (HERE / "index.html").read_bytes()
            return self._send(200, html, "text/html; charset=utf-8")
        if self.path == "/api/templates":
            data, _ = load_templates()
            errors, warnings = validate(data)
            payload = {
                "templates": data,
                "path": str(JSON_PATH),
                "enums": {
                    "categories": CATEGORIES, "regions": REGIONS,
                    "payments": PAYMENTS, "rewardTypes": REWARD_TYPES,
                    "capPeriods": CAP_PERIODS, "dualModes": DUAL_MODES,
                },
                "errors": errors, "warnings": warnings,
            }
            return self._send(200, json.dumps(payload, ensure_ascii=False).encode())
        self._send(404, b'{"error":"not found"}')

    def do_POST(self):
        if self.path != "/api/templates":
            return self._send(404, b'{"error":"not found"}')
        length = int(self.headers.get("Content-Length", 0))
        try:
            incoming = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception as exc:
            return self._send(400, json.dumps({"error": f"请求不是合法 JSON: {exc}"}).encode())

        data = incoming.get("templates")
        errors, warnings = validate(data)
        if errors:
            return self._send(
                422,
                json.dumps({"error": "校验未通过，没有写盘", "errors": errors,
                            "warnings": warnings}, ensure_ascii=False).encode(),
            )

        _, key_order = load_templates()
        text = dump_templates(data, key_order)
        json.loads(text)  # 写盘前最后确认一次是合法 JSON
        JSON_PATH.write_text(text, encoding="utf-8")
        print(f"✅ 已写入 {JSON_PATH} （{len(data)} 张卡）")
        self._send(200, json.dumps({"ok": True, "warnings": warnings},
                                   ensure_ascii=False).encode())


def main():
    ap = argparse.ArgumentParser(description="CardTemplates.json 可视化编辑器")
    ap.add_argument("--check", action="store_true", help="只校验，不起服务；有 error 时退出码 1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()

    if not JSON_PATH.exists():
        print(f"❌ 找不到 {JSON_PATH}", file=sys.stderr)
        return 2

    if args.check:
        data, key_order = load_templates()
        errors, warnings = validate(data)
        for w in warnings:
            print(f"⚠️  {w}")
        for e in errors:
            print(f"❌ {e}", file=sys.stderr)
        # 顺便确认序列化是幂等的：写回去应该和磁盘上一模一样
        if dump_templates(data, key_order) != JSON_PATH.read_text(encoding="utf-8"):
            print("⚠️  当前文件的排版和编辑器输出不一致，保存后会产生格式差异")
        print(f"{'❌' if errors else '✅'} {len(data)} 张卡，{len(errors)} 个错误，{len(warnings)} 个警告")
        return 1 if errors else 0

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    url = f"http://127.0.0.1:{args.port}/"
    print(f"卡片模板编辑器: {url}")
    print(f"编辑目标: {JSON_PATH}")
    print("Ctrl+C 退出")
    if not args.no_browser:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已退出")
    return 0


if __name__ == "__main__":
    sys.exit(main())
