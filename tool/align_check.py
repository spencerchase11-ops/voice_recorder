"""Measures how far each UI element of a golden render is shifted relative to
the reference screenshot (cross-correlation over a small search window).

Usage: python3 tool/align_check.py <reference.jpg> <golden.png> name:x0,y0,x1,y1 ...
Coordinates are in 1440x3120 reference pixels. Prints dx, dy in px and dp.
"""
import sys

import numpy as np
from PIL import Image


def load(path):
    return np.asarray(Image.open(path).convert('L')).astype(float)


def best_shift(ref, img, box, search=10):
    x0, y0, x1, y1 = box
    r = ref[y0:y1, x0:x1]
    r = r - r.mean()
    best = (0, 0, -1e18)
    for dy in range(-search, search + 1):
        for dx in range(-search, search + 1):
            c = img[y0 + dy:y1 + dy, x0 + dx:x1 + dx]
            if c.shape != r.shape:
                continue
            c = c - c.mean()
            score = (r * c).sum() / (np.sqrt((r * r).sum() * (c * c).sum()) + 1e-9)
            if score > best[2]:
                best = (dx, dy, score)
    return best


def main():
    ref = load(sys.argv[1])
    img = load(sys.argv[2])
    for spec in sys.argv[3:]:
        name, coords = spec.split(':')
        box = tuple(int(v) for v in coords.split(','))
        dx, dy, score = best_shift(ref, img, box)
        print('%-16s dx=%+3d dy=%+3d px  (%+.2f, %+.2f dp)  corr=%.3f' % (name, dx, dy, dx / 3.5, dy / 3.5, score))


if __name__ == '__main__':
    main()
