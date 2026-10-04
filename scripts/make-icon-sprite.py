#!/usr/bin/env python3
"""Builds web/icons.svg, a sprite of the Phosphor icons (MIT) the client uses.

    npm pack @phosphor-icons/core && tar xzf phosphor-icons-core-*.tgz
    python3 scripts/make-icon-sprite.py package      # path to the unpacked package

Use an icon in HTML as <svg class="i"><use href="icons.svg#name"/></svg>.
"""
import json
import re
import sys
from pathlib import Path

ICONS = [
    # toolbar
    "dots-six-vertical", "keyboard", "pencil-simple-line", "lightning", "clipboard-text", "folder-simple",
    "speaker-high", "speaker-slash", "sliders-horizontal", "arrows-out", "arrows-in", "caret-down", "caret-up",
    "dots-three", "x", "desktop",
    # screens and sheets
    "pause-circle", "lock-simple", "fingerprint", "warning-circle", "moon", "plugs", "file", "upload-simple",
    "download-simple", "sun", "arrow-clockwise", "lightbulb", "arrows-out-cardinal", "check", "copy",
    # first-run tips
    "hand-tap", "mouse-scroll", "hand-swipe-left", "cursor-click",
]

pkg = Path(sys.argv[1] if len(sys.argv) > 1 else "package")
version = json.loads((pkg / "package.json").read_text())["version"]
root = Path(__file__).resolve().parents[1]
out = [f'<svg xmlns="http://www.w3.org/2000/svg">',
       f"<!-- Phosphor Icons {version}, regular weight. MIT License, (c) Phosphor Icons. https://phosphoricons.com -->"]
for name in ICONS:
    svg = (pkg / "assets/regular" / f"{name}.svg").read_text()
    body = re.search(r"<svg[^>]*>(.*)</svg>", svg, re.S).group(1).strip()
    out.append(f'<symbol id="{name}" viewBox="0 0 256 256">{body}</symbol>')
out.append("</svg>")
(root / "web/icons.svg").write_text("\n".join(out) + "\n")
print(f"wrote web/icons.svg ({len(ICONS)} icons, Phosphor {version})")
