#!/usr/bin/env python3
"""Draws Pilot's folder designs (P54) into Packaging/folder-designs: <id>.heic, the 1024 px cut-out a folder is dressed
in; <id>.png, the same at 256 px for the grid and menu rows; and <id>-small.png, a simpler 64 px drawing for 32 px and
under, which FolderDesigns.art adds to the 1024 as its small representation.

Each is one SVG built here (a back panel of blurred colour, papers peeking out, a frosted glass front with a bright edge,
a soft shadow), rasterised by resvg, since CoreSVG drops the blur and filters. The fluid colour behind the glass is drawn
here in numpy (blobs of colour on a warped field) and placed in the SVG as an image: resvg's displacement filter fails. The front of `plain` holds a picture of
your own: FolderDesigns.icon fits it into x 7 to 57, y 26 to 51 of the 64-unit icon, so the front stays at x 72 to 952,
y 368 to 880 of 1024 here.

  uv run --no-project --python 3.12 --with resvg-py --with pillow --with numpy --with pyoxipng python -I Scripts/folder-designs.py [id …]

With no ids it draws every design; name ids to draw only those (T61 drew only the kinds', so today's 13 kept their bytes).
"""
import base64
import io
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import oxipng
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


# The folder kinds (T60, picked by Sven 2026-11-05, Q858-Q862): each kind's marks and pattern tile as paths, never text,
# one stroke weight (28), in the 1024 icon's mark box (about 240 x 180 round 512, 630). Each kind has a palette (main,
# light, deep, accent) and a mark per treatment; a treatment turns them into one of the design dicts above:
#   pour     poured colour, a milky pane, a white mark
#   smoke    smoked glass on a dark pour, the mark and rim in the kind's accent
#   pattern  a tiled pattern of the kind across the pane, the mark over it
#   emboss   one colour, tone on tone, the mark pressed into the pane
#   bold     a clear pane, the mark three times the size and cropped by the pane's edge
# At 32 px and under (the -small drawing) every one shows only its mark: no pattern, no crop. Ids are <kind>-<treatment>;
# FolderDesign.kinds lists the same picks for Pilot.
def S(ink, w=28):
    return f'fill="none" stroke="{ink}" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round"'


def F(ink):
    return f'fill="{ink}"'


def rr(x, y, w, h, r, attrs):
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" {attrs}/>'


