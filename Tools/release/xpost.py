#!/usr/bin/env python3
"""One image and one post per TestFlight build.

    xpost.py <build> <notes.txt> [--icon icon.png] [--out dir] [--version 1.1]

Reads the What-to-Test notes (the "Fixed in this build" / "Changed in this build" groups, plus an
optional "Coming next" group written for the card), draws a
1600x900 card with the Vory cloud, "TestFlight build N" and the bullets, and prints a post for X:
a short one that fits 280 characters and a longer one. Needs Pillow and numpy. The icon is a 2048 px render
of Shared/AppIcon.icon (ictool --rendition Default / Dark); pass --icon to use another.
"""
import argparse, os, re, sys, textwrap
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SITE = "vory.dev"

def font(size, bold=False):
    for path, idx in [("/System/Library/Fonts/SFCompact.ttf", 0), ("/System/Library/Fonts/HelveticaNeue.ttc", 1 if bold else 0),
                      ("/System/Library/Fonts/Supplemental/Arial.ttf", 0)]:
        try:
            f = ImageFont.truetype(path, size, index=idx)
            if path.endswith("SFCompact.ttf"):
                try: f.set_variation_by_name("Bold" if bold else "Regular")
                except Exception: pass
            return f
        except Exception:
            continue
    return ImageFont.load_default()

def sections(notes: str) -> dict:
    """{'Fixed in this build': [bullet, …], 'Changed in this build': [...]}."""
    # A heading is any non-bullet line; bullets belong to the last heading. Blank lines mean
    # nothing (the notes keep one between bullets for legibility).
    out, current = {}, None
    for line in notes.splitlines():
        s = line.strip()
        if not s:
            continue
        if s.startswith("•"):
            if current is not None: out.setdefault(current, []).append(s.lstrip("• ").strip())
        else:
            current = s
    return out

def short(b: str, limit: int = 120) -> str:
    """The first clause of a bullet, for the card."""
    b = re.split(r"(?<=[a-z0-9)]):\s|;\s", b, maxsplit=1)[0]
    # a trailing aside ("…, for anyone who…", "…, so that…") goes too once the point is made
    m = re.match(r"(.{40,}?),\s(?:for|so|which|instead)\b.*", b)
    if m: b = m.group(1)
    b = re.sub(r"\s*\([^)]*\)", "", b).rstrip(".")
    return b if len(b) <= limit else b[:limit - 1].rsplit(" ", 1)[0] + "…"

def wrap(d, text, f, width):
    words, lines, cur = text.split(), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if d.textlength(t, font=f) <= width: cur = t
        else: lines.append(cur); cur = w
    if cur: lines.append(cur)
    return lines

PALETTES = {
    # background, glow 1, glow 2, headline, body, muted, accent, shadow alpha
    "dark":  ((9, 10, 16), (20, 60, 120), (50, 22, 90), (245, 245, 250), (228, 229, 238), (150, 152, 168), (120, 160, 255), 160),
    "light": ((246, 247, 251), (200, 222, 255), (232, 214, 250), (18, 20, 30), (40, 42, 56), (112, 116, 134), (31, 110, 210), 48),
}

def background(W, H, bg, g1, g2, seed=7):
    """Two soft colour blobs on the base, computed in float and dithered: a blurred 8-bit
    gradient shows visible bands on a phone; ±1 level of noise hides the steps."""
    import numpy as np
    y, x = np.mgrid[0:H, 0:W].astype(np.float32)
    base = np.array(bg, np.float32)[None, None, :]
    img = np.broadcast_to(base, (H, W, 3)).copy()
    for (cx, cy, r), col in (((0.10, 0.08, 0.62), g1), ((0.95, 0.95, 0.70), g2)):
        d2 = ((x / W - cx) ** 2 + ((y / H - cy) * H / W) ** 2) / (r * r)
        w = np.exp(-d2 * 1.8)[:, :, None]
        img = img * (1 - w) + np.array(col, np.float32)[None, None, :] * w
    # TPDF dither: ±1 level, triangular, the standard for hiding quantisation steps without
    # visible grain (Gaussian noise at 2 levels read as texture on the phone).
    rng = np.random.default_rng(seed)
    img += (rng.uniform(-0.5, 0.5, img.shape) + rng.uniform(-0.5, 0.5, img.shape)).astype(np.float32)
    return Image.fromarray(np.clip(img + 0.5, 0, 255).astype(np.uint8), "RGB")

def smoothed(rgba, target):
    """The glass gradient in the 8-bit icon render steps by several levels at a time. A small
    blur of the colour at full render size (2048) spreads each step over a few pixels, and the
    4x downsample then averages them away; the outline and eyes lose under a pixel of edge."""
    r, g, b, a = rgba.split()
    rgb = Image.merge("RGB", (r, g, b)).filter(ImageFilter.GaussianBlur(3.5))
    out = Image.merge("RGBA", (*rgb.split(), a))
    return out.resize((target, target), Image.LANCZOS)

