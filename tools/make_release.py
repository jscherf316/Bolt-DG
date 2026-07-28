# Build a one-click-install release for Bolt's plugin manager.
#
#   python tools/make_release.py
#
# Produces dist/bolt-dg-v<version>.tar.gz (version read from bolt.json) and
# rewrites meta.json at the repo root:
#
#   { "sha256": ..., "version": ..., "url": ... }
#
# Bolt's installer (window_launcher.cxx InstallPlugin) extracts the archive
# with libarchive DIRECTLY into the plugin dir, so bolt.json must be at the
# ARCHIVE ROOT -- the archive holds the plugin folder's contents, not the
# folder. gzip because that is what Windows' bsdtar and every libarchive build
# can do; the installer enables all formats/filters.
#
# After running: upload the tarball as a release asset at the URL meta.json
# names (gh release create/upload), then commit meta.json.
import hashlib
import io
import json
import os
import subprocess
import tarfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN = os.path.join(REPO, 'plugins', 'dg-map-tracker')
DIST = os.path.join(REPO, 'dist')

# Runtime files only: cataloguing/dev tooling stays out of user installs.
EXCLUDE_DIRS = { 'test', 'tools', '__pycache__' }

version = json.load(io.open(os.path.join(PLUGIN, 'bolt.json'), encoding='utf-8'))['version']
name = 'bolt-dg-v%s.tar.gz' % version
os.path.isdir(DIST) or os.makedirs(DIST)
out_path = os.path.join(DIST, name)

# GIT-TRACKED files only. Walking the directory swept in gitignored local
# working files (plan docs) on the first run -- a release must never contain
# anything the repo does not.
tracked = subprocess.check_output(
    ['git', '-C', REPO, 'ls-files', 'plugins/dg-map-tracker'], text=True).splitlines()
entries = []
for rel in sorted(tracked):
    arc = rel[len('plugins/dg-map-tracker/'):]
    if arc.split('/')[0] in EXCLUDE_DIRS:
        continue
    entries.append((os.path.join(REPO, rel.replace('/', os.sep)), arc))

# Deterministic-ish: fixed mtime/owner so rebuilding an identical tree yields
# an identical archive (and therefore an unchanged sha256).
with tarfile.open(out_path, 'w:gz', compresslevel=9) as tf:
    for p, arc in entries:
        ti = tf.gettarinfo(p, arcname=arc)
        ti.mtime, ti.uid, ti.gid, ti.uname, ti.gname = 0, 0, 0, '', ''
        with open(p, 'rb') as f:
            tf.addfile(ti, f)

sha = hashlib.sha256(open(out_path, 'rb').read()).hexdigest()
meta = {
    'sha256': sha,
    'version': version,
    'url': 'https://github.com/jscherf316/Bolt-DG/releases/download/v%s/%s' % (version, name),
}
io.open(os.path.join(REPO, 'meta.json'), 'w', encoding='utf-8', newline='\n').write(
    json.dumps(meta, indent=2) + '\n')

print('archive : %s (%d files, %d bytes)' % (out_path, len(entries), os.path.getsize(out_path)))
print('sha256  : %s' % sha)
print('meta.json updated -> %s' % meta['url'])
