#!/usr/bin/env bash
# Renders docs/diagrams/mermaid/architecture-elk.mmd to light and dark SVG files with the same
# Mermaid release GitHub uses (11.17.2) plus the ELK layout engine, via headless Chrome.
#   docs/diagrams/render_svg.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/docs/diagrams/mermaid/architecture-elk.mmd"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; kill "${SERVER:-0}" 2>/dev/null || true' EXIT
python3 - "$SRC" "$TMP" <<'PY'
import html, sys, pathlib
code = pathlib.Path(sys.argv[1]).read_text(); tmp = pathlib.Path(sys.argv[2])
for theme in ("default", "dark"):
    (tmp / f"{theme}.html").write_text(f"""<!doctype html><meta charset="utf-8"><pre id="src">{html.escape(code)}</pre><textarea id="out"></textarea>
<script type="module">
import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11.17.2/dist/mermaid.esm.min.mjs";
import elk from "https://cdn.jsdelivr.net/npm/@mermaid-js/layout-elk@0/dist/mermaid-layout-elk.esm.min.mjs";
mermaid.registerLayoutLoaders(elk);
const text = "{theme}" === "dark"
  ? {{nodeTextColor: "#e6edf3", primaryTextColor: "#e6edf3", textColor: "#c9d1d9", titleColor: "#c9d1d9", edgeLabelBackground: "#262c36"}}
  : {{nodeTextColor: "#1f2328", primaryTextColor: "#1f2328", textColor: "#424a53", titleColor: "#424a53", edgeLabelBackground: "#eef1f4"}};
mermaid.initialize({{startOnLoad: false, theme: "{theme}", securityLevel: "strict", themeVariables: text}});
try {{ const {{svg}} = await mermaid.render("tether", document.getElementById("src").textContent);
  // Mermaid returns HTML-serialized markup; a standalone .svg (shown via <img>) must be strict XML.
  const holder = document.createElement("div"); holder.innerHTML = svg;
  const el = holder.querySelector("svg"); el.setAttribute("xmlns", "http://www.w3.org/2000/svg");
  document.getElementById("out").textContent = '<?xml version="1.0" encoding="UTF-8"?>' + new XMLSerializer().serializeToString(el);
  document.title = "ok"; }}
catch (e) {{ document.title = "ERR " + e.message; }}
</script>""")
PY
PORT=8767
(cd "$TMP" && exec python3 -m http.server $PORT >/dev/null 2>&1) & SERVER=$!
sleep 1
for pair in default:light dark:dark; do
  theme="${pair%%:*}"; name="${pair##*:}"
  "$CHROME" --headless=new --disable-gpu --virtual-time-budget=20000 --dump-dom "http://localhost:$PORT/$theme.html" 2>/dev/null > "$TMP/$theme.dom"
  python3 - "$TMP/$theme.dom" "$ROOT/docs/diagrams/architecture-elk-$name.svg" <<'PY'
import html, re, sys, pathlib
dom = pathlib.Path(sys.argv[1]).read_text()
if "<title>ok</title>" not in dom:
    sys.exit("render failed: " + (re.search(r"<title>(.*?)</title>", dom) or [None, "no title"])[1])
svg = html.unescape(re.search(r'<textarea id="out">(.*?)</textarea>', dom, re.S).group(1))
pathlib.Path(sys.argv[2]).write_text(svg)
print("wrote", sys.argv[2], f"{len(svg)//1024} KB")
PY
done
