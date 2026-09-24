"""Generates the brushed-metal background tile used on every screen.

The statistics (horizontal brightness profile, streak contrast and the
horizontal/vertical correlation lengths) were measured from 1440x3120
reference screenshots of the original app and are reproduced here with
periodic (FFT) filtering so the tile repeats seamlessly in both directions.

Usage: python3 tool/art/brushed_metal.py <out.jpg> [--size 1440] [--seed 7]
"""
import argparse

import numpy as np
from PIL import Image

# Mean luminance of the original background in 40 px bands across a
# 1440 px wide screen (left to right).
PROFILE = [70.9, 73.6, 75.8, 78.0, 80.1, 82.2, 84.3, 86.7, 89.1, 91.8, 94.6,
           97.6, 100.6, 103.5, 106.0, 108.1, 109.6, 110.2, 109.8, 108.7,
           106.8, 104.2, 101.6, 98.5, 95.3, 92.4, 89.4, 86.6, 83.9, 81.2,
           78.6, 75.9, 73.0, 70.1, 66.9, 63.8]


def periodic_noise(h, w, sigma_y, sigma_x, rng):
    """Unit-variance Gaussian-filtered white noise that tiles seamlessly."""
    n = rng.standard_normal((h, w))
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.fftfreq(w)[None, :]
    kernel = np.exp(-2 * (np.pi ** 2) * ((fy * sigma_y) ** 2 + (fx * sigma_x) ** 2))
    out = np.real(np.fft.ifft2(np.fft.fft2(n) * kernel))
    return out / out.std()


def profile(w):
    centers = (np.arange(len(PROFILE)) + 0.5) * (1440 / len(PROFILE))
    xs = (np.arange(w) + 0.5) * (1440 / w)
    return np.interp(xs, centers, PROFILE)


def generate(size=1440, seed=7, scale=1.0):
    rng = np.random.default_rng(seed)
    h = w = size
    s = size / 1440.0 * scale
    streaks = (0.92 * periodic_noise(h, w, 2.0 * s, 190 * s, rng)
               + 0.30 * periodic_noise(h, w, 2.0 * s, 32 * s, rng)
               + 0.16 * periodic_noise(h, w, 1.0 * s, 3 * s, rng))
    streaks /= streaks.std()
    base = profile(w)[None, :]
    lum = base * (1.0 + 0.0250 * streaks)
    return np.clip(lum, 0, 255)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('--size', type=int, default=1440)
    ap.add_argument('--seed', type=int, default=7)
    ap.add_argument('--quality', type=int, default=90)
    args = ap.parse_args()
    img = Image.fromarray(np.round(generate(args.size, args.seed)).astype(np.uint8), 'L')
    img.save(args.out, quality=args.quality, optimize=True)


if __name__ == '__main__':
    main()
