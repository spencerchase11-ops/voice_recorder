"""Renders the glossy transport buttons (record/stop, play/pause/disabled play,
list play/pause).

Shapes and colours were sampled from reference screenshots of the original
app; the recording/playing variants (stop, pause) are drawn in the same style.
All geometry is expressed in dp and rendered at --scale device pixels per dp.

Usage: python3 tool/art/buttons.py <out_dir> [--scale 4] [--ss 4]
"""
import argparse
import os

import numpy as np
from PIL import Image


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def gauss(x, mu, sigma):
    return np.exp(-0.5 * ((x - mu) / sigma) ** 2)


# ---------------------------------------------------------------- SDFs
def sd_circle(x, y, cx, cy, r):
    return np.hypot(x - cx, y - cy) - r


def sd_segment(x, y, ax, ay, bx, by):
    pax, pay = x - ax, y - ay
    bax, bay = bx - ax, by - ay
    h = np.clip((pax * bax + pay * bay) / (bax * bax + bay * bay), 0, 1)
    return np.hypot(pax - bax * h, pay - bay * h)


def sd_polygon(x, y, pts):
    """Signed distance to a convex polygon (negative inside)."""
    d = np.full(x.shape, np.inf)
    inside = np.ones(x.shape, bool)
    n = len(pts)
    for i in range(n):
        ax, ay = pts[i]
        bx, by = pts[(i + 1) % n]
        d = np.minimum(d, sd_segment(x, y, ax, ay, bx, by))
        cross = (bx - ax) * (y - ay) - (by - ay) * (x - ax)
        inside &= cross >= 0
    return np.where(inside, -d, d)


def sd_rounded_polygon(x, y, pts, r):
    """Polygon with rounded corners: shrink the polygon by r, then offset by r."""
    cx = sum(p[0] for p in pts) / len(pts)
    cy = sum(p[1] for p in pts) / len(pts)
    # inset each vertex along the bisector so that edges move inwards by r
    n = len(pts)
    inset = []
    for i in range(n):
        px, py = pts[i]
        ax, ay = pts[i - 1]
        bx, by = pts[(i + 1) % n]
        e1 = np.array([px - ax, py - ay]); e1 /= np.linalg.norm(e1)
        e2 = np.array([bx - px, by - py]); e2 /= np.linalg.norm(e2)
        n1 = np.array([e1[1], -e1[0]])
        n2 = np.array([e2[1], -e2[0]])
        # choose inward normals (towards the centroid)
        if np.dot(n1, [cx - px, cy - py]) < 0:
            n1 = -n1
        if np.dot(n2, [cx - px, cy - py]) < 0:
            n2 = -n2
        bis = n1 + n2
        bis /= np.linalg.norm(bis)
        s = r / np.dot(bis, n1)
        inset.append((px + bis[0] * s, py + bis[1] * s))
    return sd_polygon(x, y, inset) - r


def fit_rounded_triangle(x0, y0, w, h, r):
    """Right-pointing triangle whose *rounded* outline has the bbox (x0, y0, w, h)."""
    gx, gy = np.meshgrid(np.linspace(-20, w + 20, 1200), np.linspace(-20, h + 20, 1200))
    pts = [(0.0, 0.0), (w, h / 2), (0.0, h)]
    for _ in range(40):
        inside = sd_rounded_polygon(gx, gy, pts, r) < 0
        ys, xs = np.nonzero(inside)
        bx0, bx1 = gx[0, xs.min()], gx[0, xs.max()]
        by0, by1 = gy[ys.min(), 0], gy[ys.max(), 0]
        sx = w / (bx1 - bx0)
        sy = h / (by1 - by0)
        pts = [((px - bx0) * sx, (py - by0) * sy) for px, py in pts]
        if abs(sx - 1) < 1e-3 and abs(sy - 1) < 1e-3:
            break
    return [(px + x0, py + y0) for px, py in pts]


