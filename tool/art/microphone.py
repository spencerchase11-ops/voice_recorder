"""Procedurally renders the chrome studio microphone shown on the Recorder screen.

Geometry was measured from a 1440x3120 (3.5x density) screenshot of the
original app. All coordinates below are in those reference pixels, relative
to the canvas origin (458, 560) of the reference screen. The perforated grille
is ray-cast as a capsule (cylinder + two hemispheres) with a staggered hole
lattice in latitude/longitude surface coordinates, so the holes foreshorten
towards the silhouette like the original artwork.

Usage: python3 tool/art/microphone.py <out.png> [--scale 4.0] [--ss 3]
  --scale  output density (device pixels per dp); the reference is 3.5
  --ss     supersampling factor for anti-aliasing
"""
import argparse

import numpy as np
from PIL import Image

REF_DENSITY = 3.5
CANVAS_W, CANVAS_H = 518.0, 886.0          # reference px

CX = 259.0                                 # mic axis
R = 196.0                                  # grille radius
Y_TOP_EQ = 201.0                           # centre of the upper hemisphere
Y_BOT_EQ = 579.0                           # centre of the lower hemisphere

BAND_R = 201.0
BAND_Y0, BAND_Y1 = 372.0, 472.0

DOT_C = (257.0, 428.0)
DOT_R = 30.0

KNOB_X0, KNOB_X1 = 5.0, 25.0               # knurled cap (left side)
KNOB_Y0, KNOB_Y1 = 378.0, 447.0
AXLE_X0, AXLE_X1 = 23.0, 62.0
AXLE_Y0, AXLE_Y1 = 389.0, 437.0

ARM_R = 213.0                              # centre line radius of the U arm
ARM_W = 14.0
ARM_Y0 = 432.0                             # where the arm leaves the axle

STEM_X0, STEM_X1 = 235.0, 284.0
STEM_Y0, STEM_Y1 = 760.0, 840.0
BASE_X0, BASE_X1 = 184.0, 334.0
BASE_Y0, BASE_Y1 = 838.0, 882.0

HOLE_PITCH_U = 18.0
HOLE_PITCH_V = 12.5
HOLE_R = 4.6


# Peak metal luminance of the grille (between the holes), sampled from the
# reference artwork every 24 px of canvas height (rows inside the band are
# omitted) and 21 bins of |t| = distance from the axis / local radius.
GRILLE_ENV_Y = [12, 36, 60, 84, 108, 132, 156, 180, 204, 228, 252, 276, 300, 324, 348,
                492, 516, 540, 564, 588, 612, 636, 660, 684, 708, 732, 756]
