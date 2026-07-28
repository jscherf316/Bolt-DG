#!/usr/bin/env python3
"""Append examine-glyph catalog entries from the current queue snapshot.

Usage:  python tools/catalog-glyphs.py GLYPH_D9=1 GLYPH_UP_P=2 ...

Each NAME=INDEX pairs a catalog name with a 1-based index into the panel's
queue_snapshot.txt (dev mode). Writes to all three img_signatures.txt copies:
the live config, the live bundled seed, and the repo seed. Refuses duplicate
names and out-of-range indices.
"""

import os
import sys

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
TARGETS = [
    os.path.join(CFG, 'img_signatures.txt'),
    os.path.expandvars(
        r'%APPDATA%\bolt-launcher\data\plugins\dg-map-tracker\data\img_signatures.txt'),
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                 'plugins', 'dg-map-tracker', 'data', 'img_signatures.txt'),
]


def main(argv):
    # --from FILE: name against a FROZEN snapshot (made by render-queue.py)
    # instead of the live queue, which re-sorts whenever an admission lands --
    # naming by live index once mislabeled a 't' variant as GLYPH_UP_W.
    src = os.path.join(CFG, 'queue_snapshot.txt')
    if argv and argv[0] == '--from':
        src = argv[1]
        argv = argv[2:]
    pairs = []
    for a in argv:
        name, _, idx = a.partition('=')
        assert name and idx.isdigit(), 'bad arg: ' + a
        pairs.append((name, int(idx)))
    snap = [l.strip() for l in open(src) if l.strip()]
    lines = []
    for name, idx in pairs:
        assert 1 <= idx <= len(snap), '%s: index %d out of range (queue has %d)' % (
            name, idx, len(snap))
        w, h, hx = snap[idx - 1].split('|')
        lines.append('%s|%s|%s|%s' % (name, w, h, hx))
        print('%s <- queue index %d (%sx%s)' % (name, idx, w, h))
    for t in TARGETS:
        body = open(t).read()
        for nl in lines:
            assert nl.split('|')[0] + '|' not in body, \
                nl.split('|')[0] + ' already cataloged in ' + t
        if body and not body.endswith('\n'):
            body += '\n'
        open(t, 'w', newline='').write(body + '\n'.join(lines) + '\n')
    print('appended %d entries to %d catalog copies' % (len(lines), len(TARGETS)))


if __name__ == '__main__':
    main(sys.argv[1:])
