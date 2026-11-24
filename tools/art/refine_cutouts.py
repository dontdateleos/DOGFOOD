#!/usr/bin/env python3
"""Cleans the three piñatas that were cut out of screenshots (donkey, bull, zebra).

A cut-out from a flat-colour screenshot has two problems: the soft edge still carries some of the
background colour (a teal or peach fringe), and the picture is only as big as it was on screen.

For each one this
  1. keeps the solid middle of the picture as the truth for colour and paints that colour outward
     into the soft edge, so the fringe takes the piñata's own colours instead of the old background;
  2. tightens the edge a little so a halo cannot show on any banner colour;
  3. scales it up 2x and sharpens lightly, so it stays crisp on a phone screen.
It cannot add detail the source never had; the real fix for that is the original artwork.

Run from the repo root:  python3 -I tools/art/refine_cutouts.py
Rebuilds the eye piece and the paper behind it for the animals that blink and build in layers.
Keep a copy of shell/ before running: the sources are overwritten.
"""
import numpy as np, os, sys
from PIL import Image, ImageFilter

SHELL = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'shell')
SCALE = 2


def decontaminate(im):
    a = np.array(im.convert('RGBA')).astype(float)
    al = a[..., 3] / 255.0
    solid = Image.fromarray((al > 0.97).astype(np.uint8) * 255, 'L').filter(ImageFilter.MinFilter(5))
    core = np.array(solid) > 0
    col = a[..., :3].copy()
    filled = core.copy()
    shifts = [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)]
    for _ in range(7):
        acc = np.zeros_like(col)
        cnt = np.zeros(al.shape)
        for dy, dx in shifts:
            f = np.roll(filled, (dy, dx), (0, 1))
            c = np.roll(col, (dy, dx), (0, 1))
            acc += c * f[..., None]
            cnt += f
        grow = (~filled) & (cnt > 0)
        col[grow] = acc[grow] / cnt[grow][..., None]
        filled |= grow
    edge = (al > 0) & ~core
    a[..., :3][edge] = col[edge]
    # tighten: the faintest and the almost-solid ends of the edge are cut back, then the edge is eased
    al2 = np.clip((al - 0.18) / 0.64, 0, 1)
    out = Image.fromarray(np.dstack([a[..., :3], al2 * 255]).astype(np.uint8), 'RGBA')
    soft = out.getchannel('A').filter(ImageFilter.GaussianBlur(0.55))
    out.putalpha(soft)
    return out


def upscale(im, k=SCALE):
    big = im.resize((im.width * k, im.height * k), Image.LANCZOS)
    rgb = big.convert('RGB').filter(ImageFilter.UnsharpMask(radius=1.4, percent=55, threshold=3))
    out = rgb.convert('RGBA')
    out.putalpha(big.getchannel('A'))
    return out


def eye_and_paper(base, cx, cy, r, name):
    """The paper behind the eye (its hole filled with the colours around it) and the eye on its own."""
    a = np.array(base)
    H, W = a.shape[:2]
    yy, xx = np.mgrid[0:H, 0:W]
    d = np.hypot(xx - cx, yy - cy)
    ang = np.arctan2(yy - cy, xx - cx)
    ring = (d > r + 12) & (d < r + 24) & (a[..., 3] > 200)
    bins = ((ang + np.pi) / (2 * np.pi) * 48).astype(int) % 48
    cols = np.zeros((48, 3))
    for k in range(48):
        m = ring & (bins == k)
        cols[k] = a[m][:, :3].mean(0) if m.sum() > 3 else a[ring][:, :3].mean(0)
    cols = (np.roll(cols, 1, 0) + cols + np.roll(cols, -1, 0)) / 3
    pap = a.copy()
    hole = d <= r + 6
    pap[hole, :3] = cols[bins[hole]].astype(np.uint8)
    pap[hole, 3] = 255
    Image.fromarray(pap, 'RGBA').save(os.path.join(SHELL, f'{name}_paper.webp'), quality=94)
    eye = np.zeros_like(a)
    me = d <= r + 10
    eye[me] = a[me]
    ea = Image.fromarray(eye, 'RGBA')
    ea.putalpha(ea.getchannel('A').filter(ImageFilter.GaussianBlur(2.6)))
    ea.save(os.path.join(SHELL, f'{name}_eye.webp'), quality=94)


def main():
    jobs = {
        'm_donkey': (264, 160, 27),    # eye centre and radius on the original-size picture
        'm_bull': None,                 # no eye piece, no layers
        'm_zebra': (188, 173, 44),
    }
    for name, eye in jobs.items():
        src = Image.open(os.path.join(SHELL, f'{name}.webp')).convert('RGBA')
        clean = upscale(decontaminate(src))
        clean.save(os.path.join(SHELL, f'{name}.webp'), quality=93, method=6)
        if eye:
            cx, cy, r = [v * SCALE for v in eye]
            eye_and_paper(clean, cx, cy, r, name)
        print(name, src.size, '->', clean.size)
    bull = Image.open(os.path.join(SHELL, 'm_bull.webp')).convert('RGBA')
    head = bull.crop((190, 0, 850, 600))
    head.crop(head.getchannel('A').getbbox()).save(os.path.join(SHELL, 'm_bull_head.webp'), quality=92)


if __name__ == '__main__':
    main()