def sd_rounded_rect(x, y, x0, y0, x1, y1, r):
    qx = np.abs(x - (x0 + x1) / 2) - ((x1 - x0) / 2 - r)
    qy = np.abs(y - (y0 + y1) / 2) - ((y1 - y0) / 2 - r)
    return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r


def cover(sd, px):
    """Anti-aliased coverage from a signed distance (in dp) given the pixel size."""
    return np.clip(0.5 - sd / px, 0, 1)


def over(dst, src_rgb, src_a):
    rgb, a = dst
    sa = src_a[..., None]
    out_a = src_a + a * (1 - src_a)
    out = (src_rgb * sa + rgb * a[..., None] * (1 - sa)) / np.where(out_a > 1e-6, out_a, 1)[..., None]
    return out, out_a


def canvas(w_dp, h_dp, scale, ss):
    W, H = int(round(w_dp * scale)), int(round(h_dp * scale))
    f = scale * ss
    ys, xs = np.mgrid[0:H * ss, 0:W * ss].astype(np.float64)
    return (xs + 0.5) / f, (ys + 0.5) / f, W, H, 1.0 / f


def finish(img, W, H, ss):
    rgb, a = img
    prem = rgb * a[..., None]
    a_d = a.reshape(H, ss, W, ss).mean(axis=(1, 3))
    p_d = prem.reshape(H, ss, W, ss, 3).mean(axis=(1, 3))
    rgb_d = p_d / np.where(a_d > 1e-6, a_d, 1)[..., None]
    out = np.dstack([np.clip(rgb_d, 0, 255), np.clip(a_d * 255, 0, 255)])
    return Image.fromarray(out.round().astype(np.uint8), 'RGBA')


def col(*c):
    return np.array(c, dtype=np.float64)


def blend(a, b, t):
    return a + (b - a) * t[..., None]


# ---------------------------------------------------------- red ball
def red_ball(scale, ss, symbol=None):
    size = 36.0
    x, y, W, H, px = canvas(size, size, scale, ss)
    cx = cy = size / 2
    R = 16.7
    nx, ny = (x - cx) / R, (y - cy) / R
    d = sd_circle(x, y, cx, cy, R)
    a = cover(d, px)

    # lower (lit) body: radial glow from the lower right
    glow = np.hypot(nx - 0.62, ny - 0.62)
    body = blend(col(214, 26, 2)[None, None, :] + 0 * x[..., None], col(126, 5, 5), smoothstep(0.05, 1.05, glow))
    # upper gloss cap: everything above an arc rising from the left
    arc = np.hypot(nx - 0.30, ny - 1.90) - 2.15
    cap = smoothstep(-0.03, 0.03, arc)
    gloss = blend(col(164, 74, 72) + 0 * x[..., None], col(146, 60, 58), smoothstep(-0.2, -1.0, ny))
    rgb = blend(body, gloss, cap)
    # thin light rim
    rim = gauss(d, -0.45, 0.35) * 0.35
    rgb = blend(rgb, col(235, 150, 150) + 0 * x[..., None], rim)
    img = (np.zeros(x.shape + (3,)), np.zeros(x.shape))
    img = over(img, rgb, a)

    if symbol in ('stop', 'pause'):
        s = 5.4
        if symbol == 'stop':
            rects = [(cx - s, cy - s, cx + s, cy + s)]
        else:
            # two bars of the stop square's height (the recording pause)
            bw, gap = 3.6, 3.2
            rects = [(cx - gap / 2 - bw, cy - s, cx - gap / 2, cy + s),
                     (cx + gap / 2, cy - s, cx + gap / 2 + bw, cy + s)]
        for x0, y0, x1, y1 in rects:
            sd = sd_rounded_rect(x, y, x0, y0, x1, y1, 1.2 if symbol == 'pause' else 1.6)
            sa = cover(sd, px)
            sym = blend(col(255, 255, 255) + 0 * x[..., None], col(236, 222, 222), smoothstep(cy - s, cy + s, y))
            # soft shadow under the symbol
            sh = cover(sd_rounded_rect(x, y - 0.6, x0, y0, x1, y1, 1.2 if symbol == 'pause' else 1.6) - 0.3, 1.2) * 0.35
            img = over(img, np.zeros_like(rgb) + col(60, 0, 0), sh * a)
            img = over(img, sym, sa)
    return finish(img, W, H, ss)


