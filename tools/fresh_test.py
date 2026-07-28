# Fresh-install test harness for dg-map-tracker.
#
#   python tools/fresh_test.py start    swap to a fresh install
#   python tools/fresh_test.py stop     swap back to the real setup
#   python tools/fresh_test.py status   which mode, and what is stashed
#
# A bolt "install" is exactly two directories:
#   deploy dir : %APPDATA%\bolt-launcher\data\plugins\dg-map-tracker\
#                (what Bolt loads; found via config\plugins.json, never assumed)
#   config dir : %APPDATA%\bolt-launcher\config\plugins\<uuid>\
#                (settings.json + every seeded catalog + all accumulated state)
#
# start:
#   - refuses if a fresh test is already active (crash-safe: marker file)
#   - stashes BOTH dirs by os.rename -- atomic on one volume, the real config
#     is never copied and never deleted, only moved aside
#   - deploys the plugin from git HEAD via `git archive` (NOT the working
#     tree -- "latest commit" means the commit)
#   - creates an EMPTY config dir, so load_or_seed seeds every catalog from
#     data/ exactly the way a brand-new user's install would
# stop:
#   - parks the fresh session's config as fresh-last\ (post-mortem material;
#     each run replaces the previous parked one)
#   - renames the real config and real deploy back into place
#
# MANUAL STEP EITHER SIDE: toggle the plugin OFF in Bolt before start/stop and
# ON after. The running plugin re-reads settings.json every ~30 frames and
# writes state continuously; swapping directories under it mid-session makes it
# adopt the wrong world. Bolt itself can stay open.
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import time

APPDATA = os.environ['APPDATA']
BOLT    = os.path.join(APPDATA, 'bolt-launcher')
STASH   = os.path.join(BOLT, 'fresh-test-stash')
MARKER  = os.path.join(STASH, 'ACTIVE.txt')
REPO    = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN  = 'dg-map-tracker'

CFG_REAL    = os.path.join(STASH, 'config-real')
DEPLOY_REAL = os.path.join(STASH, 'deploy-real')
FRESH_LAST  = os.path.join(STASH, 'fresh-last')


def find_install():
    """uuid + deploy path straight from plugins.json -- the loader's authority."""
    pj = json.load(io.open(os.path.join(BOLT, 'config', 'plugins.json'),
                           encoding='utf-8'))
    for uuid, e in pj.items():
        if isinstance(e, dict) and e.get('path', '').replace('\\', '/').rstrip('/').endswith(PLUGIN):
            return uuid, e['path'].rstrip('\\/')
    raise SystemExit('ERROR: no %s entry in plugins.json' % PLUGIN)


def head_commit():
    return subprocess.check_output(
        ['git', '-C', REPO, 'rev-parse', '--short', 'HEAD'], text=True).strip()


def deploy_from_head(deploy_dir):
    """Extract plugins/<PLUGIN>/ from git HEAD into deploy_dir (which must not
    exist yet). Faithful to what a user downloading the latest commit gets."""
    tar_bytes = subprocess.check_output(
        ['git', '-C', REPO, 'archive', 'HEAD', 'plugins/' + PLUGIN])
    prefix = 'plugins/' + PLUGIN + '/'
    if not os.path.isdir(deploy_dir):
        os.makedirs(deploy_dir)
    with tarfile.open(fileobj=io.BytesIO(tar_bytes)) as tf:
        for m in tf.getmembers():
            if not m.name.startswith(prefix) or not m.isfile():
                continue
            rel = m.name[len(prefix):]
            dst = os.path.join(deploy_dir, rel.replace('/', os.sep))
            d = os.path.dirname(dst)
            if d and not os.path.isdir(d):
                os.makedirs(d)
            with open(dst, 'wb') as f:
                f.write(tf.extractfile(m).read())


def move_contents(src, dst):
    """Rename every child of src into dst (created if needed), leaving src in
    place but empty. Bolt holds an open handle on the config/deploy DIRECTORIES
    themselves (measured 2026-07-27: the dir rename fails with WinError 32
    while every file inside renames fine), so the directories stay put and only
    their contents swap."""
    if not os.path.isdir(dst):
        os.makedirs(dst)
    for n in os.listdir(src):
        os.rename(os.path.join(src, n), os.path.join(dst, n))