# Each mark is ink -> svg. Kept inside x 380..644, y 520..740.
MARKS = {
    # Applications: what you launch
    "app-grid": lambda i: "".join(rr(416 + c * 70, 534 + r * 70, 52, 52, 15, F(i)) for c in range(3) for r in range(3)),
    "rocket": lambda i: (f'<path {S(i)} d="M512 532C556 566 572 626 558 690H466C452 626 468 566 512 532Z"/>'
                         f'<circle cx="512" cy="616" r="20" {F(i)}/>'
                         f'<path {S(i)} d="M466 650 430 700H470M558 650 594 700H554M494 726 512 752 530 726"/>'),
    "compass": lambda i: (f'<circle cx="512" cy="630" r="104" {S(i)}/>'
                          f'<path d="M512 548 544 630H480Z" {F(i)}/><path d="M480 630H544L512 712Z" {S(i, 14)}/>'),
    "app-squircle": lambda i: (rr(420, 538, 184, 184, 54, S(i)) + f'<circle cx="512" cy="630" r="34" {F(i)}/>'),
    "app-stack": lambda i: (rr(452, 520, 150, 150, 44, S(i)) + rr(408, 576, 150, 150, 44, F(i))),
    # Desktop: the screen you work on
    "display": lambda i: (rr(392, 538, 240, 152, 22, S(i)) + f'<path {S(i)} d="M512 690V728M462 732H562"/>'),
    "windows": lambda i: (rr(384, 552, 170, 120, 18, S(i)) + rr(470, 600, 170, 120, 18, F(i))
                          + f'<path {S(i, 16)} d="M402 584H536"/>'),
    "dock": lambda i: (rr(392, 652, 240, 64, 32, S(i, 20)) + "".join(rr(420 + k * 50, 540, 34, 34, 10, F(i)) for k in range(4))
                       + "".join(f'<circle cx="{434 + k * 52}" cy="684" r="12" {F(i)}/>' for k in range(4))),
    "pointer": lambda i: f'<path {S(i)} d="M460 536V708L506 664 540 736 572 722 538 652H604Z"/>',
    "display-wide": lambda i: (f'<path {F(i)} fill-rule="evenodd" d="M404 540H620Q640 540 640 560V694Q640 714 620 714H404Q384 714 384 694V560Q384 540 404 540ZM420 574V680H604V574Z"/>'
                          + f'<path {S(i)} d="M478 744H546"/>' + rr(436, 650, 152, 18, 9, F(i))),
    # Documents: what you write and keep
    "page-fold": lambda i: f'<path {S(i)} d="M444 534H546L600 588V726H444ZM546 534V588H600"/>',
    "page-stack": lambda i: (f'<path {S(i)} d="M470 534H606V690"/>' + rr(418, 572, 152, 158, 18, F(i))),
    "paperclip": lambda i: f'<path {S(i)} d="M560 586V672C560 712 536 734 506 734S452 712 452 672V570C452 546 470 530 492 530S532 546 532 570V664C532 680 522 690 508 690S486 680 486 664V590"/>',
    "page-corner": lambda i: f'<path {F(i)} fill-rule="evenodd" d="M444 534H546L600 588V726H444ZM530 552V604H582Z"/>',
    "page-tab": lambda i: (f'<path {S(i)} d="M432 560H500L522 582H596V720H432Z"/>' + f'<path d="M432 560H500L522 582H432Z" {F(i)}/>'),
    # Downloads: what came in
    "down-tray": lambda i: f'<path {S(i)} d="M512 532V650M462 604 512 654 562 604M412 652V706H612V652"/>',
    "down-circle": lambda i: f'<path {F(i)} fill-rule="evenodd" d="M408 630A104 104 0 1 0 616 630A104 104 0 1 0 408 630ZM494 568H530V628H562L512 690 462 628H494Z"/>',
    "down-chevrons": lambda i: f'<path {S(i)} d="M448 562 512 618 576 562M448 642 512 698 576 642"/>',
    "down-arrow": lambda i: f'<path {S(i, 34)} d="M512 532V712M440 642 512 714 584 642"/>',
    "down-bold": lambda i: f'<path d="M478 532H546V634H604L512 728 420 634H478Z" {F(i)}/>',
    # Pictures: photos you keep
    "hills": lambda i: (rr(392, 540, 240, 180, 26, S(i)) + f'<circle cx="572" cy="594" r="22" {F(i)}/>'
                        + f'<path d="M406 706 470 628 520 682 552 650 618 706Z" {F(i)}/>'),
    "photos": lambda i: (f'<g transform="rotate(-10 512 630)">{rr(404, 548, 190, 150, 20, S(i, 22))}</g>'
                         + f'<g transform="rotate(8 540 640)">{rr(450, 568, 190, 150, 20, F(i))}</g>'),
    "camera": lambda i: (f'<path {S(i)} d="M406 586H460L478 558H546L564 586H618V710H406Z"/>' + f'<circle cx="512" cy="646" r="36" {S(i)}/>'),
    "bloom": lambda i: ("".join(f'<circle cx="{512 + 50 * c}" cy="{630 + 50 * s}" r="44" {F(i)} fill-opacity=".85"/>'
                                for c, s in ((1, 0), (.31, .95), (-.81, .59), (-.81, -.59), (.31, -.95)))),
    "sun-hill": lambda i: (f'<circle cx="560" cy="584" r="46" {F(i)}/><path d="M380 724C430 640 500 640 548 690 580 666 616 668 644 700V724Z" {F(i)}/>'),
    # Screenshots: what you captured
    "marquee": lambda i: (f'<path {S(i)} d="M400 580V552H428M596 552H624V580M624 680V708H596M428 708H400V680"/>'
                          + f'<path {S(i, 14)} stroke-dasharray="20 22" d="M456 552H568M456 708H568M400 608V652M624 608V652"/>'),
    "viewfinder": lambda i: (f'<path {S(i)} d="M408 588V552H444M580 552H616V588M616 672V708H580M444 708H408V672"/>'
                             + f'<circle cx="512" cy="630" r="34" {F(i)}/>'),
    "crosshair": lambda i: (f'<path {S(i)} d="M512 532V598M512 662V728M414 630H480M544 630H610"/>'),
    "snap": lambda i: (f'<path {S(i)} d="M408 588V552H444M580 552H616V588M616 672V708H580M444 708H408V672"/>'
                       + f'<path d="M488 590 560 636 528 644 548 686 528 694 510 652 488 676Z" {F(i)}/>'),
    "frame-corner": lambda i: f'<path {S(i, 40)} d="M420 700V560H560"/><path {S(i, 40)} d="M604 560V700H464" stroke-opacity=".55"/>',
    # Movies: what you watch
    "clapper": lambda i: (f'<path {S(i)} d="M414 622H610V718H414Z"/>'
                          + f'<g transform="rotate(-12 414 610)"><path {F(i)} fill-rule="evenodd" d="M414 566H610V606H414ZM452 570 476 602H500L476 570ZM516 570 540 602H564L540 570Z"/></g>'),
    "filmstrip": lambda i: (rr(432, 532, 160, 196, 16, S(i)) + "".join(rr(448, 552 + k * 42, 18, 22, 4, F(i)) + rr(558, 552 + k * 42, 18, 22, 4, F(i)) for k in range(4))),
    "play": lambda i: (f'<circle cx="512" cy="630" r="104" {S(i)}/><path d="M488 584 560 630 488 676Z" {F(i)}/>'),
    "reel": lambda i: (f'<circle cx="512" cy="630" r="100" {S(i)}/>'
                       + "".join(f'<circle cx="{512 + 50 * c}" cy="{630 + 50 * s}" r="20" {F(i)}/>' for c, s in ((0, -1), (.95, -.31), (.59, .81), (-.59, .81), (-.95, -.31)))),
    "play-bold": lambda i: f'<path d="M456 540Q456 520 474 530L604 618Q622 630 604 642L474 730Q456 740 456 720Z" {F(i)}/>',
    # Music: what you listen to
    "wave-bars": lambda i: "".join(f'<path {S(i)} d="M{412 + k * 40} {630 - h}V{630 + h}"/>' for k, h in enumerate((24, 58, 86, 44, 70, 30))),
    "vinyl": lambda i: (f'<circle cx="512" cy="630" r="106" {F(i)}/><circle cx="512" cy="630" r="72" fill="none" stroke="#000" stroke-opacity=".25" stroke-width="6"/>'
                        f'<circle cx="512" cy="630" r="22" fill="#000" fill-opacity=".35"/>'),
    "headphones": lambda i: (f'<path {S(i)} d="M420 676V636C420 584 462 544 512 544S604 584 604 636V676"/>'
                             + rr(404, 648, 50, 84, 20, F(i)) + rr(570, 648, 50, 84, 20, F(i))),
    "eq": lambda i: (f'<path {S(i, 16)} d="M440 540V720M512 540V720M584 540V720"/>'
                     + "".join(rr(x - 26, y - 16, 52, 32, 16, F(i)) for x, y in ((440, 660), (512, 590), (584, 680)))),
    "eighth": lambda i: (f'<path {S(i)} d="M548 540V690M548 540C580 556 600 580 596 620"/>'
                         + f'<ellipse cx="506" cy="694" rx="50" ry="38" transform="rotate(-20 506 694)" {F(i)}/>'),
    # Public: what you share with others on the network
    "people": lambda i: (f'<circle cx="468" cy="580" r="34" {F(i)}/><circle cx="566" cy="590" r="28" {F(i)} fill-opacity=".7"/>'
                         f'<path d="M398 720C398 660 430 632 468 632S538 660 538 720Z" {F(i)}/>'
                         f'<path d="M552 720C552 680 548 660 532 646 544 638 554 636 566 636 600 636 626 664 626 720Z" {F(i)} fill-opacity=".7"/>'),
    "globe": lambda i: (f'<circle cx="512" cy="630" r="102" {S(i)}/>'
                        f'<path {S(i, 16)} d="M512 528C470 560 470 700 512 732M512 528C554 560 554 700 512 732M414 630H610M430 578H594M430 682H594"/>'),
    "broadcast": lambda i: (f'<circle cx="512" cy="630" r="26" {F(i)}/>'
                            f'<path {S(i)} d="M458 576A76 76 0 0 0 458 684M566 576A76 76 0 0 1 566 684M418 540A128 128 0 0 0 418 720M606 540A128 128 0 0 1 606 720"/>'),
    "drop-tray": lambda i: f'<path {S(i)} d="M512 652V534M466 578 512 532 558 578M412 640V708H612V640"/>',
    "share-nodes": lambda i: (f'<path {S(i, 22)} d="M440 630 584 556M440 630 584 704"/>'
                             + "".join(f'<circle cx="{x}" cy="{y}" r="40" {F(i)}/>' for x, y in ((440, 630), (584, 556), (584, 704)))),
    "open-door": lambda i: (f'<path {S(i)} d="M436 724V548H588V724"/><path d="M436 548 540 572V734L436 724Z" {F(i)}/>'),
    # iCloud Drive and synced folders
    "cloud": lambda i: f'<path {S(i)} d="M450 700H594C628 700 650 676 650 646S626 594 594 596C586 556 554 534 518 534 474 534 444 566 440 604 406 608 384 632 384 654 384 682 410 700 450 700Z"/>',
    "cloud-fill": lambda i: f'<path {F(i)} d="M450 712H594C634 712 662 684 662 648S634 586 596 588C586 540 552 520 514 520 466 520 432 554 428 596 392 602 368 628 368 656 368 688 398 712 450 712Z"/>',
    "cloud-sync": lambda i: (f'<path {S(i)} d="M450 700H594C628 700 650 676 650 646S626 594 594 596C586 556 554 534 518 534 474 534 444 566 440 604 406 608 384 632 384 654 384 682 410 700 450 700Z"/>'
                             f'<path {S(i, 18)} d="M478 650A36 36 0 0 1 544 630M546 652A36 36 0 0 1 480 672M534 618 546 630 554 614M490 684 480 672 470 688"/>'),
    "cloud-up": lambda i: (f'<path {S(i)} d="M450 700H594C628 700 650 676 650 646S626 594 594 596C586 556 554 534 518 534 474 534 444 566 440 604 406 608 384 632 384 654 384 682 410 700 450 700Z"/>'
                           f'<path {S(i, 20)} d="M514 676V610M488 634 514 608 540 634"/>'),
    "cloud-sun": lambda i: (f'<circle cx="580" cy="580" r="46" {F(i)} fill-opacity=".55"/>'
                            f'<path {F(i)} d="M436 716H564C594 716 614 696 614 670S594 626 566 628C558 596 534 580 504 580 468 580 444 606 442 636 414 640 396 660 396 678 396 700 412 716 436 716Z"/>'),
    # Code, Developer, Projects: what you build (no brackets, prompts or other characters)
    "branch": lambda i: (f'<circle cx="452" cy="562" r="26" {S(i, 22)}/><circle cx="452" cy="700" r="26" {S(i, 22)}/><circle cx="574" cy="590" r="26" {S(i, 22)}/>'
                         f'<path {S(i, 22)} d="M452 588V674M574 616C574 652 540 662 486 690"/>'),
    "bug": lambda i: (f'<circle cx="512" cy="560" r="30" {F(i)}/><path {F(i)} d="M512 584C560 584 584 624 584 664S556 736 512 736 440 704 440 664 464 584 512 584Z"/>'
                     f'<path stroke="#000" stroke-opacity=".28" stroke-width="10" d="M512 600V728"/>'
                     f'<path {S(i, 18)} d="M440 640H404M442 690 408 714M446 604 414 588M584 640H620M582 690 616 714M578 604 610 588M496 534 482 516M528 534 542 516"/>'),
    "flow": lambda i: (rr(392, 540, 84, 72, 18, F(i)) + rr(548, 648, 84, 72, 18, F(i)) + f'<circle cx="590" cy="576" r="30" {S(i, 22)}/>'
                      + f'<path {S(i, 22)} d="M476 576H560M434 612V684H548"/>'),
    "cube": lambda i: (f'<path {S(i)} d="M512 534 604 584V684L512 734 420 684V584ZM420 584 512 634 604 584M512 634V734"/>'),
    "cursor-window": lambda i: (rr(392, 548, 240, 168, 22, S(i)) + "".join(f'<circle cx="{424 + k * 26}" cy="578" r="9" {F(i)}/>' for k in range(3))
                                + rr(424, 626, 26, 52, 6, F(i))),
    "chip": lambda i: (rr(448, 566, 128, 128, 22, S(i)) + rr(484, 602, 56, 56, 10, F(i))
                       + f'<path {S(i, 16)} d="M480 532V556M512 532V556M544 532V556M480 704V728M512 704V728M544 704V728M414 598H438M414 630H438M414 662H438M586 598H610M586 630H610M586 662H610"/>'),
    "hex": lambda i: f'<path {F(i)} d="M512 520 612 576V688L512 744 412 688V576Z"/><path d="M512 586 552 608V652L512 674 472 652V608Z" fill="#000" fill-opacity=".28"/>',
    # Notes, the vault: what you think
    "nib": lambda i: (f'<path {S(i)} d="M512 736 450 640 512 528 574 640Z"/><path {S(i, 16)} d="M512 736V650"/><circle cx="512" cy="636" r="14" {F(i)}/>'),
    "pencil": lambda i: (f'<g transform="rotate(45 512 630)"><path {S(i)} d="M480 520H544V700L512 744 480 700Z"/><path {S(i, 16)} d="M480 560H544"/></g>'),
    "spiral": lambda i: (rr(432, 556, 176, 176, 22, S(i)) + "".join(f'<path {S(i, 18)} d="M{464 + k * 38} 530V578"/>' for k in range(4))),
    "bookmark": lambda i: f'<path {F(i)} d="M456 532H568V736L512 692 456 736Z"/>',
    "quill": lambda i: (f'<path {F(i)} d="M624 532C540 540 470 604 446 700 500 650 556 624 604 618 590 604 572 600 556 600 590 584 616 560 624 532Z"/>'
                        f'<path {S(i, 16)} d="M446 700 420 736"/>'),
    # Design, wallpapers, assets: what you make look good
    "palette": lambda i: (f'<path {F(i)} fill-rule="evenodd" d="M512 528C574 528 628 572 628 628 628 664 600 674 576 668 552 662 540 680 552 700 566 724 548 736 512 736 454 736 396 690 396 630 396 572 450 528 512 528Z'
                          f'M466 600A20 20 0 1 0 466 601ZM520 572A20 20 0 1 0 520 573ZM574 604A20 20 0 1 0 574 605ZM456 664A20 20 0 1 0 456 665Z"/>'),
    "pen-tool": lambda i: (f'<path {S(i, 18)} d="M412 690C452 600 572 600 612 690"/><path {S(i, 14)} d="M452 600H572"/>'
                           + rr(496, 584, 32, 32, 6, F(i)) + f'<circle cx="452" cy="600" r="12" {F(i)}/><circle cx="572" cy="600" r="12" {F(i)}/>'
                           + rr(398, 676, 28, 28, 6, F(i)) + rr(598, 676, 28, 28, 6, F(i))),
    "shapes": lambda i: (f'<circle cx="452" cy="594" r="52" {F(i)}/>' + rr(520, 548, 104, 104, 18, S(i, 22))
                         + f'<path {F(i)} fill-opacity=".7" d="M512 616 572 728H452Z"/>'),
    "layers": lambda i: (f'<path {F(i)} fill-opacity=".45" d="M512 640 624 690 512 740 400 690Z"/><path {F(i)} fill-opacity=".7" d="M512 590 624 640 512 690 400 640Z"/>'
                         f'<path {F(i)} d="M512 540 624 590 512 640 400 590Z"/>'),
    "brush": lambda i: (f'<path {S(i)} d="M610 534 520 640"/><path {F(i)} d="M528 626C548 646 548 676 524 696 498 718 450 714 416 728 432 694 430 650 458 628 480 610 510 610 528 626Z"/>'),
    # Archive and backups: what you keep but rarely open
    "archive-box": lambda i: (rr(400, 540, 224, 54, 14, F(i)) + f'<path {S(i)} d="M420 606V716H604V606"/><path {S(i, 22)} d="M480 644H544"/>'),
    "trays": lambda i: (rr(452, 538, 150, 76, 14, F(i)) + rr(410, 630, 150, 90, 14, S(i, 24)) + rr(458, 664, 54, 18, 9, F(i))),
    "zip": lambda i: (f'<path {S(i, 14)} d="M512 528V600"/>' + "".join(rr(484 if k % 2 else 512, 532 + k * 26, 28, 16, 5, F(i)) for k in range(4))
                      + f'<path {S(i, 18)} d="M512 640 474 720M512 640 550 720"/>' + rr(490, 610, 44, 56, 12, F(i))),
    "padlock": lambda i: (f'<path {S(i)} d="M462 604V576C462 548 484 528 512 528S562 548 562 576V604"/>'
                         + f'<path {F(i)} fill-rule="evenodd" d="M434 604H590Q610 604 610 624V712Q610 732 590 732H434Q414 732 414 712V624Q414 604 434 604ZM500 648V690H524V648Z"/>'),
    "history": lambda i: (f'<path {S(i)} d="M428 600A100 100 0 1 1 420 672"/><path d="M394 572 444 610 396 634Z" {F(i)}/>'
                          f'<path {S(i, 22)} d="M512 580V634L548 656"/>'),
    "box-bold": lambda i: (rr(380, 548, 264, 72, 18, F(i)) + rr(400, 632, 224, 104, 16, F(i)) + rr(480, 656, 64, 22, 11, 'fill="#000" fill-opacity=".3"')),
    # Work and money: clients, invoices, taxes
    "briefcase": lambda i: (rr(396, 584, 232, 144, 22, S(i)) + f'<path {S(i)} d="M472 584V560C472 548 480 540 492 540H532C544 540 552 548 552 560V584"/>'
                            + f'<path {S(i, 18)} d="M396 642H628"/>'),
    "receipt": lambda i: f'<path {S(i)} d="M440 536H584V724L560 708 536 724 512 708 488 724 464 708 440 724Z"/><circle cx="512" cy="612" r="22" {F(i)}/>',
    "coins": lambda i: (f'<ellipse cx="512" cy="566" rx="92" ry="30" {F(i)}/>'
                        f'<path {S(i, 22)} d="M420 600C420 616 461 630 512 630S604 616 604 600M420 640C420 656 461 670 512 670S604 656 604 640M420 680C420 696 461 710 512 710S604 696 604 680"/>'),
    "chart": lambda i: ("".join(rr(404 + k * 60, 720 - h, 40, h, 10, F(i)) for k, h in enumerate((70, 110, 90, 170)))),
    "case-bold": lambda i: (rr(380, 580, 264, 156, 26, F(i)) + f'<path {S(i)} d="M470 580V552C470 540 478 532 490 532H534C546 532 554 540 554 552V580"/>'
                            + rr(490, 636, 44, 26, 8, 'fill="#000" fill-opacity=".3"')),
    # Data and models: datasets, model weights, caches
    "cylinder": lambda i: (f'<ellipse cx="512" cy="562" rx="96" ry="32" {S(i)}/><path {S(i)} d="M416 562V700C416 718 459 732 512 732S608 718 608 700V562M416 630C416 648 459 662 512 662S608 648 608 630"/>'),
    "network": lambda i: (f'<path {S(i, 12)} stroke-opacity=".7" d="M432 566 512 630 432 694M432 566 592 566M432 694 592 694M512 630 592 566M512 630 592 694M432 566 432 694"/>'
                          + "".join(f'<circle cx="{x}" cy="{y}" r="26" {F(i)}/>' for x, y in ((432, 566), (432, 694), (512, 630), (592, 566), (592, 694)))),
    "sparkle": lambda i: (f'<path {F(i)} d="M492 540C500 600 520 620 580 630 520 640 500 660 492 720 484 660 464 640 404 630 464 620 484 600 492 540Z"/>'
                          f'<path {F(i)} d="M592 540C596 562 604 570 626 574 604 578 596 586 592 608 588 586 580 578 558 574 580 570 588 562 592 540Z"/>'),
    "matrix": lambda i: "".join(rr(424 + c * 48, 548 + r * 48, 32, 32, 8, F(i) + (' fill-opacity=".4"' if (c * 7 + r * 3) % 4 == 0 else ""))
                                for c in range(4) for r in range(4)),
    "cyl-bold": lambda i: (f'<path {F(i)} d="M400 566C400 540 450 522 512 522S624 540 624 566V700C624 726 574 744 512 744S400 726 400 700Z"/>'
                           f'<path fill="none" stroke="#000" stroke-opacity=".25" stroke-width="10" d="M400 566C400 592 450 610 512 610S624 592 624 566M400 634C400 660 450 678 512 678S624 660 624 634"/>'),
    # Redraws of today's text-like marks
    "code-branch": lambda i: (f'<circle cx="452" cy="562" r="26" {S(i, 22)}/><circle cx="452" cy="700" r="26" {S(i, 22)}/><circle cx="574" cy="590" r="26" {S(i, 22)}/>'
                              f'<path {S(i, 22)} d="M452 588V674M574 616C574 652 540 662 486 690"/>'),
    "term-window": lambda i: (rr(392, 548, 240, 168, 22, S(i)) + "".join(f'<circle cx="{424 + k * 26}" cy="578" r="9" {F(i)}/>' for k in range(3))
                              + rr(424, 626, 26, 52, 6, F(i))),
    "paper-clip": lambda i: f'<path {S(i)} d="M560 586V672C560 712 536 734 506 734S452 712 452 672V570C452 546 470 530 492 530S532 546 532 570V664C532 680 522 690 508 690S486 680 486 664V590"/>',
}