# ------------------------------------------------- green play / pause
def _green_shade(x, y, top, bottom, sd, px):
    h = bottom - top
    t = (y - top) / h
    base = blend(col(20, 150, 14) + 0 * x[..., None], col(14, 186, 10), smoothstep(0.45, 0.95, t))
    # gloss over the upper half, with an arc-shaped lower boundary
    arc = t - (0.50 + 0.10 * np.cos(np.clip((x - x.min()) / max(x.max() - x.min(), 1e-6), 0, 1) * np.pi))
    cap = 1 - smoothstep(-0.02, 0.02, arc)
    gloss = blend(col(84, 190, 76) + 0 * x[..., None], col(80, 162, 86), smoothstep(0.05, 0.5, t))
    rgb = blend(base, gloss, cap)
    # bright lime inner edge along the lower part
    inner = gauss(sd, -0.9, 0.55) * smoothstep(0.55, 0.95, t)
    rgb = blend(rgb, col(96, 232, 60) + 0 * x[..., None], inner * 0.9)
    # darker outline
    edge = gauss(sd, -0.25, 0.35)
    rgb = blend(rgb, col(18, 110, 18) + 0 * x[..., None], edge * 0.8)
    return rgb


def green_play(scale, ss):
    w, h = 28.0, 36.0
    x, y, W, H, px = canvas(w, h, scale, ss)
    x0, y0 = 1.15, 1.45
    pts = fit_rounded_triangle(x0, y0, 25.7, 33.1, 2.4)
    sd = sd_rounded_polygon(x, y, pts, 2.4)
    rgb = _green_shade(x, y, y0, y0 + 33.1, sd, px)
    img = over((np.zeros(x.shape + (3,)), np.zeros(x.shape)), rgb, cover(sd, px))
    return finish(img, W, H, ss)


def green_pause(scale, ss):
    w, h = 28.0, 36.0
    x, y, W, H, px = canvas(w, h, scale, ss)
    y0, y1 = 3.0, 33.0
    img = (np.zeros(x.shape + (3,)), np.zeros(x.shape))
    for bx0 in (3.5, 16.0):
        sd = sd_rounded_rect(x, y, bx0, y0, bx0 + 8.5, y1, 2.2)
        rgb = _green_shade(x, y, y0, y1, sd, px)
        img = over(img, rgb, cover(sd, px))
    return finish(img, W, H, ss)


# ------------------------------------------- silver (disabled) play
def _silver_shade(x, y, top, bottom, sd, px):
    """The play button's disabled look: the same glossy triangle in silver."""
    t = (y - top) / (bottom - top)
    u = np.clip((x - x.min()) / max(x.max() - x.min(), 1e-6), 0, 1)
    arc_t = 0.50 + 0.10 * np.cos(u * np.pi)
    arc = t - arc_t
    # body under the gloss: darkest right below it, lighter towards the bottom
    below = np.clip(arc / (1 - arc_t), 0, 1)
    base = blend(col(170, 174, 177) + 0 * x[..., None], col(228, 229, 231), smoothstep(0.0, 0.75, below))
    # gloss: light at the top, dimmer lower down, brighter again along its edge
    above = np.clip(t / arc_t, 0, 1)
    gloss = blend(col(204, 207, 209) + 0 * x[..., None], col(176, 180, 183), smoothstep(0.0, 0.6, above))
    gloss = blend(gloss, col(200, 203, 206) + 0 * x[..., None], smoothstep(0.75, 1.0, above) * 0.8)
    cap = 1 - smoothstep(-0.02, 0.02, arc)
    rgb = blend(base, gloss, cap)
    # light rim just inside the outline
    rim = gauss(sd, -1.1, 0.5)
    return blend(rgb, col(222, 224, 226) + 0 * x[..., None], rim * 0.35)


