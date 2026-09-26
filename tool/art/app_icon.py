"""Renders the app icon (red disc with a white studio microphone and a flat
long shadow on a light rounded tile), measured from the original's action bar.

Outputs (paths relative to the repository root):
  assets/images/app_icon.png                       in-app header icon (with tile)
  android/app/src/main/res/mipmap-*/ic_launcher.png legacy launcher icons
  android/app/src/main/res/mipmap-*/ic_launcher_foreground.png  adaptive layer
  android/app/src/main/res/drawable/ic_launcher_background.xml   (written separately)
  ios/Runner/Assets.xcassets/AppIcon.appiconset/*   opaque iOS icons

Usage: python3 tool/art/app_icon.py <repo_root>
"""
import json
import os
import sys

import numpy as np
from PIL import Image


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def sd_round_rect(x, y, x0, y0, x1, y1, r):
    qx = np.abs(x - (x0 + x1) / 2) - ((x1 - x0) / 2 - r)
    qy = np.abs(y - (y0 + y1) / 2) - ((y1 - y0) / 2 - r)
    return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r


def mic_sdf(x, y):
    """Signed distance (in icon units, 0..1) of the white microphone glyph."""
    head = sd_round_rect(x, y, 0.38, 0.19, 0.62, 0.595, 0.12)
    # U-shaped holder around the lower half of the head
    cx, cy, r, t = 0.5, 0.47, 0.178, 0.044
    ring = np.abs(np.hypot(x - cx, y - cy) - r) - t / 2
    arms = np.minimum(sd_round_rect(x, y, cx - r - t / 2, 0.44, cx - r + t / 2, cy + 0.001, t / 2),
                      sd_round_rect(x, y, cx + r - t / 2, 0.44, cx + r + t / 2, cy + 0.001, t / 2))
    holder = np.minimum(np.where(y >= cy, ring, 1.0), arms)
    stem = sd_round_rect(x, y, 0.477, cy + r, 0.523, 0.775, 0.004)
    base = sd_round_rect(x, y, 0.37, 0.765, 0.63, 0.812, 0.008)
    d = np.minimum.reduce([head, holder, stem, base])
    # 3 x 3 grille dots punched out of the head
    for yy in (0.245, 0.295, 0.345):
        for xx in (0.44, 0.5, 0.56):
            d = np.maximum(d, -(np.hypot(x - xx, y - yy) - 0.02))
    return d


def diagonal_distance(mask, max_steps):
    """For every pixel, how many pixels up-left along the 45 degree diagonal
    the nearest covered pixel of [mask] is (min-plus doubling)."""
    inf = 1e9
    d = np.where(mask, 0.0, inf)
    s = 1
    while s < max_steps:
        shifted = np.full_like(d, inf)
        shifted[s:, s:] = d[:-s, :-s] + s
        d = np.minimum(d, shifted)
        s *= 2
    return d


