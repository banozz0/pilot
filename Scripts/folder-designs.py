#!/usr/bin/env python3
"""Draws Pilot's folder designs (P54) into Packaging/folder-designs: <id>.heic, the 1024 px cut-out a folder is dressed
in; <id>.png, the same at 256 px for the grid and menu rows; and <id>-small.png, a simpler 64 px drawing for 32 px and
under, which FolderDesigns.art adds to the 1024 as its small representation.

Each is one SVG built here (a back panel of blurred colour, papers peeking out, a frosted glass front with a bright edge,
a soft shadow), rasterised by resvg, since CoreSVG drops the blur and filters. The fluid colour behind the glass is drawn
here in numpy (blobs of colour on a warped field) and placed in the SVG as an image: resvg's displacement filter fails. The front of `plain` holds a picture of
your own: FolderDesigns.icon fits it into x 7 to 57, y 26 to 51 of the 64-unit icon, so the front stays at x 72 to 952,
y 368 to 880 of 1024 here.

  uv run --no-project --python 3.12 --with resvg-py --with pillow --with numpy python -I Scripts/folder-designs.py [id …]
"""
import base64
import io
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import resvg_py
from PIL import Image

OUT = Path(__file__).resolve().parent.parent / "Packaging" / "folder-designs"

BACK = ("M56 198A48 48 0 0 1 104 150H340C366 150 382 158 398 174L446 222C458 232 470 236 488 236H920A48 48 0 0 1 968 284"
        "V836A44 44 0 0 1 924 880H100A44 44 0 0 1 56 836Z")
FRONT = "M72 412A44 44 0 0 1 116 368H908A44 44 0 0 1 952 412V836A44 44 0 0 1 908 880H116A44 44 0 0 1 72 836Z"