GRILLE_ENV = np.array([
    [233, 233, 231, 231, 230, 228, 227, 228, 231, 232, 232, 233, 232, 229, 227, 225, 222, 218, 214, 210, 208],
    [238, 238, 241, 241, 241, 241, 239, 240, 239, 239, 238, 238, 237, 238, 239, 239, 237, 235, 232, 225, 221],
    [240, 240, 242, 245, 244, 241, 245, 244, 240, 242, 239, 236, 237, 233, 232, 233, 229, 225, 223, 223, 216],
    [243, 241, 239, 243, 247, 245, 242, 241, 239, 235, 230, 228, 225, 226, 224, 222, 222, 220, 222, 209, 202],
    [244, 244, 244, 244, 240, 237, 238, 239, 232, 229, 226, 222, 217, 214, 216, 216, 222, 223, 220, 212, 209],
    [245, 243, 246, 245, 243, 238, 236, 233, 227, 225, 216, 215, 210, 209, 211, 226, 221, 220, 212, 204, 194],
    [244, 241, 245, 241, 240, 239, 234, 230, 221, 215, 211, 207, 203, 205, 211, 221, 225, 219, 189, 189, 191],
    [245, 243, 245, 241, 242, 235, 231, 227, 214, 209, 202, 200, 194, 203, 214, 217, 211, 198, 172, 177, 182],
    [245, 240, 240, 236, 236, 235, 228, 222, 212, 206, 200, 195, 187, 191, 213, 217, 207, 194, 158, 171, 175],
    [245, 240, 239, 235, 237, 234, 228, 217, 205, 198, 193, 187, 182, 184, 202, 211, 201, 179, 155, 167, 171],
    [247, 241, 239, 238, 235, 232, 225, 214, 204, 196, 187, 179, 176, 179, 194, 202, 195, 178, 156, 168, 172],
    [245, 242, 241, 240, 237, 233, 223, 212, 198, 187, 183, 170, 168, 173, 191, 202, 199, 181, 164, 168, 172],
    [243, 243, 241, 245, 234, 233, 218, 207, 196, 186, 175, 164, 160, 167, 192, 204, 196, 185, 168, 169, 171],
    [239, 244, 238, 241, 235, 231, 215, 208, 192, 180, 170, 158, 152, 160, 189, 199, 199, 184, 162, 166, 168],
    [237, 244, 239, 242, 236, 229, 214, 201, 188, 174, 164, 151, 144, 153, 193, 198, 198, 185, 168, 170, 172],
    [239, 236, 231, 230, 228, 214, 203, 172, 167, 133, 126, 106, 97, 121, 170, 180, 186, 179, 158, 170, 174],
    [242, 244, 237, 237, 227, 223, 199, 181, 163, 136, 124, 102, 94, 114, 166, 182, 179, 172, 156, 168, 172],
    [237, 243, 240, 241, 227, 224, 194, 180, 159, 136, 120, 97, 87, 107, 160, 183, 181, 168, 150, 167, 171],
    [239, 242, 239, 239, 228, 224, 195, 177, 157, 128, 115, 93, 81, 102, 152, 178, 179, 167, 145, 161, 165],
    [238, 242, 240, 241, 228, 221, 193, 179, 158, 123, 111, 88, 75, 99, 148, 172, 173, 162, 130, 154, 155],
    [238, 243, 237, 237, 227, 222, 198, 177, 156, 124, 108, 88, 71, 88, 135, 157, 159, 148, 125, 152, 153],
    [234, 242, 238, 239, 231, 221, 210, 178, 157, 134, 107, 88, 71, 64, 101, 135, 135, 125, 113, 131, 133],
    [243, 244, 240, 237, 232, 221, 210, 196, 159, 144, 119, 96, 72, 58, 57, 85, 96, 92, 90, 113, 116],
    [245, 242, 244, 238, 230, 230, 212, 201, 178, 153, 124, 105, 83, 58, 42, 35, 48, 58, 70, 97, 109],
    [241, 238, 236, 233, 225, 224, 219, 197, 175, 156, 134, 104, 77, 59, 44, 30, 25, 35, 59, 98, 106],
    [163, 160, 157, 159, 157, 148, 138, 132, 131, 121, 101, 88, 74, 64, 56, 50, 50, 53, 68, 99, 108],
    [69, 69, 69, 69, 69, 68, 67, 68, 69, 71, 71, 72, 73, 74, 74, 78, 84, 97, 106, 110, 112],
], dtype=np.float64)


def grille_envelope(y, side):
    """Bilinear lookup of GRILLE_ENV at canvas height y and |t| = side."""
    ys = np.array(GRILLE_ENV_Y, dtype=np.float64)
    fy = np.interp(y, ys, np.arange(len(ys)))
    fx = np.clip(side, 0, 1) * (GRILLE_ENV.shape[1] - 1)
    y0 = np.floor(fy).astype(int)
    x0 = np.floor(fx).astype(int)
    y1 = np.minimum(y0 + 1, len(ys) - 1)
    x1 = np.minimum(x0 + 1, GRILLE_ENV.shape[1] - 1)
    wy = fy - y0
    wx = fx - x0
    top = GRILLE_ENV[y0, x0] * (1 - wx) + GRILLE_ENV[y0, x1] * wx
    bot = GRILLE_ENV[y1, x0] * (1 - wx) + GRILLE_ENV[y1, x1] * wx
    return top * (1 - wy) + bot * wy


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def gauss(x, mu, sigma):
    return np.exp(-0.5 * ((x - mu) / sigma) ** 2)


def rounded_rect_alpha(x, y, x0, y0, x1, y1, r):
    """Anti-aliased coverage of a rounded rectangle."""
    qx = np.abs(x - (x0 + x1) / 2) - ((x1 - x0) / 2 - r)
    qy = np.abs(y - (y0 + y1) / 2) - ((y1 - y0) / 2 - r)
    outside = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r
    return np.clip(0.5 - outside, 0, 1)