# The pattern treatment's tile: a 64 x 64 cell, drawn at low opacity across the whole front.
TILES = {
    "applications": lambda i: rr(18, 18, 28, 28, 8, F(i)),
    "desktop": lambda i: rr(12, 18, 40, 28, 6, S(i, 5)),
    "documents": lambda i: f'<path {S(i, 5)} d="M20 14H38L46 22V50H20Z"/>',
    "downloads": lambda i: f'<path {S(i, 6)} d="M22 26 32 36 42 26"/>',
    "pictures": lambda i: f'<path {F(i)} d="M10 46 24 30 34 40 40 34 54 46Z"/>',
    "screenshots": lambda i: f'<path {S(i, 4)} stroke-dasharray="8 8" d="M0 32H64"/>',
    "movies": lambda i: rr(4, 8, 14, 18, 3, F(i)) + rr(46, 8, 14, 18, 3, F(i)),
    "music": lambda i: f'<path {S(i, 5)} d="M0 32C16 16 16 48 32 32S48 16 64 32"/>',
    "public": lambda i: f'<circle cx="32" cy="32" r="10" {S(i, 5)}/>',
    "icloud": lambda i: f'<path {F(i)} d="M22 42H44C50 42 54 38 54 33S50 25 44 26C42 20 37 17 32 17 25 17 21 22 20 27 15 28 12 31 12 35 12 39 16 42 22 42Z"/>',
    "code": lambda i: f'<path {S(i, 4)} d="M0 20H24L34 30H64M32 64V44"/><circle cx="34" cy="30" r="5" {F(i)}/>',
    "notes": lambda i: f'<circle cx="32" cy="32" r="4" {F(i)}/>',
    "design": lambda i: f'<circle cx="16" cy="16" r="7" {F(i)}/><path {F(i)} d="M48 40 56 54H40Z"/>',
    "archive": lambda i: rr(6, 10, 20, 12, 3, F(i)) + rr(38, 42, 20, 12, 3, F(i)),
    "work": lambda i: f'<path {S(i, 4)} d="M-16 64 64 -16M16 80 80 0"/>',
    "data": lambda i: rr(10, 10, 18, 18, 4, F(i)) + rr(36, 36, 18, 18, 4, F(i)),
}