# id: base, blobs (colour, cx, cy, rx, ry), papers (top, bottom), glass (tint, top alpha, bottom alpha), motif, its ink,
# swirl (how far the colour runs); dark for smoked glass.
DESIGNS = {
    "lagoon": dict(base="#0A3550", blobs=[("#2BC4F0", 260, 330, 330, 210), ("#7FE9F5", 760, 300, 260, 170),
                                          ("#1B4FD0", 820, 700, 340, 220), ("#0B7FB5", 240, 760, 300, 200)],
                   paper=("#FFFFFF", "#E3F4FB"), glass=("#E8FAFF", .26, .08), motif="wave", ink="#FFFFFF", swirl=110),
    "graphite": dict(base="#1B1E23", blobs=[("#5A6270", 300, 320, 300, 170), ("#A4ADB9", 760, 280, 200, 110),
                                            ("#2E333A", 700, 720, 360, 220), ("#454C57", 220, 760, 260, 180)],
                     paper=("#E6E8EB", "#C9CDD3"), glass=("#30353D", .55, .72), motif="tiles", ink="#C9D1DB", swirl=90,
                     dark=True),
    "paper": dict(base="#BFB3A0", blobs=[("#E9E1D2", 300, 320, 300, 180), ("#FFFFFF", 760, 300, 220, 140),
                                         ("#A89B85", 760, 740, 340, 220), ("#D6CCBA", 220, 760, 260, 180)],
                  paper=("#FFFFFF", "#F1ECE3"), glass=("#FFFDF8", .30, .14), motif="ruling", ink="#E0533F", swirl=60, outline=.22,
                  sheets=3),
    "blueprint": dict(base="#0C3580", blobs=[("#2F6FE0", 280, 320, 320, 200), ("#5AA0FF", 760, 300, 240, 150),
                                             ("#0A2A66", 760, 740, 360, 220), ("#1D4EB0", 220, 760, 260, 180)],
                      paper=("#EAF2FF", "#C8DBFA"), glass=("#D6E6FF", .22, .08), motif="grid", ink="#FFFFFF", swirl=70, sheets=5),
    "kraft": dict(base="#8E6239", blobs=[("#C99A68", 280, 320, 320, 200), ("#DDB98C", 760, 290, 240, 150),
                                         ("#7A5230", 760, 740, 360, 220), ("#A9784A", 220, 760, 260, 180)],
                  paper=("#FBF3E4", "#EBDCC0"), glass=("#F6E7CF", .26, .10), motif="tie", ink="#5A3A1C", swirl=50,
                  grain=.045),
    "terminal": dict(base="#040806", blobs=[("#1FAE4A", 300, 330, 230, 120), ("#0E3B1E", 720, 320, 320, 180),
                                            ("#3BEA5C", 800, 760, 170, 90), ("#0B2414", 240, 760, 300, 200)],
                     paper=("#DCE8E0", "#BFD3C6"), glass=("#08120D", .48, .62), motif="prompt", ink="#3BEA5C",
                     swirl=90, dark=True, rim="#3BEA5C", sheets=1),
    "code": dict(base="#211660", blobs=[("#5B4BFF", 280, 320, 320, 190), ("#8A5CFF", 780, 300, 240, 150),
                                        ("#2D7BFF", 760, 740, 300, 190), ("#3B2A8C", 220, 760, 280, 180)],
                 paper=("#EEEAFF", "#D2CBF7"), glass=("#1C1450", .44, .62), motif="code", ink="#B9E8FF", swirl=110,
                 dark=True, sheets=0),
    "sunset": dict(base="#7A2418", blobs=[("#FF8A3D", 260, 330, 320, 190), ("#FFC15E", 720, 260, 240, 140),
                                          ("#FF5A4E", 780, 690, 340, 210), ("#B8326A", 220, 780, 300, 190)],
                   paper=("#FFFFFF", "#FFEDE2"), glass=("#FFF1E6", .24, .06), motif="sun", ink="#FFFFFF", swirl=130, sheets=1),
    "mint": dict(base="#1E9E6A", blobs=[("#9FF0C9", 280, 320, 330, 200), ("#E2FFF2", 760, 290, 240, 140),
                                        ("#3CCB8C", 760, 740, 360, 220), ("#14845A", 220, 780, 260, 170)],
                 paper=("#FFFFFF", "#E6FBF1"), glass=("#F0FFF8", .28, .08), motif="leaf", ink="#FFFFFF", swirl=90),
    "music": dict(base="#4A0A3A", blobs=[("#FF2E93", 260, 330, 320, 190), ("#FF7A59", 760, 280, 240, 150),
                                         ("#C026D3", 760, 730, 360, 220), ("#FFD23F", 230, 780, 200, 120)],
                  paper=("#FFFFFF", "#FFE6F2"), glass=("#FFE9F4", .20, .06), motif="note", ink="#FFFFFF", swirl=90, sheets=1),
    "archive": dict(base="#4F5762", blobs=[("#8E98A6", 280, 320, 320, 200), ("#B9C2CD", 760, 290, 240, 150),
                                           ("#6E7681", 760, 740, 360, 220), ("#5C6672", 220, 760, 260, 180)],
                    paper=("#F7F8FA", "#DEE2E8"), glass=("#E8ECF1", .22, .08), motif="handle", ink="#FFFFFF", swirl=40,
                    sheets=4),
    "candy": dict(base="#FFC933", blobs=[("#FF6FB5", 260, 320, 280, 170), ("#FFE58A", 760, 270, 240, 150),
                                         ("#5FE3C0", 780, 730, 260, 160), ("#FFB020", 220, 770, 300, 190)],
                  paper=("#FFFFFF", "#FFF0F8"), glass=("#FFF4FB", .26, .08), motif="smile", ink="#7A1046", swirl=120),
    # The frame a picture of your own is fitted into: calm, no art and no mark of its own.
    "plain": dict(base="#2F86D6", blobs=[("#5DB2F5", 300, 300, 360, 200), ("#2A74C8", 760, 760, 380, 220)],
                  paper=("#FFFFFF", "#E7F2FD"), glass=("#EAF5FF", .40, .26), motif=None, swirl=0),
}


