#!/usr/bin/env python3
"""Generate a self-contained SVG health badge — no third-party services.

Produces a shields-style flat badge like  [ postgres health | B · 87 ]
coloured by grade, so it works offline and never depends on shields.io.

Usage:
    python make_badge.py --score 87 --grade B --out pgvitals-badge.svg
    python make_badge.py --score 87 --grade B            # SVG to stdout
"""
from __future__ import annotations

import argparse
import sys

# Grade → colour (GitHub-ish palette)
GRADE_COLOR = {
    "A": "#2ea44f", "B": "#97ca00", "C": "#dfb317",
    "D": "#fe7d37", "F": "#e05d44",
}
_DEFAULT_COLOR = "#9f9f9f"


def _text_width(s: str) -> int:
    """Approximate Verdana-11 pixel width (good enough for badge layout)."""
    return int(len(s) * 6.7) + 10


def generate_badge(score: int, grade: str, label: str = "postgres health") -> str:
    grade = (grade or "?").strip().upper()[:1]
    value = f"{grade} · {score}"
    color = GRADE_COLOR.get(grade, _DEFAULT_COLOR)

    lw, rw = _text_width(label), _text_width(value)
    total = lw + rw
    # Text anchors are at segment centres, ×10 for the scale(.1) trick shields uses.
    lx, rx = lw * 10 // 2, lw * 10 + (rw * 10 // 2)

    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{total}" height="20" role="img" aria-label="{label}: {value}">
  <title>{label}: {value}</title>
  <linearGradient id="s" x2="0" y2="100%">
    <stop offset="0" stop-color="#bbb" stop-opacity=".1"/>
    <stop offset="1" stop-opacity=".1"/>
  </linearGradient>
  <clipPath id="r"><rect width="{total}" height="20" rx="3" fill="#fff"/></clipPath>
  <g clip-path="url(#r)">
    <rect width="{lw}" height="20" fill="#555"/>
    <rect x="{lw}" width="{rw}" height="20" fill="{color}"/>
    <rect width="{total}" height="20" fill="url(#s)"/>
  </g>
  <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="110" text-rendering="geometricPrecision">
    <text x="{lx}" y="150" fill="#010101" fill-opacity=".3" transform="scale(.1)" textLength="{(lw - 10) * 10}">{label}</text>
    <text x="{lx}" y="140" transform="scale(.1)" textLength="{(lw - 10) * 10}">{label}</text>
    <text x="{rx}" y="150" fill="#010101" fill-opacity=".3" transform="scale(.1)" textLength="{(rw - 10) * 10}">{value}</text>
    <text x="{rx}" y="140" transform="scale(.1)" textLength="{(rw - 10) * 10}">{value}</text>
  </g>
</svg>
'''


def main() -> int:
    p = argparse.ArgumentParser(description="Generate a pgvitals SVG health badge.")
    p.add_argument("--score", type=int, required=True, help="0-100 health score")
    p.add_argument("--grade", required=True, help="Letter grade A-F")
    p.add_argument("--label", default="postgres health", help="Left-hand label text")
    p.add_argument("--out", help="Output path (default: stdout)")
    args = p.parse_args()

    svg = generate_badge(args.score, args.grade, args.label)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(svg)
        print(f"Wrote {args.out}")
    else:
        sys.stdout.write(svg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