def rgb(c):
    return [int(c[i:i + 2], 16) for i in (1, 3, 5)]


def mix(a, b, t):
    """a toward b by t."""
    return "#" + "".join(f"{round(x + (y - x) * t):02X}" for x, y in zip(rgb(a), rgb(b)))


W, K = "#FFFFFF", "#000000"

# kind: title, palette (main, light, deep, accent), marks per treatment (pour, smoke, pattern, emboss, bold)
KINDS = {
    "applications": ("Applications", ("#3D7BFF", "#9CC4FF", "#1736A8", "#8A5CFF"), ("app-grid", "rocket", "app-squircle", "compass", "app-stack")),
    "desktop": ("Desktop", ("#25AFC6", "#A6EEF2", "#0E5C7A", "#FF9F5A"), ("display", "windows", "dock", "pointer", "display-wide")),
    "documents": ("Documents", ("#5B7FA6", "#DCE6F2", "#2A3F5C", "#F2C14E"), ("page-fold", "page-stack", "page-tab", "paperclip", "page-corner")),
    "downloads": ("Downloads", ("#18B47A", "#A8F0CF", "#0B6146", "#2DA8FF"), ("down-tray", "down-arrow", "down-chevrons", "down-circle", "down-bold")),
    "pictures": ("Pictures", ("#FF7A59", "#FFD2B8", "#A62F3A", "#FFC93D"), ("hills", "camera", "photos", "bloom", "sun-hill")),
    "screenshots": ("Screenshots", ("#A65CFF", "#E2C9FF", "#4B1E99", "#3DE0FF"), ("marquee", "viewfinder", "crosshair", "snap", "frame-corner")),
    "movies": ("Movies", ("#E5383B", "#FFB3A7", "#5C0A14", "#FFC233"), ("clapper", "play", "filmstrip", "reel", "play-bold")),
    "music": ("Music", ("#FF3D8B", "#FFC1DA", "#6A0B45", "#8A5CFF"), ("wave-bars", "headphones", "eq", "vinyl", "eighth")),
    "public": ("Public", ("#7DBB35", "#E2F5C2", "#3E6B12", "#3DB5FF"), ("people", "broadcast", "globe", "drop-tray", "share-nodes")),
    "icloud": ("iCloud Drive", ("#4AA8FF", "#DDF0FF", "#1B5FB8", "#7CE0FF"), ("cloud", "cloud-sync", "cloud-up", "cloud-sun", "cloud-fill")),
    "code": ("Code", ("#3550E0", "#A9B8FF", "#0F1A52", "#3BEA9C"), ("cube", "bug", "flow", "chip", "hex")),
    "notes": ("Notes", ("#F0A92E", "#FFE9B0", "#8A5A0B", "#E0533F"), ("nib", "pencil", "spiral", "bookmark", "quill")),
    "design": ("Design", ("#FF5CA8", "#FFD1E6", "#5A1BA8", "#2EE6C9"), ("palette", "pen-tool", "shapes", "brush", "layers")),
    "archive": ("Archive", ("#8C7B65", "#E8DCC8", "#3E352A", "#C9A15A"), ("archive-box", "history", "padlock", "trays", "box-bold")),
    "work": ("Work", ("#2F5E8E", "#BFD3E8", "#0F2440", "#E8B04A"), ("briefcase", "receipt", "chart", "coins", "case-bold")),
    "data": ("Data and models", ("#16B8A6", "#B6F5EC", "#08343A", "#C6F432"), ("cylinder", "network", "matrix", "sparkle", "cyl-bold")),
}
TREATMENTS = ("pour", "smoke", "pattern", "emboss", "bold")