def motif(kind, ink):
    """The design's mark and any texture across the front (extra), the mark centred on the glass in one box (about 240 x 180 round 512, 630), one stroke weight: paths,
    never text. Big enough to survive at 32 px, where it is most of what tells two designs of one colour apart."""
    line = f'fill="none" stroke="{ink}" stroke-width="28" stroke-linecap="round" stroke-linejoin="round"'
    marks = {
        "wave": f'<path {line} d="M392 600c27-26 53-26 80 0s53 26 80 0 53-26 80 0M392 670c27-26 53-26 80 0s53 26 80 0 53-26 80 0"/>',
        "tiles": "".join(f'<rect x="{x}" y="{y}" width="80" height="80" rx="18" fill="{ink}"/>'
                         for x in (420, 524) for y in (538, 642)),
        "ruling": f'<path {line} d="M392 570H632M392 630H632M392 690H552"/>'.replace(f'stroke="{ink}"', 'stroke="#8A7D66"'),
        "grid": f'<g {line}><circle cx="512" cy="630" r="84"/><path d="M512 520V740M402 630H622"/></g>',
        # Parcel twine: a bow where the string crosses (the string itself runs across the whole front, below).
        "tie": (f'<g {line}><path d="M512 624C470 560 410 566 418 604 426 642 474 640 512 624ZM512 624C554 560 614 566 606 604 598 642 550 640 512 624Z"/>'
                f'<path d="M512 624L470 704M512 624L556 700"/></g>'),
        "prompt": f'<path {line} d="M412 566l80 64-80 64M532 700h100"/>',
        "code": f'<path {line} d="M452 566l-72 64 72 64M572 566l72 64-72 64M540 552l-56 156"/>',
        "sun": f'<path d="M422 650a90 90 0 0 1 180 0Z" fill="{ink}"/><path {line} d="M392 694H632M452 740H572"/>',
        "leaf": (f'<path d="M412 720C412 604 500 540 632 540 632 660 560 720 412 720Z" fill="{ink}"/>'
                 f'<path d="M444 690L590 578" fill="none" stroke="#1E9E6A" stroke-opacity=".55" stroke-width="16" stroke-linecap="round"/>'),
        "note": (f'<path {line} d="M486 712V566L626 546V690"/><path d="M486 566L626 546V590L486 610Z" fill="{ink}"/>'
                 f'<ellipse cx="452" cy="712" rx="42" ry="32" transform="rotate(-20 452 712)" fill="{ink}"/>'
                 f'<ellipse cx="592" cy="690" rx="42" ry="32" transform="rotate(-20 592 690)" fill="{ink}"/>'),
        "handle": f'<rect x="392" y="594" width="240" height="72" rx="36" {line}/>',
        "smile": (f'<circle cx="456" cy="590" r="24" fill="{ink}"/><circle cx="568" cy="590" r="24" fill="{ink}"/>'
                  f'<path {line} d="M432 650Q512 728 592 650"/>'),
    }
    mark = marks.get(kind, "")
    extra = ""
    if kind == "tie":  # the twine round the parcel
        extra = (f'<g stroke="{ink}" stroke-opacity=".75" stroke-width="16" clip-path="url(#front)">'
                 '<path d="M512 368V880M72 624H952"/></g>')
    if kind == "ruling":  # a notebook page: faint blue rules and the red margin
        rules = "".join(f'<path d="M72 {y}H952"/>' for y in range(424, 880, 40))
        extra = (f'<g stroke="#5C8FD6" stroke-opacity=".22" stroke-width="3" clip-path="url(#front)">{rules}</g>'
                 f'<path d="M196 368V880" stroke="{ink}" stroke-opacity=".45" stroke-width="4" clip-path="url(#front)"/>')
    if kind == "grid":  # Blueprint's faint drafting grid across the whole front
        lines = "".join(f'<path d="M{x} 368V880"/>' for x in range(136, 952, 64))
        lines += "".join(f'<path d="M72 {y}H952"/>' for y in range(432, 880, 64))
        extra = f'<g stroke="{ink}" stroke-opacity=".2" stroke-width="3" clip-path="url(#front)">{lines}</g>'
    return extra, mark


