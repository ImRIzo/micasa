"""Generates Micasa's app icon (Resources/icon/micasa.svg -> Resources/AppIcon.icns).

A macOS-style rounded-square tile with a six-petal colour pinwheel and a photo glyph
(sun over mountains) in the middle. Run: python3 make_icon.py  (needs cairosvg + Pillow)
"""
import io, math, os
import cairosvg
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
C = 512.0
R_OUT, R_IN = 300.0, 132.0
COLORS = ["#F0413A", "#FF8C1A", "#FFC915", "#30C062", "#1F8EF1", "#8B5CF0"]


def pt(r, deg):
    a = math.radians(deg - 90)
    return C + r * math.cos(a), C + r * math.sin(a)


def petal(i):
    t = i * 60.0
    a = pt(R_IN, t)               # inner start
    b = pt(R_OUT, t + 28)         # outer start (seam swirls clockwise)
    c = pt(R_OUT, t + 88)         # outer end
    d = pt(R_IN, t + 60)          # inner end
    q1 = pt((R_IN + R_OUT) / 2 + 22, t + 4)
    q2 = pt((R_IN + R_OUT) / 2 + 22, t + 64)
    return (f"M {a[0]:.2f} {a[1]:.2f} Q {q1[0]:.2f} {q1[1]:.2f} {b[0]:.2f} {b[1]:.2f} "
            f"A {R_OUT} {R_OUT} 0 0 1 {c[0]:.2f} {c[1]:.2f} "
            f"Q {q2[0]:.2f} {q2[1]:.2f} {d[0]:.2f} {d[1]:.2f} "
            f"A {R_IN} {R_IN} 0 0 0 {a[0]:.2f} {a[1]:.2f} Z")


petals = "\n".join(
    f'<path d="{petal(i)}" fill="url(#p{i})" stroke="#ffffff" stroke-width="9" stroke-linejoin="round"/>'
    for i in range(6))
petal_grads = "\n".join(
    f'<radialGradient id="p{i}" cx="512" cy="512" r="{R_OUT}" gradientUnits="userSpaceOnUse">'
    f'<stop offset="0.4" stop-color="{col}" stop-opacity="0.92"/><stop offset="1" stop-color="{col}"/></radialGradient>'
    for i, col in enumerate(COLORS))

SVG = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <title>Micasa</title>
  <defs>
    <linearGradient id="tile" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#E6E9EF"/>
    </linearGradient>
    <linearGradient id="hill1" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#5B6B82"/><stop offset="1" stop-color="#2E3A4C"/>
    </linearGradient>
    <linearGradient id="hill2" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#8A9BB3"/><stop offset="1" stop-color="#55667E"/>
    </linearGradient>
    <radialGradient id="sun" cx="0.4" cy="0.35" r="0.7">
      <stop offset="0" stop-color="#FFE27A"/><stop offset="1" stop-color="#FFB300"/>
    </radialGradient>
    <filter id="drop" x="-20%" y="-20%" width="140%" height="150%">
      <feDropShadow dx="0" dy="14" stdDeviation="16" flood-color="#000" flood-opacity="0.28"/>
    </filter>
    <filter id="soft" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="6" stdDeviation="10" flood-color="#000" flood-opacity="0.22"/>
    </filter>
    <clipPath id="lens"><circle cx="512" cy="512" r="{R_IN - 14}"/></clipPath>
    {petal_grads}
  </defs>
  <!-- macOS icon grid: 824 x 824 tile, 100 px margin -->
  <rect x="100" y="100" width="824" height="824" rx="185" ry="185" fill="url(#tile)" filter="url(#drop)"/>
  <rect x="101" y="101" width="822" height="822" rx="184" ry="184" fill="none" stroke="#000" stroke-opacity="0.06" stroke-width="2"/>
  <g filter="url(#soft)">
    {petals}
  </g>
  <circle cx="512" cy="512" r="{R_IN - 4}" fill="#FFFFFF" filter="url(#soft)"/>
  <g clip-path="url(#lens)">
    <rect x="380" y="380" width="264" height="264" fill="#EAF4FF"/>
    <circle cx="552" cy="470" r="34" fill="url(#sun)"/>
    <path d="M 370 600 L 455 495 Q 462 487 470 495 L 520 552 L 548 522 Q 556 514 564 522 L 660 620 L 660 660 L 370 660 Z" fill="url(#hill2)"/>
    <path d="M 370 640 L 430 560 Q 438 550 446 560 L 520 640 L 580 586 Q 588 579 596 586 L 660 640 L 660 660 L 370 660 Z" fill="url(#hill1)"/>
  </g>
  <circle cx="512" cy="512" r="{R_IN - 14}" fill="none" stroke="#FFFFFF" stroke-width="3"/>
</svg>
'''

with open(os.path.join(HERE, "micasa.svg"), "w") as f:
    f.write(SVG)

png = cairosvg.svg2png(bytestring=SVG.encode(), output_width=1024, output_height=1024)
base = Image.open(io.BytesIO(png)).convert("RGBA")
base.save(os.path.join(HERE, "micasa-1024.png"))
sizes = [(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)]
base.save(os.path.join(HERE, "..", "AppIcon.icns"), sizes=sizes)
print("wrote micasa.svg, micasa-1024.png, AppIcon.icns")