def design(kind, t):
    _, (main, light, deep, accent), names = KINDS[kind]
    m = MARKS[names[TREATMENTS.index(t)]]
    tile = TILES[kind]
    key = f"{kind}-{t}"
    if t == "pour":
        d = dict(base=deep, blobs=[(main, 280, 320, 320, 200), (light, 760, 290, 240, 150), (mix(deep, main, .5), 760, 740, 360, 220),
                                   (accent, 220, 780, 240, 150)],
                 paper=(W, mix(light, W, .6)), glass=(mix(light, W, .7), .26, .08), swirl=100, sheets=2)
        KIND_MOTIFS[key] = lambda small: ("", m(W))
    elif t == "smoke":
        ink = mix(accent, W, .25)
        d = dict(base=mix(deep, K, .75), blobs=[(mix(main, K, .2), 300, 330, 260, 150), (mix(deep, K, .4), 720, 320, 320, 180),
                                                  (accent, 800, 760, 170, 90), (mix(deep, K, .6), 240, 760, 300, 200)],
                 paper=(mix(light, W, .5), mix(light, "#BBBBBB", .5)), glass=(mix(deep, K, .85), .48, .62), swirl=90, dark=True,
                 rim=accent, sheets=1)
        KIND_MOTIFS[key] = lambda small: ("", m(ink))
    elif t == "pattern":
        d = dict(base=main, blobs=[(light, 280, 320, 320, 200), (mix(light, W, .5), 760, 290, 240, 150), (main, 760, 740, 360, 220),
                                   (mix(main, deep, .4), 220, 780, 260, 170)],
                 paper=(W, mix(light, W, .5)), glass=(W, .24, .10), swirl=80, sheets=0)
        pattern = (f'<defs><pattern id="tile" width="64" height="64" patternUnits="userSpaceOnUse" x="8" y="8">{tile(W)}</pattern></defs>'
                   f'<path d="{FRONT}" fill="url(#tile)" opacity=".34"/>')
        KIND_MOTIFS[key] = lambda small: ("" if small else pattern, m(W))
    elif t == "emboss":
        tone = mix(main, W, .5)
        d = dict(base=mix(main, W, .2), blobs=[(mix(main, W, .65), 280, 320, 320, 200), (mix(main, W, .85), 760, 290, 240, 150),
                                              (main, 760, 740, 360, 220), (mix(main, W, .4), 220, 780, 260, 170)],
                 paper=(W, mix(light, W, .7)), glass=(mix(tone, W, .6), .46, .34), swirl=40, sheets=3)
        ink = mix(deep, main, .25)
        KIND_MOTIFS[key] = lambda small: ("", f'<g transform="translate(0 5)" opacity=".75">{m(W)}</g><g opacity="{.8 if small else .62}">{m(ink)}</g>')
    else:  # bold
        d = dict(base=mix(main, deep, .35), blobs=[(accent, 300, 320, 360, 220), (main, 760, 300, 280, 170), (light, 780, 760, 220, 130),
                                                    (mix(main, deep, .6), 220, 780, 300, 190)],
                 paper=(W, W), glass=(mix(light, W, .6), .16, .04), swirl=120, sheets=0)
        big = (f'<g clip-path="url(#front)" opacity=".92"><g transform="translate(600 690) scale(2.4) translate(-512 -630)">{m(W)}</g></g>')
        KIND_MOTIFS[key] = lambda small: (("", m(W)) if small else (big, ""))
    d["motif"] = key
    return d

