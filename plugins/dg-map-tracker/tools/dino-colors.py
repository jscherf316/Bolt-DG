# Regenerate data/dino_colors.txt: the per-tier dino body-colour reference the
# runtime classifier matches live sightings against. Each line is
#   <tier>|<medR>,<medG>,<medB>
# computed as the median vertex colour over the full point cloud of every
# T<n>_DINO capture found in the review files, matched to tier by the catalog
# fingerprint key. Re-run whenever new dino tiers/poses are labelled.
#
#   python tools/dino-colors.py            (default config dir + repo data/)
import io
import os
import statistics
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

DEFAULT_CFG = _find_cfg()
DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, 'data')


def main():
    cfg = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_CFG
    # catalog fingerprint-key -> tier, for dinos
    key2tier = {}
    for line in io.open(os.path.join(cfg, 'resources.txt'), encoding='utf-8'):
        if line.startswith('V2|') or '_DINO' not in line:
            continue
        p = line.strip().split('|', 2)
        if len(p) == 3 and '_DINO' in p[0]:
            key2tier[p[2]] = int(p[0].split('_')[0][1:])

    # collect every dino point cloud from the review files, per tier
    clouds = {}   # tier -> list of point-cloud strings

    def scan(path):
        if not os.path.exists(path):
            return
        key = None
        for line in io.open(path, encoding='utf-8'):
            line = line.rstrip('\n')
            if line.startswith('KEY|'):
                key = line[4:]
            elif line.startswith('PTS|'):
                if key in key2tier and line[4:]:
                    clouds.setdefault(key2tier[key], []).append(line[4:])
                key = None

    scan(os.path.join(cfg, 'resource_review.txt'))
    scan(os.path.join(cfg, 'resource_review_archive.txt'))

    out = []
    for tier in sorted(clouds):
        R, G, B = [], [], []
        for pts in clouds[tier]:
            for v in pts.split(';'):
                f = v.split(',')
                if len(f) >= 6:
                    R.append(int(f[3])); G.append(int(f[4])); B.append(int(f[5]))
        if R:
            out.append('%d|%d,%d,%d' % (tier, int(statistics.median(R)),
                                        int(statistics.median(G)), int(statistics.median(B))))
    text = ('# dino body-colour references (median vertex RGB per tier), from\n'
            '# labelled review captures. Regenerate with tools/dino-colors.py.\n'
            '# tier|R,G,B\n' + '\n'.join(out) + '\n')
    for dest in (os.path.join(DATA_DIR, 'dino_colors.txt'),
                 os.path.join(cfg, 'dino_colors.txt')):
        io.open(dest, 'w', encoding='utf-8').write(text)
    print('%d tiers -> dino_colors.txt' % len(out))
    print('\n'.join(out))


if __name__ == '__main__':
    main()