def silver_play(scale, ss):
    w, h = 28.0, 36.0
    x, y, W, H, px = canvas(w, h, scale, ss)
    x0, y0 = 1.15, 1.45
    pts = fit_rounded_triangle(x0, y0, 25.7, 33.1, 2.4)
    sd = sd_rounded_polygon(x, y, pts, 2.4)
    rgb = _silver_shade(x, y, y0, y0 + 33.1, sd, px)
    img = over((np.zeros(x.shape + (3,)), np.zeros(x.shape)), rgb, cover(sd, px))
    return finish(img, W, H, ss)


# ---------------------------------------------------- blue play / pause
def _blue_shade(x, y, top, bottom, sd, px, left):
    t = (y - top) / (bottom - top)
    base = blend(col(51, 153, 254) + 0 * x[..., None], col(150, 218, 255), smoothstep(0.55, 1.0, t))
    base = blend(base, col(74, 163, 255) + 0 * x[..., None], gauss(t, 0.35, 0.12) * 0.4)
    # white gloss inside the upper-left edge
    gl = gauss(sd, -2.4, 1.3) * (1 - smoothstep(0.15, 0.62, t)) * (1 - smoothstep(0, 16, x - left))
    base = blend(base, col(246, 252, 255) + 0 * x[..., None], np.clip(gl * 1.25, 0, 1))
    # dark navy outline ~2 dp
    outline = smoothstep(-2.1, -1.5, sd)
    return blend(base, col(4, 58, 158) + 0 * x[..., None], outline)


def blue_play(scale, ss):
    w, h = 32.0, 36.0
    x, y, W, H, px = canvas(w, h, scale, ss)
    x0, y0 = 0.85, 0.85
    pts = fit_rounded_triangle(x0, y0, 30.3, 34.3, 1.6)
    sd = sd_rounded_polygon(x, y, pts, 1.6)
    rgb = _blue_shade(x, y, y0, y0 + 34.3, sd, px, x0)
    img = over((np.zeros(x.shape + (3,)), np.zeros(x.shape)), rgb, cover(sd, px))
    return finish(img, W, H, ss)


def blue_pause(scale, ss):
    w, h = 32.0, 36.0
    x, y, W, H, px = canvas(w, h, scale, ss)
    y0, y1 = 2.0, 34.0
    img = (np.zeros(x.shape + (3,)), np.zeros(x.shape))
    for bx0 in (4.0, 18.0):
        sd = sd_rounded_rect(x, y, bx0, y0, bx0 + 10.0, y1, 1.8)
        rgb = _blue_shade(x, y, y0, y1, sd, px, bx0)
        img = over(img, rgb, cover(sd, px))
    return finish(img, W, H, ss)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out_dir')
    ap.add_argument('--scale', type=float, default=4.0)
    ap.add_argument('--ss', type=int, default=4)
    args = ap.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)
    jobs = {
        'record.png': lambda: red_ball(args.scale, args.ss),
        'record_stop.png': lambda: red_ball(args.scale, args.ss, symbol='stop'),
        'record_pause.png': lambda: red_ball(args.scale, args.ss, symbol='pause'),
        'play.png': lambda: green_play(args.scale, args.ss),
        'pause.png': lambda: green_pause(args.scale, args.ss),
        'play_disabled.png': lambda: silver_play(args.scale, args.ss),
        'list_play.png': lambda: blue_play(args.scale, args.ss),
        'list_pause.png': lambda: blue_pause(args.scale, args.ss),
    }
    for name, fn in jobs.items():
        fn().save(os.path.join(args.out_dir, name), optimize=True)


if __name__ == '__main__':
    main()