# Sven's picks per kind (folder-designs-variants.build.md); FolderDesign.kinds keeps this order.
PICKS = {
    "applications": ("pour", "smoke", "emboss"),
    "desktop": ("pour", "pattern", "emboss"),
    "documents": ("pour", "smoke", "pattern", "emboss", "bold"),
    "downloads": ("pour", "pattern", "emboss"),
    "pictures": ("smoke", "pattern", "emboss", "bold"),
    "screenshots": ("pour", "smoke", "pattern", "emboss"),
    "movies": ("pour", "pattern", "emboss"),
    "music": ("pour", "smoke", "pattern", "bold"),
    "public": ("pour", "smoke", "pattern", "emboss"),
    "icloud": ("pour", "smoke", "pattern", "emboss"),
    "code": ("pour", "emboss"),
    "notes": ("smoke", "pattern", "emboss"),
    "design": ("pour", "pattern", "bold"),
    "archive": ("pour", "smoke", "emboss", "bold"),
    "work": ("pour", "smoke", "pattern"),
    "data": ("emboss", "bold"),
}
KIND_MOTIFS = {}  # <kind>-<treatment>: small -> (texture across the front, mark)
DESIGNS.update({f"{kind}-{t}": design(kind, t) for kind, picked in PICKS.items() for t in picked})


