#!/usr/bin/env python3
"""Render a queue snapshot (w|h|hex lines) to an indexed contact sheet PNG.

Usage:  python tools/render-queue.py [input_txt] [output_png]

Defaults: input = the live queue_snapshot.txt, output = frozen_sheet.png in
the input's directory. Also copies the input to <output dir>/frozen_queue.txt
so namings can reference a stable snapshot while the live queue churns.
"""

import os
import shutil
import sys

from PIL import Image, ImageDraw

def _find_cfg():
    """This plugin's config dir, discovered from bolt's plugins.json --
    the install UUID differs per machine, so it is never hardcoded."""
    import json
    base = os.path.join(os.environ.get('APPDATA', ''), 'bolt-launcher')
    try:
        with open(os.path.join(base, 'config', 'plugins.json')) as f:
            for uuid, e in json.load(f).items():
                p = e.get('path', '') if isinstance(e, dict) else ''
                if p.replace(chr(92), '/').rstrip('/').endswith('dg-map-tracker'):
                    return os.path.join(base, 'config', 'plugins', uuid)
    except Exception:
        pass
    raise SystemExit('dg-map-tracker not found in plugins.json')

CFG = _find_cfg()


def main(argv):
    inp = argv[0] if len(argv) > 0 else os.path.join(CFG, 'queue_snapshot.txt')
    out = argv[1] if len(argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(inp)), 'frozen_sheet.png')
    frozen = os.path.join(os.path.dirname(os.path.abspath(out)), 'frozen_queue.txt')
    shutil.copy(inp, frozen)
    lines = [l.strip() for l in open(frozen) if l.strip()]
    imgs = []
    for l in lines:
        w, h, hx = l.split('|')
        imgs.append(Image.frombytes('RGBA', (int(w), int(h)), bytes.fromhex(hx)))
    scale, cw, ch, cols = 5, 180, 190, 7
    rows = (len(imgs) + cols - 1) // cols
    sheet = Image.new('RGBA', (cols * cw, max(1, rows) * ch), (90, 90, 120, 255))
    d = ImageDraw.Draw(sheet)
    for idx, im in enumerate(imgs):
        big = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
        x, y = idx % cols * cw, idx // cols * ch
        sheet.paste(big, (x + (cw - big.width) // 2, y + 8), big)
        d.text((x + cw // 2 - 10, y + ch - 16), str(idx + 1),
               fill=(255, 230, 90, 255))
    sheet.save(out)
    print('%d entries -> %s' % (len(imgs), out))
    print('frozen copy: %s' % frozen)


if __name__ == '__main__':
    main(sys.argv[1:])
