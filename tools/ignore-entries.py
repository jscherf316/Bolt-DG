#!/usr/bin/env python3
"""Append queue entries to the ignore list by index.

Usage:  python tools/ignore-entries.py [--from FILE] IDX [IDX ...]

Indices are 1-based into the (frozen) queue snapshot. Writes the w|h|hex
lines to all three img_ignored.txt copies (live config, live seed, repo seed).
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
    os.path.join(CFG, 'img_ignored.txt'),
    os.path.expandvars(
        r'%APPDATA%\bolt-launcher\data\plugins\dg-map-tracker\data\img_ignored.txt'),
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                 'plugins', 'dg-map-tracker', 'data', 'img_ignored.txt'),
]


def main(argv):
    src = os.path.join(CFG, 'queue_snapshot.txt')
    if argv and argv[0] == '--from':
        src = argv[1]
        argv = argv[2:]
    idxs = [int(a) for a in argv]
    snap = [l.strip() for l in open(src) if l.strip()]
    lines = []
    for i in idxs:
        assert 1 <= i <= len(snap), 'index %d out of range (%d entries)' % (i, len(snap))
        lines.append(snap[i - 1])
        print('ignoring index %d (%sx%s)' % (i, snap[i - 1].split('|')[0],
                                             snap[i - 1].split('|')[1]))
    for t in TARGETS:
        body = open(t).read()
        add = [l for l in lines if l not in body]
        if not add:
            continue
        if body and not body.endswith('\n'):
            body += '\n'
        open(t, 'w', newline='').write(body + '\n'.join(add) + '\n')
    print('appended to %d ignore-list copies' % len(TARGETS))


if __name__ == '__main__':
    main(sys.argv[1:])