def motif(kind, ink, small=False):
    """The design's mark and any texture across the front (extra), the mark centred on the glass in one box (about 240 x 180 round 512, 630), one stroke weight: paths,
    never text. Big enough to survive at 32 px, where it is most of what tells two designs of one colour apart. A kind's
    design draws its own (KIND_MOTIFS), plainer when `small`."""
    if kind in KIND_MOTIFS:
        return KIND_MOTIFS[kind](small)
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
    extra, mark = motif(d.get("motif"), d.get("ink", "#FFFFFF"), small)
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


BUDGET = 4600 * 1024  # what the set may add to the app: the 13 (P54, 1.0 MB) and the kinds' 54 (T61, 3.4 MB; Sven raised it, Q862)
DISPLAY = 256  # the grid and menu rows draw <id>.png, never above 128 pt at 2x; decoded it is 256 KB, not the 4 MB of 1024
# HEIC quality: 60 looks the same as 85 at 512 px and below and is a quarter smaller (T61); today's 13 were written at 85.
QUALITY = 60


def squeeze(path):
    """Recompresses a PNG losslessly (oxipng), the art as it was."""
    path.write_bytes(oxipng.optimize_from_memory(path.read_bytes(), level=6, strip=oxipng.StripChunks.safe(), optimize_alpha=True))


