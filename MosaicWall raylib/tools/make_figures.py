"""make_figures.py - builds the SVG figures used by SPEC_MosaicWallpaper.md.

Usage (from the project folder):
    python tools/make_figures.py

Reads docs/data/reference_analysis.json and docs/data/render_analysis.json
(produced by tools/analyze_image.ps1) and writes docs/img/fig_*.svg.
Swatches show measured colours literally; the hue-group charts use a validated
4-colour categorical palette (blue / purple-magenta / warm / fresh) + neutral for gaps.
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, 'docs', 'data')
IMG = os.path.join(ROOT, 'docs', 'img')

FONT = "Leelawadee UI, Tahoma, Segoe UI, sans-serif"
INK, INK2, MUTED, GRID, SURF = '#0b0b0b', '#52514e', '#8a8984', '#e4e3df', '#fcfcfb'
ZONES = [(0, 45, 'Z0 Cool'), (45, 62, 'Z1 Transition'), (62, 80, 'Z2 Warm'), (80, 100, 'Z3 Bloom')]

# hue groups: (key, label, colour, member classes)
GROUPS = [
    ('gap', 'Gap / grey', '#77767a', ['gap', 'grey']),
    ('blue', 'Blue', '#2a78d6', ['blue']),
    ('purple', 'Purple-magenta', '#d55181', ['violet', 'magenta']),
    ('warm', 'Warm (red-orange)', '#eda100', ['red', 'orange']),
    ('fresh', 'Fresh (yellow-green)', '#008300', ['yellow', 'green']),
]


def load(name):
    with open(os.path.join(DATA, name), encoding='utf-8') as f:
        return json.load(f)


def svg(w, h, body, title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" '
            f'font-family="{FONT}" role="img" aria-label="{title}">\n'
            f'<title>{title}</title>\n<rect width="{w}" height="{h}" fill="{SURF}"/>\n{body}\n</svg>\n')


def text(x, y, s, size=12, fill=INK2, anchor='start', weight='normal'):
    s = str(s).replace('&', '&amp;').replace('<', '&lt;')
    return f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" text-anchor="{anchor}" font-weight="{weight}">{s}</text>'


def save(name, content):
    with open(os.path.join(IMG, name), 'w', encoding='utf-8') as f:
        f.write(content)
    print('wrote docs/img/' + name)


def grouped(classes):
    return [sum(classes.get(c, 0) for c in g[3]) for g in GROUPS]


# ---------------------------------------------------------------- fig 1: band colour strips
def fig_band_strip(ref, ren):
    rows, rh, top = 20, 24, 84
    w, h = 760, top + rows * rh + 40
    b = [text(20, 28, 'Average colour per 5 % of height - reference vs render', 16, INK, weight='bold'),
         text(20, 48, 'Swatch = measured mean RGB of the band. Gap = pixels with V < 0.12, vivid = S > 0.5 and V > 0.55.', 12, MUTED)]
    cols = [(70, 'Reference'), (230, 'Render (seed 653)')]
    for x, lab in cols:
        b.append(text(x + 60, top - 8, lab, 12, INK, 'middle', 'bold'))
    b.append(text(420, top - 8, 'gap %  ref / render', 12, INK, 'middle', 'bold'))
    b.append(text(600, top - 8, 'vivid %  ref / render', 12, INK, 'middle', 'bold'))
    for i in range(rows):
        y = top + i * rh
        rb, nb = ref['bands'][i], ren['bands'][i]
        b.append(text(58, y + 16, f"{rb['y0']:.0f}%", 11, MUTED, 'end'))
        b.append(f'<rect x="70" y="{y}" width="120" height="{rh - 2}" fill="{rb["hex"]}"/>')
        b.append(f'<rect x="230" y="{y}" width="120" height="{rh - 2}" fill="{nb["hex"]}"/>')
        b.append(text(130, y + 16, rb['hex'], 10, '#ffffff', 'middle'))
        b.append(text(290, y + 16, nb['hex'], 10, '#ffffff', 'middle'))
        b.append(text(420, y + 16, f"{rb['gapPct']:.1f}  /  {nb['gapPct']:.1f}", 11, INK2, 'middle'))
        b.append(text(600, y + 16, f"{rb['vividPct']:.1f}  /  {nb['vividPct']:.1f}", 11, INK2, 'middle'))
    for z0, z1, lab in ZONES:
        y = top + z0 / 5 * rh - 1
        if z0 > 0:
            b.append(f'<line x1="66" x2="740" y1="{y}" y2="{y}" stroke="{INK}" stroke-width="1" stroke-dasharray="4 3"/>')
        b.append(text(740, y + 14, lab, 11, INK, 'end', 'bold'))
    b.append(text(20, h - 14, 'Dashed lines: zone boundaries used by the generator (45 / 62 / 80 %).', 11, MUTED))
    save('fig_band_strip.svg', svg(w, h, '\n'.join(b), 'Average colour per band, reference vs render'))


# ---------------------------------------------------------------- fig 2: hue groups by height
def fig_hue_by_height(ref, ren):
    rows, rh, top, pw = 20, 22, 108, 300
    w, h = 760, top + rows * rh + 46
    b = [text(20, 28, 'Hue groups by height (share of pixels, %)', 16, INK, weight='bold'),
         text(20, 48, 'Each bar = 5 % of the image height, top to bottom. Same scale in both panels.', 12, MUTED)]
    # legend, one row above the plots
    lx = 20
    for key, lab, col, _ in GROUPS:
        b.append(f'<rect x="{lx}" y="62" width="12" height="12" rx="2" fill="{col}"/>')
        b.append(text(lx + 18, 72, lab, 12, INK2))
        lx += 30 + len(lab) * 6.6
    for pi, (data, lab, x0) in enumerate([(ref, 'Reference', 60), (ren, 'Render (seed 653)', 420)]):
        b.append(text(x0, top - 8, lab, 12, INK, weight='bold'))
        for i in range(rows):
            y = top + i * rh
            vals = grouped(data['bands'][i]['classes'])
            x = x0
            for (key, _, col, _), v in zip(GROUPS, vals):
                ww = pw * v / 100
                if ww >= 0.5:
                    # 2 px surface gap between stacked segments
                    b.append(f'<rect x="{x:.1f}" y="{y}" width="{max(ww - 2, 0.5):.1f}" height="{rh - 4}" fill="{col}"/>')
                x += ww
            if pi == 0:
                b.append(text(x0 - 6, y + 13, f"{data['bands'][i]['y0']:.0f}%", 10, MUTED, 'end'))
        for z0, _, _ in ZONES[1:]:
            yy = top + z0 / 5 * rh - 2
            b.append(f'<line x1="{x0 - 4}" x2="{x0 + pw + 4}" y1="{yy}" y2="{yy}" stroke="{INK}" stroke-width="1" stroke-dasharray="4 3"/>')
        for t in (0, 50, 100):
            b.append(text(x0 + pw * t / 100, top + rows * rh + 12, f'{t}%', 10, MUTED, 'middle'))
    b.append(text(20, h - 10, 'Exact values: docs/data/*_analysis.json, summarised in the table under this figure.', 11, MUTED))
    save('fig_hue_by_height.svg', svg(w, h, '\n'.join(b), 'Hue groups by height, reference vs render'))


# ---------------------------------------------------------------- fig 3: bottom left/right split
def fig_bottom_split(ref, ren):
    w, h, pw, ph, top = 760, 330, 300, 200, 80
    warm_c, fresh_c = '#d55181', '#008300'
    b = [text(20, 28, 'Bottom 20 %: warm vs fresh share across the width', 16, INK, weight='bold'),
         text(20, 48, 'Warm = red + magenta + orange, fresh = yellow + green (% of pixels in each 10 % column).', 12, MUTED)]
    for data, lab, x0 in [(ref, 'Reference', 60), (ren, 'Render (seed 653)', 430)]:
        b.append(text(x0, top - 12, lab, 12, INK, weight='bold'))
        for gy in (0, 25, 50, 75, 100):
            y = top + ph - ph * gy / 100
            b.append(f'<line x1="{x0}" x2="{x0 + pw}" y1="{y}" y2="{y}" stroke="{GRID}" stroke-width="1"/>')
            b.append(text(x0 - 6, y + 4, gy, 10, MUTED, 'end'))
        series = []
        for key, col in (('warm', warm_c), ('fresh', fresh_c)):
            pts = []
            for i, c in enumerate(data['bottomCols']):
                cl = c['classes']
                v = cl['red'] + cl['magenta'] + cl['orange'] if key == 'warm' else cl['yellow'] + cl['green']
                pts.append((x0 + pw * (i + 0.5) / 10, top + ph - ph * v / 100))
            series.append((key, col, pts))
            b.append('<polyline fill="none" stroke="%s" stroke-width="2" stroke-linejoin="round" points="%s"/>'
                     % (col, ' '.join(f'{x:.1f},{y:.1f}' for x, y in pts)))
            for x, y in pts:
                b.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4" fill="{col}" stroke="{SURF}" stroke-width="2"/>')
        # direct labels at the line ends (ink colour, swatch carries identity)
        for key, col, pts in series:
            xe, ye = pts[0] if key == 'warm' else pts[-1]
            anchor = 'start'
            b.append(text(xe + (8 if key == 'fresh' else -8), ye - 8, 'warm' if key == 'warm' else 'fresh', 11, INK,
                          'end' if key == 'warm' else anchor, 'bold'))
        for t in (0, 50, 100):
            b.append(text(x0 + pw * t / 100, top + ph + 16, f'{t}% of width', 10, MUTED, 'middle'))
    b.append(f'<rect x="20" y="{h - 30}" width="12" height="12" rx="2" fill="{warm_c}"/>')
    b.append(text(38, h - 20, 'Warm (red-pink-orange)', 12, INK2))
    b.append(f'<rect x="210" y="{h - 30}" width="12" height="12" rx="2" fill="{fresh_c}"/>')
    b.append(text(228, h - 20, 'Fresh (yellow-green)', 12, INK2))
    save('fig_bottom_split.svg', svg(w, h, '\n'.join(b), 'Bottom split warm vs fresh across width'))


# ---------------------------------------------------------------- fig 4: palettes
SPEC_PALETTE = [
    ('Background', [('BASE', '#06385D'), ('BASE_DARK', '#021929'), ('GAP', '#040509'), ('GAP2', '#0A0E17')]),
    ('Cool (Z0)', [('TEAL_BLUE', '#0B5A86'), ('SKY', '#3094C8'), ('STEEL', '#1D6490'), ('ROYAL', '#0631CE'), ('INDIGO', '#1C2894')]),
    ('Transition (Z1)', [('PURPLE', '#59096C'), ('PLUM', '#88235F'), ('MAGENTA', '#872A61'), ('VIOLET', '#432B77')]),
    ('Warm (Z2/Z3 left)', [('HOT_PINK', '#E2335E'), ('PINK_RED', '#F4202F'), ('CORAL', '#FA3155'), ('RED', '#E81D0C'), ('ORANGE', '#E3865B'), ('MUSTARD', '#BDBB0E')]),
    ('Fresh (Z3 right)', [('YELLOW', '#E9E23A'), ('LIME', '#B3F381'), ('LEAF', '#8BD250'), ('MINT', '#78BD7A'), ('PALE_GREEN', '#B0D5B3')]),
]


def fig_palette(ref):
    w = 760
    rows = ref['palette']
    top = 70
    h = top + len(rows) * 26 + 60 + len(SPEC_PALETTE) * 62 + 20
    b = [text(20, 28, 'Colour palette', 16, INK, weight='bold'),
         text(20, 48, 'A: k-means (k = 14) on 40 000 pixels of the reference. B: the constants used in uPalette.pas.', 12, MUTED),
         text(20, top - 6, 'A. Measured clusters (share of pixels, mean height in image)', 12, INK, weight='bold')]
    maxs = max(r['share'] for r in rows)
    for i, r in enumerate(rows):
        y = top + 6 + i * 26
        b.append(f'<rect x="20" y="{y}" width="40" height="20" rx="3" fill="{r["hex"]}" stroke="{GRID}"/>')
        b.append(text(70, y + 15, r['hex'], 12, INK2))
        b.append(f'<rect x="150" y="{y + 4}" width="{300 * r["share"] / maxs:.1f}" height="12" rx="2" fill="#2a78d6"/>')
        b.append(text(160 + 300 * r['share'] / maxs, y + 15, f"{r['share']:.1f} %", 11, INK2))
        b.append(text(560, y + 15, f"mean y {r['meanY']:.0f} %", 11, MUTED))
        b.append(text(660, y + 15, r['class'], 11, MUTED))
    y = top + 6 + len(rows) * 26 + 30
    b.append(text(20, y, 'B. Palette constants (HEX_* in uPalette.pas)', 12, INK, weight='bold'))
    y += 12
    for grp, items in SPEC_PALETTE:
        b.append(text(20, y + 16, grp, 11, INK2, weight='bold'))
        for j, (name, hx) in enumerate(items):
            x = 150 + j * 100
            b.append(f'<rect x="{x}" y="{y}" width="90" height="28" rx="3" fill="{hx}" stroke="{GRID}"/>')
            b.append(text(x, y + 42, name, 9, INK2))
            b.append(text(x + 90, y + 42, hx, 9, MUTED, 'end'))
        y += 62
    save('fig_palette.svg', svg(w, h, '\n'.join(b), 'Measured and specified palette'))


# ---------------------------------------------------------------- fig 5: zone map
def fig_zones(ref):
    fx, fy, fw, fh = 40, 70, 270, 480   # 9:16 frame
    w, h = 760, 590
    b = [text(20, 28, 'Zone map (9:16 frame)', 16, INK, weight='bold'),
         text(20, 48, 'Band fill = measured mean colour of the reference. Right: what the generator does per zone.', 12, MUTED)]
    for band in ref['bands']:
        y = fy + fh * band['y0'] / 100
        b.append(f'<rect x="{fx}" y="{y:.1f}" width="{fw}" height="{fh / 20 + 0.5:.1f}" fill="{band["hex"]}"/>')
    # bottom split hint
    b.append(f'<line x1="{fx + fw * 0.5}" x2="{fx + fw * 0.5}" y1="{fy + fh * 0.8}" y2="{fy + fh}" stroke="#ffffff" stroke-width="1.5" stroke-dasharray="5 4"/>')
    b.append(text(fx + fw * 0.25, fy + fh * 0.9 + 4, 'red / pink', 11, '#ffffff', 'middle', 'bold'))
    b.append(text(fx + fw * 0.75, fy + fh * 0.9 + 4, 'yellow / green', 11, '#ffffff', 'middle', 'bold'))
    b.append(f'<rect x="{fx}" y="{fy}" width="{fw}" height="{fh}" fill="none" stroke="{INK}" stroke-width="1.5"/>')
    info = [
        ('Z0 Cool', '0 - 45 %', 'accent density 25 %', 'BASE 70, TEAL 18, SKY 5, STEEL 4, ROYAL 3'),
        ('Z1 Transition', '45 - 62 %', 'accent density 42 %', 'BASE 50, TEAL 12, PURPLE/HOT_PINK/RED 10, ROYAL 8'),
        ('Z2 Warm', '62 - 80 %', 'accent density 72 %', 'BASE 30, PLUM/MAGENTA/HOT_PINK 15, CORAL 10, VIOLET 8, MUSTARD 7'),
        ('Z3 Bloom', '80 - 100 %', 'accent density 98 %', 'left: CORAL, PINK_RED, MAGENTA, RED, ORANGE / right: LIME, LEAF, YELLOW, MINT, MUSTARD, PALE_GREEN'),
    ]
    for (z0, z1, _), (name, rng, dens, pal) in zip(ZONES, info):
        ymid = fy + fh * (z0 + z1) / 200
        if z0 > 0:
            yb = fy + fh * z0 / 100
            b.append(f'<line x1="{fx - 6}" x2="{fx + fw + 20}" y1="{yb}" y2="{yb}" stroke="{INK}" stroke-width="1" stroke-dasharray="4 3"/>')
            b.append(text(fx - 10, yb + 4, f'{z0}%', 10, INK2, 'end'))
        b.append(f'<line x1="{fx + fw + 4}" x2="{fx + fw + 26}" y1="{ymid}" y2="{ymid}" stroke="{MUTED}"/>')
        b.append(text(fx + fw + 32, ymid - 10, f'{name}  ({rng})', 13, INK, weight='bold'))
        b.append(text(fx + fw + 32, ymid + 6, dens + ' - soft edges: smoothstep +/- 6 % + fbm noise', 11, INK2))
        # long palette lines wrap at the slash
        parts = pal.split(' / ')
        for k, p in enumerate(parts):
            b.append(text(fx + fw + 32, ymid + 22 + k * 14, p, 10, MUTED))
    b.append(text(20, h - 12, 'Weights are relative within a zone; "BASE" tiles blend into the background (muted, faint rim).', 11, MUTED))
    save('fig_zones.svg', svg(w, h, '\n'.join(b), 'Zone map'))


# ---------------------------------------------------------------- fig 6: tile anatomy
def fig_tile_anatomy():
    w, h = 760, 590
    col = '#E2335E'
    b = [text(20, 28, 'Anatomy of one accent tile (drawn back to front)', 16, INK, weight='bold'),
         text(20, 48, 'Each step is one draw call; a bridged pair shares rim and fill so it reads as one shape.', 12, MUTED)]
    steps = [
        ('1 Glow', ['radial sprite, size x2.4', 'additive blend, alpha 60', 'swells with the wave']),
        ('2 Shadow', ['offset +0.04 / +0.05 cell', 'black, alpha 90']),
        ('3 Rim', ['rect expanded 0.035 cell', 'tile colour x0.22, alpha 215']),
        ('4 Fill', ['rounded rect', 'roundness 0.40 - 0.65']),
        ('5 Inner shade', ['68 % x 62 % at top-left', '13 % lighter, alpha 150']),
        ('6 Glint', ['soft white sprite, alpha 70', '+ streak alpha 38', 'angle -25 to -55 deg']),
    ]
    for i, (name, lines) in enumerate(steps):
        cx = 130 + (i % 3) * 250
        cy = 140 + (i // 3) * 250
        s = 64
        b.append(f'<rect x="{cx - 70}" y="{cy - 70}" width="140" height="140" rx="8" fill="#06385D"/>')
        b.append(f'<circle cx="{cx}" cy="{cy}" r="62" fill="{col}" opacity="0.28"/>')
        if i >= 1:
            b.append(f'<rect x="{cx - s / 2 + 3}" y="{cy - s / 2 + 4}" width="{s}" height="{s}" rx="16" fill="#000000" opacity="0.35"/>')
        if i >= 2:
            b.append(f'<rect x="{cx - s / 2 - 3}" y="{cy - s / 2 - 3}" width="{s + 6}" height="{s + 6}" rx="19" fill="#320b15"/>')
        if i >= 3:
            b.append(f'<rect x="{cx - s / 2}" y="{cy - s / 2}" width="{s}" height="{s}" rx="16" fill="{col}"/>')
        if i >= 4:
            b.append(f'<rect x="{cx - s / 2 + 6}" y="{cy - s / 2 + 6}" width="{s * 0.68:.0f}" height="{s * 0.62:.0f}" rx="14" fill="#ec6f8f" opacity="0.75"/>')
        if i >= 5:
            b.append(f'<ellipse cx="{cx - 8}" cy="{cy - 10}" rx="12" ry="9" fill="#ffffff" opacity="0.35"/>')
            b.append(f'<line x1="{cx - 16}" y1="{cy - 2}" x2="{cx - 2}" y2="{cy - 18}" stroke="#ffffff" stroke-width="2.5" opacity="0.5" stroke-linecap="round"/>')
        b.append(text(cx, cy + 92, name, 13, INK, 'middle', 'bold'))
        for k, ln in enumerate(lines):
            b.append(text(cx, cy + 110 + k * 15, ln, 11, INK2, 'middle'))
    b.append(text(20, h - 14, 'Values from uMosaicRender.pas (DrawScene / DrawAccentGroup). Base-kind tiles use rim alpha 120, shade alpha 70.', 11, MUTED))
    save('fig_tile_anatomy.svg', svg(w, h, '\n'.join(b), 'Tile anatomy'))


if __name__ == '__main__':
    os.makedirs(IMG, exist_ok=True)
    ref = load('reference_analysis.json')
    ren = load('render_analysis.json')
    fig_band_strip(ref, ren)
    fig_hue_by_height(ref, ren)
    fig_bottom_split(ref, ren)
    fig_palette(ref)
    fig_zones(ref)
    fig_tile_anatomy()