def papers(d):
    top, bottom = d["paper"]
    # (turn, x, top, width) per sheet; each design keeps its own stack.
    stacks = {
        0: [],
        1: [("-1.2", 150, 296, 724)],
        2: [("-2.6", 128, 292, 744), ("1.8", 156, 318, 712)],
        3: [("-3.4", 116, 252, 752), ("0.9", 140, 284, 740), ("2.6", 176, 318, 690)],
        # Archive: a full drawer of tall files, straight and close
        4: [("0", 120, 214, 784), ("0", 136, 250, 752), ("0", 152, 286, 720), ("0", 168, 322, 688)],
        # Blueprint: one wide sheet, as a drawing on the board
        5: [("-4.5", 104, 236, 800)],
    }
    sheets = stacks[d.get("sheets", 2)]
    out = []
    for i, (turn, x, y, w) in enumerate(sheets):
        lines = ""
        if d.get("motif") == "grid" and i == len(sheets) - 1:  # a ruled sheet
            lines = "".join(f'<path d="M{x + 16} {yy}H{x + w - 16}" stroke="#2F6FE0" stroke-opacity=".35" stroke-width="3"/>'
                            for yy in range(y + 40, 400, 28))
        h = 640 - y  # down to a little below the front's top, so the glass shows the colour, not the papers
        out.append(f'<g transform="rotate({turn} 512 520)" filter="url(#sheet)">'
                   f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="22" fill="url(#paper)"/>{lines}'
                   f'<rect x="{x + 1.5}" y="{y + 1.5}" width="{w - 3}" height="{h - 3}" rx="21" fill="none" stroke="#FFFFFF" stroke-opacity=".8" stroke-width="3"/></g>')
    return f'<linearGradient id="paper" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/></linearGradient>', "".join(out)


def hex_rgb(c):
    return np.array([int(c[i:i + 2], 16) for i in (1, 3, 5)], dtype=float) / 255