def main(ids):
    OUT.mkdir(parents=True, exist_ok=True)
    for name in ids or DESIGNS:
        art = Image.open(io.BytesIO(bytes(resvg_py.svg_to_bytes(svg_string=svg(DESIGNS[name]))))).convert("RGBA")
        small = Image.open(io.BytesIO(bytes(resvg_py.svg_to_bytes(svg_string=svg(DESIGNS[name], True))))).convert("RGBA")
        # The full art, which dresses a folder: HEIC keeps alpha at a tenth of PNG's size (sips, macOS's own encoder).
        with tempfile.TemporaryDirectory() as tmp:
            art.save(Path(tmp) / "art.png")
            subprocess.run(["sips", "-s", "format", "heic", "-s", "formatOptions", str(QUALITY), str(Path(tmp) / "art.png"),
                            "--out", str(OUT / f"{name}.heic")], check=True, capture_output=True)
        art.resize((DISPLAY, DISPLAY), Image.LANCZOS).save(OUT / f"{name}.png", optimize=True)
        # The 64 px drawing in 256 colours: at 32 px and under a palette is unseen, and it fits one 4 KB disk block.
        small.resize((64, 64), Image.LANCZOS).quantize(256, method=Image.Quantize.FASTOCTREE).save(OUT / f"{name}-small.png", optimize=True)
        for png in (f"{name}.png", f"{name}-small.png"):
            squeeze(OUT / png)
        print(name, sum((OUT / f).stat().st_size for f in (f"{name}.heic", f"{name}.png", f"{name}-small.png")) // 1024, "KB")
    total = sum(f.stat().st_size for f in OUT.iterdir())
    print(f"set {total / 1024:.0f} KB of {BUDGET // 1024} KB")
    if total > BUDGET:
        sys.exit("over the size budget")


if __name__ == "__main__":
    main(sys.argv[1:])