def render(size, ss=4, tile=True, tile_radius=0.092, disc_scale=1.0, opaque_bg=None, bg_window=(0.0, 1.0)):
    """[bg_window]: the part of the tile's top-to-bottom gradient that shows."""
    n = size * ss
    ys, xs = np.mgrid[0:n, 0:n].astype(np.float64)
    x = (xs + 0.5) / n
    y = (ys + 0.5) / n
    px = 1.0 / n

    # scale the artwork about the centre (adaptive foregrounds need padding)
    ax = (x - 0.5) / disc_scale + 0.5
    ay = (y - 0.5) / disc_scale + 0.5
    apx = px / disc_scale

    rgb = np.zeros((n, n, 3))
    alpha = np.zeros((n, n))

    def over(src, a):
        nonlocal rgb, alpha
        out_a = a + alpha * (1 - a)
        rgb = (src * a[..., None] + rgb * (alpha * (1 - a))[..., None]) / np.where(out_a > 1e-6, out_a, 1)[..., None]
        alpha = out_a

    if opaque_bg is not None:
        over(np.broadcast_to(np.array(opaque_bg, float), rgb.shape), np.ones((n, n)))

    if tile:
        if tile_radius > 0:
            d = sd_round_rect(x, y, 0.0, 0.0, 1.0, 1.0, tile_radius)
            a = np.clip(0.5 - d / px, 0, 1)
            edge = smoothstep(0.0, 0.012, -d)
        else:
            a = np.ones_like(x)
            edge = np.ones_like(x)
        # (top, middle, bottom) per channel, measured from the original
        gy = bg_window[0] + (bg_window[1] - bg_window[0]) * y
        g = np.stack([np.interp(gy, [0, 0.5, 1], c) for c in ([255, 231, 194], [243, 227, 195], [245, 228, 197])], -1)
        g = g * (0.86 + 0.14 * edge[..., None])
        over(g, a)

    # red disc: red at the top, dark grey at the bottom
    r = 0.465
    dd = np.hypot(ax - 0.5, ay - 0.5) - r
    a = np.clip(0.5 - dd / apx, 0, 1)
    t = ay
    red = np.stack([
        np.interp(t, [0.03, 0.35, 0.62, 0.84, 0.97], [192, 176, 132, 70, 56]),
        np.interp(t, [0.03, 0.35, 0.62, 0.84, 0.97], [30, 29, 32, 38, 50]),
        np.interp(t, [0.03, 0.35, 0.62, 0.84, 0.97], [46, 42, 44, 44, 52]),
    ], -1)
    # sideways falloff
    red = red * (0.86 + 0.14 * (1 - smoothstep(0.1, 0.47, np.abs(ax - 0.5))))[..., None]

    # long shadow: the glyph extruded towards the bottom right
    m = mic_sdf(ax, ay)
    reach = 0.55 * n * disc_scale
    dist = diagonal_distance(m < 0, int(reach) + 1)
    shadow = np.where(dist <= reach, 1 - 0.45 * np.clip(dist / reach, 0, 1), 0.0)
    red = red * (1 - 0.32 * shadow[..., None])
    over(red, a)

    # white microphone with a faint drop shadow
    glyph = np.clip(0.5 - m / apx, 0, 1)
    tone = np.stack([np.interp(ay, [0.18, 0.8], c) for c in ([250, 226], [240, 229], [242, 231])], -1)
    over(tone, glyph * a)

    # downsample
    prem = rgb * alpha[..., None]
    a_d = alpha.reshape(size, ss, size, ss).mean(axis=(1, 3))
    p_d = prem.reshape(size, ss, size, ss, 3).mean(axis=(1, 3))
    rgb_d = p_d / np.where(a_d > 1e-6, a_d, 1)[..., None]
    out = np.dstack([np.clip(rgb_d, 0, 255), np.clip(a_d * 255, 0, 255)]).round().astype(np.uint8)
    return Image.fromarray(out, 'RGBA')


def render_monochrome(size, ss=4, disc_scale=0.64):
    """Microphone silhouette for Android 13+ themed icons."""
    n = size * ss
    ys, xs = np.mgrid[0:n, 0:n].astype(np.float64)
    x = ((xs + 0.5) / n - 0.5) / disc_scale + 0.5
    y = ((ys + 0.5) / n - 0.5) / disc_scale + 0.5
    a = np.clip(0.5 - mic_sdf(x, y) / (1.0 / n / disc_scale), 0, 1)
    a = a.reshape(size, ss, size, ss).mean(axis=(1, 3))
    out = np.zeros((size, size, 4), np.uint8)
    out[..., :3] = 255
    out[..., 3] = np.round(a * 255).astype(np.uint8)
    return Image.fromarray(out, 'RGBA')


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    render(160).save(os.path.join(root, 'assets/images/app_icon.png'), optimize=True)

    res = os.path.join(root, 'android/app/src/main/res')
    for folder, px in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}.items():
        d = os.path.join(res, 'mipmap-' + folder)
        os.makedirs(d, exist_ok=True)
        render(px).save(os.path.join(d, 'ic_launcher.png'), optimize=True)
        # adaptive foreground: 108 dp canvas, artwork inside the 72 dp safe zone
        fg = render(int(px * 108 / 48), tile=False, disc_scale=0.64)
        fg.save(os.path.join(d, 'ic_launcher_foreground.png'), optimize=True)
        render_monochrome(int(px * 108 / 48)).save(os.path.join(d, 'ic_launcher_monochrome.png'), optimize=True)

    ios = os.path.join(root, 'ios/Runner/Assets.xcassets/AppIcon.appiconset')
    with open(os.path.join(ios, 'Contents.json')) as fh:
        contents = json.load(fh)
    # What Android's adaptive icon shows inside its 72 dp mask: the middle of
    # the 108 dp layers, so the disc is 0.64 * 108 / 72 = 0.96 and the tile's
    # gradient runs from 18 dp to 90 dp. iOS then rounds the corners.
    master = render(1024, ss=2, tile=True, tile_radius=0, disc_scale=0.96,
                    bg_window=(18 / 108, 90 / 108)).convert('RGB')
    for img in contents['images']:
        name = img.get('filename')
        if not name:
            continue
        pts = float(img['size'].split('x')[0])
        scale = float(img['scale'].rstrip('x'))
        px = int(round(pts * scale))
        master.resize((px, px), Image.LANCZOS).save(os.path.join(ios, name), optimize=True)


if __name__ == '__main__':
    main()
