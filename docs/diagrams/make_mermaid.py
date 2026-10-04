#!/usr/bin/env python3
"""Generate the README's Mermaid diagrams from the Archify sources in docs/diagrams/src/.

GitHub renders Mermaid natively (crisp vector, zoom + pan), while it can't run the
interactive Archify HTML inside a README. These Mermaid versions copy Archify's look:
role-tinted rounded nodes with a sublabel, emphasis / security / dashed edge styles,
orthogonal routing and dashed region boundaries — all laid out top to bottom.

    python3 docs/diagrams/make_mermaid.py      # rewrites docs/diagrams/mermaid/*.mmd and the README blocks
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
    """Layered, top-to-bottom view of the same components as the Archify map.

    Mermaid's flowchart layout tangles a 33-node graph with dozens of cross links, so the README
    version stacks horizontal layers: links inside a layer are drawn node to node, links between
    layers once, labeled with the protocol. The interactive Archify map keeps every node-to-node link.
    """
    a = json.loads((SRC / "architecture.json").read_text())
    comps = {c["id"]: c for c in a["components"]}
    layers = [
        ("L1", "Your device · screen and input", ["you", "input", "stream", "cursorc", "audioc"]),
        ("L2", "Your device · lock, files and other Macs", ["passkeyc", "ui", "filesui", "macs"]),
        ("L3", "Your tailnet → the Mac", ["serve", "gate"]),
        ("L4", "Tether.app routes · 127.0.0.1:7400 only", ["static", "auth", "ws", "files", "peers"]),
        ("L5", "Services and storage", ["pstore", "appsupport", "sandbox", "folders", "peersnode"]),
        ("L6", "Hub · one capture feeds every viewer", ["hub", "adaptive"]),
        ("L7", "Capture and encode", ["fit", "streamer", "encoder", "audioenc"]),
        ("L8", "Input and sync", ["inputinj", "clip", "cursorw"]),
        ("L9", "macOS", ["displays", "hid", "pasteboard"]),
    ]
    layer_of = {nid: lid for lid, _, ids in layers for nid in ids}
    out = [INIT, "flowchart TB"]
    for lid, title, ids in layers:
        out.append(f'  subgraph {lid}["{title}"]')
        out.append("    direction LR")
        for i in ids:
            c = comps[i]
            out.append("    " + node(i, c["label"], c.get("sublabel", "")) + f":::{c['type']}")
        out.append("  end")
    styles, k = [], 0

    def link(a_, b_, label, variant):
        nonlocal k
        arrow = "-.->" if variant in ("dashed", "security") else ("==>" if variant == "emphasis" else "-->")
        out.append(f"  {a_} {arrow}" + (f'|"{esc(label)}"|' if label else "") + f" {b_}")
        styles.append(f"  linkStyle {k} {EDGE[variant]}")
        k += 1

    # Node-to-node links that stay inside one layer, straight from the Archify source.
    for e in a["connections"]:
        if layer_of[e["from"]] == layer_of[e["to"]]:
            link(e["from"], e["to"], e.get("label"), e.get("variant", "default"))
    # One labeled link per pair of adjacent layers (the protocol between them).
    for a_, b_, label, variant in [
        ("L1", "L2", None, "dashed"),
        ("L2", "L3", "HTTPS + WSS (tailnet only)", "emphasis"),
        ("L3", "L4", "verified login → :7400", "emphasis"),
        ("L4", "L5", "verify · resolve · list", "security"),
        ("L4", "L6", "/ws messages", "emphasis"),
        ("L6", "L7", "start · keyframe · bitrate", "emphasis"),
        ("L7", "L8", None, "dashed"),
        ("L8", "L9", "CGEvent · pasteboard · pixels", "default"),
    ]:
        link(a_, b_, label, variant)
    # Keep every layer on its own row, in order (layers that branch from the same parent would sit side by side).
    out.append("  " + " ~~~ ".join(l for l, _, _ in layers))
    # Invisible links put each layer's boxes side by side, in the listed order.
    for _, _, ids in layers:
        if len(ids) > 1:
            out.append("  " + " ~~~ ".join(ids))
    out += styles + ["  " + l for l in class_defs()]
    out.append("  class " + ",".join(l for l, _, _ in layers) + " region")
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
    blocks = {"architecture": architecture(), "session": session(), "setup": setup()}
    for name, text in blocks.items():
        (OUT / f"{name}.mmd").write_text(text + "\n")
    readme = ROOT / "README.md"
    md = readme.read_text()
    for name, text in blocks.items():
        pattern = re.compile(rf"(<!-- mermaid:{name} -->\n)```mermaid\n.*?```\n", re.S)
        if pattern.search(md):
            md = pattern.sub(lambda m: m.group(1) + "```mermaid\n" + text + "\n```\n", md)
    readme.write_text(md)
    print("wrote", ", ".join(f"{k}.mmd" for k in blocks))


if __name__ == "__main__":
    main()
