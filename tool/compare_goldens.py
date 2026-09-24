"""Puts each golden render next to the matching reference screenshot.

For every screen it writes <out>/<name>_compare.png with three panels:
reference | render | difference (amplified), and prints the mean absolute
difference of the app area (status and navigation bars excluded).

Usage: python3 tool/compare_goldens.py <reference_dir> [<out_dir>]
  reference_dir holds recorder.jpg, delete_dialog.jpg, rename_dialog.jpg,
  list.jpg and settings.jpg (1440x3120 screenshots of the original app).
"""
import os
import sys

import numpy as np
from PIL import Image

PAIRS = {
    'recorder': 'recorder',
    'delete_dialog': 'delete_dialog',
    'rename_dialog': 'rename_dialog',
    'recording_list': 'list',
    'settings': 'settings',
}
STATUS, NAV = 150, 56


def main():
    ref_dir = sys.argv[1]
    out_dir = sys.argv[2] if len(sys.argv) > 2 else '.'
    os.makedirs(out_dir, exist_ok=True)
    here = os.path.dirname(os.path.abspath(__file__))
    goldens = os.path.join(here, '..', 'test', 'golden', 'goldens')
    for golden, ref in PAIRS.items():
        g = Image.open(os.path.join(goldens, golden + '.png')).convert('RGB')
        r = Image.open(os.path.join(ref_dir, ref + '.jpg')).convert('RGB').resize(g.size)
        a = np.asarray(r).astype(int)
        b = np.asarray(g).astype(int)
        area = (slice(STATUS, a.shape[0] - NAV), slice(None))
        diff = np.abs(a - b)
        mad = diff[area].mean()
        vis = np.clip(diff.max(axis=2) * 3, 0, 255).astype(np.uint8)
        w, h = g.size
        canvas = Image.new('RGB', (w * 3 + 40, h), (255, 255, 255))
        canvas.paste(r, (0, 0))
        canvas.paste(g, (w + 20, 0))
        canvas.paste(Image.fromarray(vis).convert('RGB'), (2 * w + 40, 0))
        canvas = canvas.resize((canvas.width // 3, canvas.height // 3), Image.LANCZOS)
        path = os.path.join(out_dir, golden + '_compare.png')
        canvas.save(path)
        print('%-15s mean abs diff %.1f  -> %s' % (golden, mad, path))


if __name__ == '__main__':
    main()