def render(build, version, groups, icon_path, out_path, theme="light", scale=1.5):
    """A 4:5 portrait card (1200x1500 layout units, drawn at `scale`): what X shows uncropped
    on a phone, one column, big type."""
    S = scale
    W, H = int(1200 * S), int(1500 * S)
    bg, g1, g2, headline, body, muted, accent, shadow_a = PALETTES[theme]
    img = background(W, H, bg, g1, g2)
    # the icon tile, centred, floating on a soft shadow
    size, ix, iy = int(330 * S), (W - int(330 * S)) // 2, int(96 * S)
    if icon_path and os.path.exists(icon_path):
        ic = smoothed(Image.open(icon_path).convert("RGBA"), size)
        # a wide, faint shadow under the tile (a tight dark one showed the dither as texture)
        pad = int(90 * S)
        sh = Image.new("RGBA", (size + 2 * pad, size + 2 * pad), (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle((pad, pad + int(22 * S), size + pad, size + pad + int(22 * S)), radius=int(size * 0.22), fill=(20, 30, 70, shadow_a))
        sh = sh.filter(ImageFilter.GaussianBlur(36 * S))
        img.paste(sh, (ix - pad, iy - pad), sh)
        img.paste(ic, (ix, iy), ic)
    d = ImageDraw.Draw(img)
    F = lambda size, bold=False: font(int(size * S), bold)
    def centred(text, f, y, fill):
        d.text(((W - d.textlength(text, font=f)) / 2, y * S), text, font=f, fill=fill)
    centred("Vory", F(64, True), 458, headline)
    centred(f"TestFlight build {build}", F(38), 540, accent)
    centred(f"Public beta {version}", F(28), 592, muted)
    # one column of bullets
    x, y, colw = 110, 700, 1200 - 220
    # Many bullets (a "Coming next" group on top of the fixes): a tighter setting so the last
    # group is not cut off above the site line.
    total = sum(len(v) for v in groups.values())
    compact = total >= 8
    hf, bf = F(26 if compact else 28, True), F(30 if compact else 34)
    lh, gap, ggap, hh = (40, 6, 22, 44) if compact else (46, 10, 30, 50)
    for title, items in groups.items():
        if not items or y > 1300: continue
        d.text((x * S, y * S), title.upper(), font=hf, fill=accent); y += hh
        for b in items:
            lines = wrap(d, short(b), bf, (colw - 40) * S)
            if y + lh * len(lines) > 1370: break
            for i, line in enumerate(lines):
                if i == 0: d.ellipse(((x + 4) * S, (y + 14) * S, (x + 15) * S, (y + 25) * S), fill=accent)
                d.text(((x + 38) * S, y * S), line, font=bf, fill=body); y += lh
            y += gap
        y += ggap
    centred(SITE, F(34, True), 1408, accent)
    img.save(out_path, optimize=True)
    # The one to post: X re-encodes to JPEG anyway, and the dither makes the PNG several MB.
    img.save(os.path.splitext(out_path)[0] + ".jpg", quality=95, subsampling=0, optimize=True)

def posts(build, groups):
    fixed = [short(b, 95) for b in groups.get("Fixed in this build", [])]
    changed = [short(b, 95) for b in groups.get("Changed in this build", [])]
    head = f"Vory beta build {build} is on TestFlight."
    parts = []
    if fixed: parts.append("Fixed: " + "; ".join(fixed[:3]) + ".")
    if changed: parts.append("New: " + "; ".join(changed[:2]) + ".")
    short_post = head + " " + " ".join(parts) + " " + SITE
    while len(short_post) > 280 and (fixed or changed):
        if len(fixed) > 1: fixed.pop()
        elif changed: changed.pop()
        else: fixed.pop()
        parts = []
        if fixed: parts.append("Fixed: " + "; ".join(fixed[:3]) + ".")
        if changed: parts.append("New: " + "; ".join(changed[:2]) + ".")
        short_post = head + " " + " ".join(parts) + " " + SITE
    long_post = head + "\n\n" + "\n".join(f"• {short(b, 90)}" for t in groups for b in groups[t][:5]) + "\n\n" + SITE
    return short_post, long_post

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("build"); ap.add_argument("notes"); ap.add_argument("--icon", default=None)
    ap.add_argument("--out", default="."); ap.add_argument("--version", default="1.1")
    ap.add_argument("--theme", choices=("light", "dark"), default="light", help="light (the default, with the light icon) or dark")
    a = ap.parse_args()
    groups = {k: v for k, v in sections(open(a.notes).read()).items() if k in ("Fixed in this build", "Changed in this build", "Coming next")}
    if not groups: sys.exit("no 'Fixed in this build' / 'Changed in this build' bullets found")
    os.makedirs(a.out, exist_ok=True)
    out = os.path.join(a.out, f"vory-build-{a.build}.png")
    icon = a.icon or os.path.join(os.path.dirname(os.path.abspath(__file__)), "vory-icon-2048-light.png" if a.theme == "light" else "vory-icon-2048.png")
    render(a.build, a.version, groups, icon, out, a.theme)
    s, l = posts(a.build, groups)
    print(out, "(+ .jpg for posting)"); print("\n--- short (%d chars) ---\n%s\n\n--- long ---\n%s" % (len(s), s, l))