def start():
    if os.path.exists(MARKER):
        raise SystemExit('ERROR: fresh test already ACTIVE (%s). Run stop first.'
                         % MARKER)
    uuid, deploy = find_install()
    cfg = os.path.join(BOLT, 'config', 'plugins', uuid)
    for p in (CFG_REAL, DEPLOY_REAL):
        if os.path.exists(p):
            raise SystemExit('ERROR: leftover stash at %s -- a previous cycle did '
                             'not finish. Sort that out by hand first; refusing '
                             'to overwrite it.' % p)
    if not os.path.isdir(STASH):
        os.makedirs(STASH)
    head = head_commit()

    # Stash CONTENTS by rename. Never copied, never deleted; the directories
    # themselves stay put because Bolt holds handles on them.
    if os.path.isdir(cfg) and os.listdir(cfg):
        move_contents(cfg, CFG_REAL)
        print('stashed real config  -> %s' % CFG_REAL)
    else:
        print('note: config dir missing or empty (already fresh?)')
    if os.path.isdir(deploy) and os.listdir(deploy):
        move_contents(deploy, DEPLOY_REAL)
        print('stashed real deploy  -> %s' % DEPLOY_REAL)

    deploy_from_head(deploy)
    if not os.path.isdir(cfg):
        os.makedirs(cfg)
    io.open(MARKER, 'w', encoding='utf-8').write(
        'started %s\nhead %s\nuuid %s\n'
        % (time.strftime('%Y-%m-%d %H:%M:%S'), head, uuid))
    print('deployed HEAD (%s)   -> %s' % (head, deploy))
    print('created empty config -> %s' % cfg)
    print('\nFRESH TEST ACTIVE. Toggle the plugin ON in Bolt to begin.')


def stop():
    if not os.path.exists(MARKER):
        raise SystemExit('ERROR: no fresh test active.')
    uuid, deploy = find_install()
    cfg = os.path.join(BOLT, 'config', 'plugins', uuid)

    # Park the fresh session for post-mortem (replacing the previous one),
    # then restore the real contents by rename. Same contents-not-directory
    # discipline as start(), for the same open-handle reason.
    if os.path.isdir(FRESH_LAST):
        shutil.rmtree(FRESH_LAST)
    if os.path.isdir(cfg) and os.listdir(cfg):
        move_contents(cfg, FRESH_LAST)
        print('parked fresh config  -> %s' % FRESH_LAST)
    if os.path.isdir(CFG_REAL):
        move_contents(CFG_REAL, cfg)
        os.rmdir(CFG_REAL)
        print('restored real config -> %s' % cfg)
    if os.path.isdir(deploy):
        for n in os.listdir(deploy):       # fresh deploy is disposable
            p = os.path.join(deploy, n)
            if os.path.isdir(p):
                shutil.rmtree(p)
            else:
                os.remove(p)
    if os.path.isdir(DEPLOY_REAL):
        move_contents(DEPLOY_REAL, deploy)
        os.rmdir(DEPLOY_REAL)
        print('restored real deploy -> %s' % deploy)
    os.remove(MARKER)
    print('\nBACK TO NORMAL. Toggle the plugin ON in Bolt.')


def status():
    active = os.path.exists(MARKER)
    print('mode: %s' % ('FRESH TEST ACTIVE' if active else 'normal'))
    if active:
        print(io.open(MARKER, encoding='utf-8').read().rstrip())
    uuid, deploy = find_install()
    print('uuid   : %s' % uuid)
    print('deploy : %s' % deploy)
    print('config : %s' % os.path.join(BOLT, 'config', 'plugins', uuid))
    print('repo   : %s (HEAD %s)' % (REPO, head_commit()))
    for label, p in (('stash config-real', CFG_REAL),
                     ('stash deploy-real', DEPLOY_REAL),
                     ('parked fresh-last', FRESH_LAST)):
        print('%-18s: %s' % (label, 'present' if os.path.isdir(p) else '-'))


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'status'
    if cmd == 'start':
        start()
    elif cmd == 'stop':
        stop()
    else:
        status()
