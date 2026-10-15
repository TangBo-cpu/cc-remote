#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 Noto Emoji 的 SVG 光栅化成 assets/noto/*.png。

用法（在 mobile/ 目录下）：
    python tool/rasterize_noto_emoji.py

依赖：pip install cairosvg pillow

图标清单以 lib/noto_icon.dart 的 NotoGlyph 为唯一真源。每个条目写成
    const('assetName', 'sourceName')
其中 sourceName 是上游 Noto Emoji 里的原名。要加图标：先在枚举里加一行，
再跑本脚本。
"""
import io
import json
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUTDIR = os.path.join(ROOT, "assets", "noto")
DART = os.path.join(ROOT, "lib", "noto_icon.dart")
CACHE = os.path.join(os.environ.get("TEMP") or "/tmp", "iconify-noto.json")
SOURCE = "https://cdn.jsdelivr.net/npm/@iconify-json/noto@latest/icons.json"
SIZE = 128

RECORD = re.compile(r"(\w+)\('([^']+)',\s*'([^']+)'\)")


def load_source():
    if not os.path.exists(CACHE) or os.path.getsize(CACHE) < 100000:
        print("下载 %s …" % SOURCE)
        with urllib.request.urlopen(SOURCE, timeout=300) as r:
            data = r.read()
        with open(CACHE, "wb") as f:
            f.write(data)
    with io.open(CACHE, encoding="utf-8") as f:
        return json.load(f)


def parse_enum(dart_text):
    """返回 [(常量名, assetName, sourceName), ...]。"""
    m = re.search(r"enum NotoGlyph \{(.*?)\n\s*;", dart_text, re.S)
    if not m:
        raise SystemExit("在 %s 里找不到 enum NotoGlyph" % DART)
    return RECORD.findall(m.group(1))


def main():
    try:
        import cairosvg
        from PIL import Image
    except ImportError as e:
        raise SystemExit("缺少依赖（pip install cairosvg pillow）：%s" % e)

    src = load_source()
    icons = src.get("icons", {})
    aliases = src.get("aliases") or {}

    with io.open(DART, encoding="utf-8") as f:
        enum = parse_enum(f.read())
    if not enum:
        raise SystemExit("NotoGlyph 里没解析到条目，检查枚举格式是否为 const('asset', 'source')")

    def body_of(name):
        if name in icons:
            return icons[name].get("body")
        al = aliases.get(name)
        if isinstance(al, dict) and al.get("parent") in icons:
            return icons[al["parent"]].get("body")
        return None

    os.makedirs(OUTDIR, exist_ok=True)
    ok, fail = 0, []
    for const, asset, source in enum:
        body = body_of(source)
        if not body:
            fail.append((const, asset, "上游没有 %s" % source))
            continue
        svg = (
            '<svg xmlns="http://www.w3.org/2000/svg" '
            'xmlns:xlink="http://www.w3.org/1999/xlink" '
            'width="%d" height="%d" viewBox="0 0 128 128">%s</svg>' % (SIZE, SIZE, body)
        )
        dst = os.path.join(OUTDIR, asset + ".png")
        try:
            cairosvg.svg2png(
                bytestring=svg.encode("utf-8"), write_to=dst,
                output_width=SIZE, output_height=SIZE,
            )
            im = Image.open(dst).convert("RGBA")
            opaque = [p for p in im.getdata() if p[3] > 8]
            if im.size != (SIZE, SIZE) or not opaque or len(set(opaque)) < 3:
                fail.append((const, asset, "渲染结果像是空白"))
                continue
            ok += 1
        except Exception as e:                                  # noqa: BLE001
            fail.append((const, asset, "渲染失败: %s" % e))

    print("渲染成功 %d / %d" % (ok, len(enum)))
    for const, asset, why in fail:
        print("  失败 %-22s %-24s %s" % (const, asset, why))
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