def fluid(d, side=512):
    """The back panel's colour: each blob a soft pool of its colour over the base, sampled on a field warped by a few
    slow waves (seeded per design), so the pools run into streaks as poured ink does."""
    rng = np.random.default_rng(sum(map(ord, d["base"])) + len(d["blobs"]))
    y, x = np.mgrid[0:side, 0:side].astype(float) * (1024 / side)
    u, v = x.copy(), y.copy()
    swirl = d["swirl"]
    for _ in range(3):
        f = rng.uniform(.004, .009, 4)
        p = rng.uniform(0, 2 * np.pi, 4)
        u, v = (u + swirl * np.sin(v * f[0] + p[0]) + swirl * .5 * np.sin((u + v) * f[1] + p[1]),
                v + swirl * np.cos(u * f[2] + p[2]) + swirl * .5 * np.sin((u - v) * f[3] + p[3]))
    colour = np.broadcast_to(hex_rgb(d["base"]), (side, side, 3)).copy()
    for c, cx, cy, rx, ry in d["blobs"]:
        # Each pool laid over what is there (not averaged into it, which goes to mud), drawn out about 3:1 along the
        # flow so the colour streaks.
        w = np.minimum(1, 1.6 * np.exp(-(((u - cx) / (rx * 1.7)) ** 2 + ((v - cy) / (ry * .6)) ** 2) * 1.6))[..., None]
        colour = colour * (1 - w) + hex_rgb(c) * w
    # Silk: light bands along the flow, and soft bright sheens where the bands crest, as in poured ink.
    band = np.sin((u * .6 + v) * .026)
    colour *= 1 + .2 * band[..., None]
    colour += .10 * (np.clip(band, 0, 1) ** 5)[..., None]
    # Streaks: fine lines combed along the flow, as a brush drags ink.
    streak = sum(np.sin(u * f + v * f * .18 + p) / k for k, (f, p) in enumerate(zip((.09, .17, .31), rng.uniform(0, 6, 3)), 1))
    colour *= 1 + .12 * streak[..., None]
    # Grain, in one tone: a printed surface rather than a screen gradient.
    colour *= 1 + rng.normal(0, d.get("grain", .012), (side, side, 1))
    rgb = (np.clip(colour, 0, 1) * 255).astype(np.uint8)
    buf = io.BytesIO()
    Image.fromarray(rgb, "RGB").save(buf, "PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()


def svg(d, small=False):
    """The design at 1024; `small` is the drawing for 32 px and under: no papers and no wide shadow, the mark at about
    60 % of the front's height, a lit top edge and, on a dark design, a light rim, so it holds on a dark ground."""
    dark = d.get("dark", False)
    paper_grad, sheet = papers(d)
    if small:
        sheet = ""
    tint, a_top, a_bottom = d["glass"]
    if not dark:  # a milky pane that sits apart from the art behind it
        a_top, a_bottom = a_top + .06, a_bottom + .06
    edge_top, edge_bottom = (.55, .12) if dark else (1, .34)
    extra, mark = motif(d.get("motif"), d.get("ink", "#FFFFFF"))
    if mark:
        scale = 1.7 if small else 1.3
        mark = (f'<g opacity="{.85 if dark else 1}" transform="translate(512 630) scale({scale}) translate(-512 -630)">{mark}</g>')
    edge_width = 28 if small else 10
    return f'''<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <clipPath id="back"><path d="{BACK}"/></clipPath>
  <clipPath id="front"><path d="{FRONT}"/></clipPath>
  <filter id="frost" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="26"/></filter>
  <filter id="pane" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="26"/><feComponentTransfer><feFuncR type="linear" slope="{1 if dark else 1.1}"/><feFuncG type="linear" slope="{1 if dark else 1.1}"/><feFuncB type="linear" slope="{1 if dark else 1.1}"/></feComponentTransfer></filter>
  <filter id="sheet" x="-10%" y="-10%" width="120%" height="130%"><feDropShadow dx="0" dy="6" stdDeviation="10" flood-color="#000" flood-opacity=".22"/></filter>
  <filter id="shadowWide" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="26"/></filter>
  <filter id="shadowNear" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur stdDeviation="6"/></filter>
  <linearGradient id="backShade" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity=".06"/><stop offset=".4" stop-color="#000" stop-opacity=".08"/><stop offset="1" stop-color="#000" stop-opacity=".34"/></linearGradient>
  <linearGradient id="tint" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{tint}" stop-opacity="{a_top}"/><stop offset="1" stop-color="{tint}" stop-opacity="{a_bottom}"/></linearGradient>
  <linearGradient id="sheen" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity="{.10 if dark else .18}"/><stop offset=".45" stop-color="#FFFFFF" stop-opacity="0"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="{.04 if dark else .10}"/></linearGradient>
  <linearGradient id="edge" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity="{edge_top}"/><stop offset=".35" stop-color="#FFFFFF" stop-opacity="{edge_bottom}"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="{edge_bottom * .6}"/></linearGradient>
  <linearGradient id="backEdge" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity="{.30 if dark else .45}"/><stop offset=".2" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>
  <linearGradient id="under" x1="0" y1="0" x2="0" y2="1"><stop offset=".3" stop-color="#000" stop-opacity="{.10 if dark else .14}"/><stop offset="1" stop-color="#000" stop-opacity="0"/></linearGradient>
  {paper_grad}
  <image id="raw" x="0" y="0" width="1024" height="1024" preserveAspectRatio="none" xlink:href="{fluid(d)}"/>
  <g id="art" clip-path="url(#back)"><use xlink:href="#raw"/><path d="{BACK}" fill="url(#backShade)"/></g>
  <g id="behind"><use xlink:href="#art"/>{sheet}</g>
</defs>
{"" if small else '<path d="M88 520H936V880Q936 912 900 912H124Q88 912 88 880Z" fill="#000" opacity=".30" filter="url(#shadowWide)" transform="translate(0 26)"/>'}
<path d="{BACK}" fill="#000" opacity=".22" filter="url(#shadowNear)" transform="translate(0 6)"/>
<use xlink:href="#behind"/>
<path d="{BACK}" fill="none" stroke="url(#backEdge)" stroke-width="4" clip-path="url(#back)"/>
<path d="{BACK}" fill="none" stroke="#000" stroke-opacity="{d.get("outline", .16)}" stroke-width="{4 if d.get("outline") else 2}"/>
<path d="{FRONT}" fill="#000" opacity=".22" filter="url(#shadowNear)" transform="translate(0 -4)" clip-path="url(#back)"/>
<g clip-path="url(#front)"><use xlink:href="#raw" filter="url(#pane)"/><g opacity=".32" filter="url(#frost)">{sheet}</g></g>
<path d="{FRONT}" fill="url(#tint)"/>
<path d="{FRONT}" fill="url(#sheen)"/>
<path d="M72 368H952V392H72Z" fill="url(#under)" clip-path="url(#front)"/>
{extra}{mark}
<path d="{FRONT}" fill="none" stroke="url(#edge)" stroke-width="{edge_width}" clip-path="url(#front)"/>
<path d="M72 412A44 44 0 0 1 116 370H908A44 44 0 0 1 952 412" fill="none" stroke="#FFFFFF" stroke-opacity="{.5 if dark else .9}" stroke-width="4" stroke-linecap="round"/>
<path d="{FRONT}" fill="none" stroke="#000" stroke-opacity="{.30 if dark else .14}" stroke-width="2"/>
{f'<path d="{FRONT}" fill="none" stroke="{d["rim"]}" stroke-opacity=".4" stroke-width="{24 if small else 8}" clip-path="url(#front)"/>' if d.get("rim") else ""}
{f'<path d="{BACK}" fill="none" stroke="#FFFFFF" stroke-opacity=".5" stroke-width="32" clip-path="url(#back)"/>' if small and dark else ""}
</svg>'''


BUDGET = 3 * 1024 * 1024  # what the set may add to the app (P54); the SVG set it replaced was 9 KB
DISPLAY = 256  # the grid and menu rows draw <id>.png, never above 128 pt at 2x; decoded it is 256 KB, not the 4 MB of 1024


def main(ids):
    OUT.mkdir(parents=True, exist_ok=True)
    for name in ids or DESIGNS:
        art = Image.open(io.BytesIO(bytes(resvg_py.svg_to_bytes(svg_string=svg(DESIGNS[name]))))).convert("RGBA")
        small = Image.open(io.BytesIO(bytes(resvg_py.svg_to_bytes(svg_string=svg(DESIGNS[name], True))))).convert("RGBA")
        # The full art, which dresses a folder: HEIC keeps alpha at a tenth of PNG's size (sips, macOS's own encoder).
        with tempfile.TemporaryDirectory() as tmp:
            art.save(Path(tmp) / "art.png")
            subprocess.run(["sips", "-s", "format", "heic", "-s", "formatOptions", "85", str(Path(tmp) / "art.png"),
                            "--out", str(OUT / f"{name}.heic")], check=True, capture_output=True)
        art.resize((DISPLAY, DISPLAY), Image.LANCZOS).save(OUT / f"{name}.png", optimize=True)
        small.resize((64, 64), Image.LANCZOS).save(OUT / f"{name}-small.png", optimize=True)
        print(name, sum((OUT / f).stat().st_size for f in (f"{name}.heic", f"{name}.png", f"{name}-small.png")) // 1024, "KB")
    total = sum(f.stat().st_size for f in OUT.iterdir())
    print(f"set {total / 1024:.0f} KB of {BUDGET // 1024} KB")
    if total > BUDGET:
        sys.exit("over the size budget")


if __name__ == "__main__":
    main(sys.argv[1:])
