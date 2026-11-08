# /// script
# requires-python = ">=3.11"
# dependencies = ["fonttools>=4.50"]
# ///
"""Draw the S|R logo from the Prompt It Yourself logo: the same tile, bar and smile
(https://promptityourself.com/media/), with S and R in place of P and Y, in the same
font and weight. Run again only when the PIY logo changes:

    uv run tools/make-logo.py

Writes Resources/icon.svg (the tile, with macOS's corner radius) and, for the menu bar,
Resources/tile.svg (the tile as published) and Resources/face.svg (the face alone). It first redraws PIY's own P and Y the same way and
stops if they do not match the published logo, so a changed font or logo cannot slip through.
"""
import json
import re
import sys
import urllib.request
from pathlib import Path

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

SITE = "https://promptityourself.com"
OUT = Path(__file__).resolve().parent.parent / "Resources"
WEIGHT = 800  # the logo's letters: the brand's "title" weight


def fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "piy-screen-it-recorder make-logo"})
    with urllib.request.urlopen(req) as r:
        return r.read()


brand = json.loads(fetch(f"{SITE}/api/brand.json"))
tile = fetch(f"{SITE}/media/logo/piy-tile.svg").decode()
font_path = Path(sys.argv[0]).with_name(".font.ttf")
font_path.write_bytes(fetch(brand["type"]["fonts"]["text"]["file"]))
font = instantiateVariableFont(TTFont(font_path), {"wght": WEIGHT})
font_path.unlink()
glyphs = font.getGlyphSet()
cmap = font.getBestCmap()


def glyph(ch: str) -> tuple[str, float]:
    """SVG path data in font units, and the x centre of its outline."""
    g = glyphs[cmap[ord(ch)]]
    pen, box = SVGPathPen(glyphs), BoundsPen(glyphs)
    g.draw(pen)
    g.draw(box)
    x0, _, x1, _ = box.bounds
    return pen.getCommands(), (x0 + x1) / 2


# Each letter in the PIY tile: <g transform="translate(CX 36) …"><path … transform="translate(X 53) scale(K -K)" d="…"/>
letter = re.compile(r'(<g transform="translate\(([\d.]+) 36\)[^"]*"><path fill="#0f0f10" transform="translate\()'
                    r'([\d.]+) 53\) scale\(([\d.]+) -[\d.]+\)" d="([^"]+)"')
found = letter.findall(tile)
if len(found) != 2:
    sys.exit(f"expected 2 letters in piy-tile.svg, found {len(found)}: the logo changed, update this script")


def numbers(d: str) -> list[float]:
    return [float(n) for n in re.findall(r"-?[\d.]+", d)]


# Positive control: our P and Y must be the published ones.
for (_, cx, x, k, d), ch in zip(found, "PY"):
    ours, centre = glyph(ch)
    a, b = numbers(ours), numbers(d)
    if len(a) != len(b) or max(abs(p - q) for p, q in zip(a, b)) > 1.5:
        sys.exit(f"{ch} from the font does not match the published logo: the font or logo changed")
    if abs(float(x) + centre * float(k) - float(cx)) > 0.05:
        sys.exit(f"{ch} is not centred the way this script assumes")
print("control: P and Y from the font match the published logo")


def swap(svg: str) -> str:
    for (_, cx, x, k, d), ch in zip(found, "SR"):
        path, centre = glyph(ch)
        new_x = float(cx) - centre * float(k)
        svg = svg.replace(f"translate({x} 53) scale({k} -{k})\" d=\"{d}\"",
                          f"translate({new_x:.3f} 53) scale({k} -{k})\" d=\"{path}\"")
    return svg.replace("Prompt It Yourself", "Screen It Recorder")


sr = swap(tile)
if sr.count("Screen It Recorder") != 2 or any(d in sr for *_, d in found):
    sys.exit("could not swap the letters")

# The app icon: macOS's grid wants a 22.5% corner radius (185 px on an 824 px tile); PIY's is 17%.
icon = sr.replace('rx="17"', 'rx="22.5"')
assert icon != sr
(OUT / "icon.svg").write_text(icon + "\n")

# The menu bar: the brand tile (PIY's corner radius) while idle; the face alone, on a tile
# the app fills red, while recording. Both in the tile's 100×100 frame, so they line up.
(OUT / "tile.svg").write_text(sr + "\n")
face = re.search(r'<g transform="translate\(5 5\) scale\(\.9\)">.*</g></g>', sr).group(0)[: -len("</g>")]
(OUT / "face.svg").write_text(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" role="img" aria-label="Screen It Recorder">'
    f"<title>Screen It Recorder</title>{face}</svg>\n")
print(f"wrote icon.svg, tile.svg and face.svg in {OUT}")