def over(dst_rgb, dst_a, src_rgb, src_a):
    """Porter-Duff source-over on premultiplied-free float images."""
    a = src_a[..., None]
    out_a = src_a + dst_a * (1 - src_a)
    out_rgb = src_rgb * a + dst_rgb * dst_a[..., None] * (1 - a)
    safe = np.where(out_a > 1e-6, out_a, 1.0)[..., None]
    return out_rgb / safe, out_a


def chrome_profile(t):
    """Horizontal reflection profile of a vertical chrome cylinder.

    t is the signed position across the cylinder (-1 .. 1).
    """
    th = np.arcsin(np.clip(t, -0.9999, 0.9999))
    v = (0.52
         + 0.44 * gauss(th, 0.0, 0.30)
         + 0.20 * gauss(np.abs(th), 1.05, 0.22)
         - 0.10 * gauss(np.abs(th), 0.62, 0.14))
    return np.clip(v, 0.0, 1.0)


def render(scale=4.0, ss=3):
    k = scale / REF_DENSITY
    W = int(round(CANVAS_W * k))
    H = int(round(CANVAS_H * k))
    f = k * ss
    ys, xs = np.mgrid[0:H * ss, 0:W * ss].astype(np.float64)
    x = (xs + 0.5) / f
    y = (ys + 0.5) / f

    rgb = np.zeros(x.shape + (3,))
    alpha = np.zeros(x.shape)

    # ----------------------------------------------------------------- arm
    dx = x - CX
    in_straight = (y >= ARM_Y0) & (y <= Y_BOT_EQ)
    d_straight = np.abs(np.abs(dx) - ARM_R)
    rr = np.hypot(dx, y - Y_BOT_EQ)
    d_curve = np.abs(rr - ARM_R)
    d_arm = np.where(in_straight, d_straight, np.where(y > Y_BOT_EQ, d_curve, 1e9))
    arm_a = np.clip(ARM_W / 2 - d_arm + 0.5, 0, 1)
    # signed offset across the tube, for tube shading
    off = np.where(in_straight, (np.abs(dx) - ARM_R), rr - ARM_R) / (ARM_W / 2)
    tube = np.clip(0.42 + 0.50 * gauss(off, -0.15, 0.45) + 0.10 * gauss(off, 0.75, 0.2), 0, 1)
    arm_rgb = np.stack([tube * 232, tube * 232, tube * 236], axis=-1)
    rgb, alpha = over(rgb, alpha, arm_rgb, arm_a)

    # ------------------------------------------------------------ grille
    top = y < Y_TOP_EQ
    bot = y > Y_BOT_EQ
    ey = np.where(top, y - Y_TOP_EQ, np.where(bot, y - Y_BOT_EQ, 0.0))
    rho2 = dx * dx + ey * ey
    inside = rho2 < R * R
    dist_edge = R - np.sqrt(rho2)
    grille_a = np.clip(dist_edge + 0.5, 0, 1)

    dz = np.sqrt(np.clip(R * R - rho2, 0, None))
    lat = np.arcsin(np.clip(ey / R, -1, 1))         # 0 at the equators
    lon = np.arctan2(dx, np.maximum(dz, 1e-6))
    u = R * lon
    v = np.where(top, Y_TOP_EQ + R * lat, np.where(bot, Y_BOT_EQ + R * lat, y))

    row = np.floor(v / HOLE_PITCH_V + 0.5)
    cv = row * HOLE_PITCH_V
    # On the domes every ring of holes keeps the physical hole spacing, so the
    # rings get fewer holes towards the poles instead of pinching together.
    row_lat = np.where(top, (cv - Y_TOP_EQ) / R, np.where(bot, (cv - Y_BOT_EQ) / R, 0.0))
    ring_r = R * np.cos(np.clip(row_lat, -np.pi / 2, np.pi / 2))
    ring_r = np.where(top | bot, ring_r, R)
    u = ring_r * lon
    shift = (row % 2) * (HOLE_PITCH_U / 2)
    cu = np.round((u - shift) / HOLE_PITCH_U) * HOLE_PITCH_U + shift
    hd = np.hypot(u - cu, v - cv)
    # screen-space size of one surface unit (for anti-aliasing the holes)
    cos_lat = np.cos(lat)
    fore = np.clip(np.minimum(cos_lat, np.cos(lon) * np.where(top | bot, 1, 1)), 0.05, 1)
    px = 1.0 / (f * fore)
    hole = 1 - smoothstep(HOLE_R - 0.6 * px - 1.6, HOLE_R + 0.6 * px + 1.0, hd)
    # soft shadow ring around each hole (depth of the perforation)
    halo = gauss(hd, HOLE_R + 1.2, 1.8) * 0.16

    t = np.clip(dx / np.maximum(np.sqrt(np.maximum(R * R - ey * ey, 1)), 1), -1, 1)
    side = np.abs(t)
    metal_v = 0.91 * grille_envelope(y, side)
    hole_v = 18 + 0.16 * metal_v * (1 - smoothstep(0.0, 0.7, side))
    metal_v = metal_v * (1 - halo)
    g = metal_v * (1 - hole) + hole_v * hole
    grille_rgb = np.stack([g, g, g * 1.01], axis=-1)
    rgb, alpha = over(rgb, alpha, grille_rgb, np.where(inside | (grille_a > 0), grille_a, 0))

    # -------------------------------------------------------------- band
    band_in_x = np.abs(dx) < BAND_R
    band_a = rounded_rect_alpha(x, y, CX - BAND_R, BAND_Y0, CX + BAND_R, BAND_Y1, 10.0)
    tb = np.clip(dx / BAND_R, -1, 1)
    hprof = np.clip(0.52 + 0.46 * gauss(np.arcsin(np.clip(tb, -.9999, .9999)), -0.05, 0.62)
                    - 0.10 * gauss(np.abs(tb), 0.93, 0.05), 0, 1)
    yb = (y - BAND_Y0) / (BAND_Y1 - BAND_Y0)
    vprof = (1.0
             + 0.10 * gauss(yb, 0.05, 0.03)
             - 0.07 * smoothstep(0.55, 1.0, yb)
             - 0.30 * smoothstep(0.93, 1.0, yb)
             - 0.18 * (1 - smoothstep(0.0, 0.035, yb)))
    bv = np.clip(hprof * vprof, 0, 1) * 250
    band_rgb = np.stack([bv, bv, bv], axis=-1)
    rgb, alpha = over(rgb, alpha, band_rgb, band_a * band_in_x)

    # --------------------------------------------------------- red dot
    ddx = x - DOT_C[0]
    ddy = y - DOT_C[1]
    dr = np.hypot(ddx, ddy)
    dot_a = np.clip(DOT_R - dr + 0.5, 0, 1)
    nz = np.sqrt(np.clip(1 - (dr / DOT_R) ** 2, 0, 1))
    lamb = np.clip(0.35 + 0.65 * (nz * 0.8 - ddy / DOT_R * 0.35), 0, 1)
    spec = gauss(np.hypot(ddx + 7, ddy + 11), 0, 6.5)
    rim = smoothstep(0.80, 1.0, dr / DOT_R)
    red = np.stack([
        np.clip(150 + 150 * lamb + 120 * spec - 40 * rim, 0, 255),
        np.clip(0 + 30 * lamb * lamb + 160 * spec - 5 * rim, 0, 255),
        np.clip(0 + 30 * lamb * lamb + 160 * spec - 5 * rim, 0, 255)], axis=-1)
    # soft dark ring around the dot
    ring_a = np.clip(1 - np.abs(dr - DOT_R - 1.0) / 2.0, 0, 1) * 0.12
    rgb, alpha = over(rgb, alpha, np.zeros_like(rgb) + 60, ring_a * (dr > DOT_R - 1))
    rgb, alpha = over(rgb, alpha, red, dot_a)

    # ------------------------------------------------------ knobs/axles
    for sgn in (-1, 1):
        ax = x if sgn < 0 else (2 * CX - x)       # mirror for the right side
        axle_a = (np.clip(ax - AXLE_X0 + 0.5, 0, 1) * np.clip(AXLE_X1 - ax + 0.5, 0, 1)
                  * np.clip(y - AXLE_Y0 + 0.5, 0, 1) * np.clip(AXLE_Y1 - y + 0.5, 0, 1))
        ya = (y - AXLE_Y0) / (AXLE_Y1 - AXLE_Y0) * 2 - 1
        av = np.clip(0.40 + 0.58 * gauss(ya, -0.25, 0.42) - 0.12 * gauss(ya, 0.85, 0.15), 0, 1) * 245
        rgb, alpha = over(rgb, alpha, np.stack([av, av, av], -1), axle_a)

        knob_a = (np.clip(ax - KNOB_X0 + 0.5, 0, 1) * np.clip(KNOB_X1 - ax + 0.5, 0, 1)
                  * np.clip(y - KNOB_Y0 + 0.5, 0, 1) * np.clip(KNOB_Y1 - y + 0.5, 0, 1))
        yk = (y - KNOB_Y0) / (KNOB_Y1 - KNOB_Y0) * 2 - 1
        ridges = 0.5 + 0.5 * np.cos(2 * np.pi * (np.arcsin(np.clip(yk, -.999, .999)) * 7.5))
        kv = np.clip(0.34 + 0.52 * gauss(yk, -0.2, 0.5), 0, 1)
        kv = kv * (0.62 + 0.38 * ridges)
        xk = (ax - KNOB_X0) / (KNOB_X1 - KNOB_X0)
        kv *= 0.80 + 0.25 * gauss(xk, 0.35, 0.25)
        kv = np.clip(kv, 0, 1) * 235
        rgb, alpha = over(rgb, alpha, np.stack([kv, kv, kv], -1), knob_a)

    # --------------------------------------------------------- stem/base
    def vertical_chrome(x0, x1, y0, y1, stripes):
        a = (np.clip(x - x0 + 0.5, 0, 1) * np.clip(x1 - x + 0.5, 0, 1)
             * np.clip(y - y0 + 0.5, 0, 1) * np.clip(y1 - y + 0.5, 0, 1))
        tt = (x - x0) / (x1 - x0)
        val = np.full(x.shape, 0.16)
        for mu, sig, amp in stripes:
            val = val + amp * gauss(tt, mu, sig)
        val = np.clip(val, 0, 1) * 235
        return np.stack([val, val, val], -1), a

    s_rgb, s_a = vertical_chrome(STEM_X0, STEM_X1, STEM_Y0, STEM_Y1,
                                 [(0.10, 0.08, 0.10), (0.63, 0.13, 0.78), (0.95, 0.05, 0.2)])
    rgb, alpha = over(rgb, alpha, s_rgb, s_a)
    b_rgb, b_a = vertical_chrome(BASE_X0, BASE_X1, BASE_Y0, BASE_Y1,
                                 [(0.05, 0.05, 0.45), (0.37, 0.07, 0.75), (0.53, 0.05, 0.45),
                                  (0.80, 0.06, 0.80), (0.97, 0.03, 0.25)])
    # slight top highlight + bottom shadow on the base
    yy = (y - BASE_Y0) / (BASE_Y1 - BASE_Y0)
    b_rgb = b_rgb * (1 + 0.08 * gauss(yy, 0.08, 0.05) - 0.25 * smoothstep(0.85, 1.0, yy))[..., None]
    rgb, alpha = over(rgb, alpha, np.clip(b_rgb, 0, 255), b_a)

    # downsample
    def down(img):
        if img.ndim == 2:
            return img.reshape(H, ss, W, ss).mean(axis=(1, 3))
        return img.reshape(H, ss, W, ss, img.shape[2]).mean(axis=(1, 3))

    prem = rgb * alpha[..., None]
    a_d = down(alpha)
    rgb_d = down(prem) / np.where(a_d > 1e-6, a_d, 1)[..., None]
    out = np.dstack([np.clip(rgb_d, 0, 255), np.clip(a_d * 255, 0, 255)]).round().astype(np.uint8)
    return Image.fromarray(out, 'RGBA')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('--scale', type=float, default=4.0)
    ap.add_argument('--ss', type=int, default=3)
    args = ap.parse_args()
    render(args.scale, args.ss).save(args.out, optimize=True)


if __name__ == '__main__':
    main()
