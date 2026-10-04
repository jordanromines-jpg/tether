#!/usr/bin/env python3
"""Generate the README's Mermaid diagrams from the Archify sources in docs/diagrams/src/.

GitHub renders Mermaid natively (crisp vector, zoom + pan), while it can't run the
interactive Archify HTML inside a README. These Mermaid versions copy Archify's look:
role-tinted rounded nodes with a sublabel, emphasis / security / dashed edge styles,
orthogonal routing and dashed region boundaries — all laid out top to bottom.

    python3 docs/diagrams/make_mermaid.py      # rewrites docs/diagrams/mermaid/*.mmd and the README blocks
    docs/diagrams/render_svg.sh                # renders the ELK architecture to light/dark SVG
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "docs/diagrams/src"
OUT = ROOT / "docs/diagrams/mermaid"

# Archify's role palette. Fills are translucent so the same diagram reads in light and dark mode.
ROLE = {
    "frontend": ("#0891b2", "#0891b21f"),
    "backend": ("#059669", "#0596691f"),
    "security": ("#e11d48", "#e11d481f"),
    "database": ("#7c3aed", "#7c3aed1f"),
    "external": ("#64748b", "#64748b1f"),
    "cloud": ("#d97706", "#d977061f"),
    "messagebus": ("#d97706", "#d977061f"),
}
EDGE = {
    "default": "stroke:#94a3b8,stroke-width:1.5px",
    "emphasis": "stroke:#059669,stroke-width:2.5px",
    "security": "stroke:#e11d48,stroke-width:1.5px,stroke-dasharray:5 4",
    "dashed": "stroke:#94a3b8,stroke-width:1.5px,stroke-dasharray:4 4",
}
INIT = ('%%{init: {"flowchart": {"curve": "stepBefore", "nodeSpacing": 28, "rankSpacing": 44, "padding": 10},'
        ' "themeVariables": {"fontSize": "14px"}}}%%')


def esc(text):
    # Markdown strings would read * and _ as emphasis; use look-alike characters.
    return text.replace('"', "'").replace("`", "'").replace("*", "∗")


def node(nid, label, sub, shape=("(", ")")):
    body = f"**{esc(label)}**" + (f"\n{esc(sub)}" if sub else "")
    return f'{nid}{shape[0]}"`{body}`"{shape[1]}'


def class_defs():
    lines = [f"classDef {r} fill:{f},stroke:{s},stroke-width:1.5px,rx:6,ry:6" for r, (s, f) in ROLE.items()]
    lines.append("classDef region fill:transparent,stroke:#d97706,stroke-width:1px,stroke-dasharray:6 4")
    lines.append("classDef guard fill:transparent,stroke:#e11d48,stroke-width:1px,stroke-dasharray:6 4")
    return lines


def architecture():
    """The full architecture map — every node-to-node link — laid out by Mermaid's ELK engine.

    GitHub's built-in Mermaid only ships the dagre layout (which tangles a graph this dense) and
    rejects ELK, so this one isn't embedded as a Mermaid block: render_svg.sh renders it to
    light/dark SVG files that the README shows as a crisp vector image.
    """
    a = json.loads((SRC / "architecture.json").read_text())
    comps = {c["id"]: c for c in a["components"]}
    regions = {b["label"]: b["wraps"] for b in a["boundaries"]}
    device = next(w for l, w in regions.items() if "browser" in l.lower())
    mac = next(w for l, w in regions.items() if "control" in l.lower())
    app = next(w for l, w in regions.items() if "127.0.0.1" in l)
    out = ['%%{init: {"layout": "elk", "elk": {"nodePlacementStrategy": "BRANDES_KOEPF", "mergeEdges": false},'
           ' "flowchart": {"curve": "stepBefore", "htmlLabels": false}, "themeVariables": {"fontSize": "14px"}}}%%',
           "flowchart TB"]

    def emit(ids, indent):
        for i in ids:
            c = comps[i]
            out.append(" " * indent + node(i, c["label"], c.get("sublabel", "")) + f":::{c['type']}")

    out.append('  subgraph DEVICE["Your iPhone / iPad / Mac browser (PWA)"]')
    emit(device, 4)
    out.append("  end")
    out.append('  subgraph MAC["The Mac you control"]')
    emit([i for i in mac if i not in app], 4)
    out.append('    subgraph APP["Tether.app · listens on 127.0.0.1:7400 only"]')
    emit(app, 6)
    out.append("    end")
    out.append("  end")
    styles = []
    for k, e in enumerate(a["connections"]):
        v = e.get("variant", "default")
        arrow = "-.->" if v in ("dashed", "security") else ("==>" if v == "emphasis" else "-->")
        out.append(f"  {e['from']} {arrow}" + (f'|"{esc(e["label"])}"|' if e.get("label") else "") + f" {e['to']}")
        styles.append(f"  linkStyle {k} {EDGE[v]}")
    out += styles + ["  " + l for l in class_defs()]
    out += ["  class DEVICE,MAC region", "  class APP guard"]
    return "\n".join(out)


def session():
    s = json.loads((SRC / "session.json").read_text())
    name_to_id = {"You": "You", "Tether app": "App", "Tailscale": "TS", "Server": "Server", "Passkeys": "Passkeys",
                  "Hub": "Hub", "InputInjector": "Input", "Capture": "Capture", "macOS": "macOS"}
    display = {"You": "You", "App": "Tether app", "TS": "Tailscale serve", "Server": "Tether server",
               "Passkeys": "Passkeys", "Hub": "Hub", "Input": "InputInjector", "Capture": "Capture", "macOS": "macOS"}
    boxes = [("rgba(8,145,178,0.10)", "Your device", ["You", "App"]),
             ("rgba(225,29,72,0.08)", "Tailscale + server gate", ["TS", "Server", "Passkeys"]),
             ("rgba(5,150,105,0.10)", "Hub", ["Hub"]),
             ("rgba(100,116,139,0.10)", "Mac side", ["Input", "Capture", "macOS"])]
    phase_tint = ["rgba(225,29,72,0.05)", "rgba(124,58,237,0.05)", "rgba(5,150,105,0.05)", "rgba(8,145,178,0.05)",
                  "rgba(5,150,105,0.05)", "rgba(8,145,178,0.05)", "rgba(217,119,6,0.05)", "rgba(100,116,139,0.05)"]
    step_of = {c["id"]: c for c in s["components"] if c["id"].startswith("s")}
    edge_variant = {e["to"]: e.get("variant", "default") for e in s["connections"]}
    out = ['%%{init: {"sequence": {"mirrorActors": false, "messageAlign": "left", "actorMargin": 16, "width": 104, "boxMargin": 6, "messageFontSize": 14, "actorFontSize": 13, "noteFontSize": 13}}}%%',
           "sequenceDiagram", "  autonumber"]
    for color, title, ids in boxes:
        out.append(f"  box {color} {title}")
        for i in ids:
            out.append(f"    {'actor' if i == 'You' else 'participant'} {i} as {display[i]}")
        out.append("  end")
    for p, b in enumerate(s["boundaries"]):
        title = re.sub(r"^\d+\.\s*", "", b["label"])
        out.append(f"  rect {phase_tint[p % len(phase_tint)]}")
        first = step_of[b["wraps"][0]]
        frm, to = [name_to_id[x.strip()] for x in first["sublabel"].split("→")]
        out.append(f"    Note over {frm},{to}: {p + 1}. {esc(title)}")
        for sid in b["wraps"]:
            st = step_of[sid]
            frm, to = [name_to_id[x.strip()] for x in st["sublabel"].split("→")]
            text = re.sub(r"^\d+\.\s*", "", st["label"])
            arrow = "-->>" if edge_variant.get(sid) in ("dashed",) else "->>"
            out.append(f"    {frm}{arrow}{to}: {esc(text)}")
        out.append("  end")
    return "\n".join(out)


def setup():
    w = json.loads((SRC / "setup.json").read_text())
    nodes = {n["id"]: n for n in w["nodes"]}
    out = [INIT, "flowchart TB"]
    lanes = [("CHECKS", "Checks — this Mac runs scripts/setup.sh", "checks"),
             ("INSTALL", "Build here → install on the Mac you'll control", "install")]
    for sg, title, lane in lanes:
        out.append(f'  subgraph {sg}["{title}"]')
        out.append("    direction TB")
        for n in sorted((n for n in w["nodes"] if n["lane"] == lane), key=lambda n: n["col"]):
            out.append("    " + node(n["id"], n["label"], n.get("sublabel", "")) + f":::{n['type']}")
        out.append("  end")
    for n in w["nodes"]:
        if n["lane"] in ("you", "you2"):
            out.append("  " + node(n["id"], "✋ " + n["label"], n.get("sublabel", ""), ("([", "])")) + ":::action")
    styles = []
    for k, e in enumerate(w["edges"]):
        role = e.get("role")
        if role == "error":
            out.append(f'  {e["from"]} -.->|"{esc(e.get("label", ""))}"| {e["to"]}')
            styles.append(f"  linkStyle {k} {EDGE['security']}")
        else:
            label = e.get("label")
            out.append(f"  {e['from']} ==>" + (f'|"{esc(label)}"|' if label else "") + f" {e['to']}")
            styles.append(f"  linkStyle {k} {EDGE['emphasis']}")
    out += styles + ["  " + l for l in class_defs()]
    out.append("  classDef action fill:#e11d4814,stroke:#e11d48,stroke-width:1.5px,stroke-dasharray:4 3")
    out += ["  class CHECKS,INSTALL region"]
    return "\n".join(out)


def main():
    OUT.mkdir(exist_ok=True)
    (OUT / "architecture-elk.mmd").write_text(architecture() + "\n")   # rendered to SVG by render_svg.sh
    (OUT / "architecture.mmd").unlink(missing_ok=True)
    blocks = {"session": session(), "setup": setup()}                 # embedded in the README
    for name, text in blocks.items():
        (OUT / f"{name}.mmd").write_text(text + "\n")
    readme = ROOT / "README.md"
    md = readme.read_text()
    for name, text in blocks.items():
        pattern = re.compile(rf"(<!-- mermaid:{name} -->\n)```mermaid\n.*?```\n", re.S)
        if pattern.search(md):
            md = pattern.sub(lambda m: m.group(1) + "```mermaid\n" + text + "\n```\n", md)
    readme.write_text(md)
    print("wrote architecture-elk.mmd,", ", ".join(f"{k}.mmd" for k in blocks))


if __name__ == "__main__":
    main()
