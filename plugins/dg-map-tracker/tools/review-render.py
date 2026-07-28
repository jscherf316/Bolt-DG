# Build review.html from resource_review.txt: a self-contained page that
# renders every marked mesh with the same z-buffered orbit rasteriser the
# resource panel uses (drag rotate, wheel zoom), plus a name box per entry
# and an export block that emits ready-to-append catalog lines
# (NAME|tier|<v1 key>). Workflow: mark things during play, run this, review
# visually, name them, paste the export back (or read the names out).
#
# A second tab (Catalog) previews everything already in resources.txt,
# grouped by type (ore/tree/herb/dino/other) and sorted by tier. Entries
# whose fingerprint still has a full mesh in the review bank/archive render
# as a rotatable 3D preview; the rest fall back to a colour-swatch strip of
# the 5-vert signature, with a line listing each duplicate print's vert count.
#
#   python tools/review-render.py            (default config dir)
#   python tools/review-render.py <dir>      (explicit plugin config dir)
import base64
import io
import json
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

DEFAULT_DIR = _find_cfg()
# Tier reference charts (herbs/ores/trees), embedded into the page as a
# fixed sidebar so tiering is a glance, not a tab-switch.
REF_IMAGES = ['herbs.png', 'ores.png', 'trees.png', 'dinos.png']
DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        os.pardir, 'data')


def parse_review(path):
    entries = []
    cur = None
    for line in io.open(path, encoding='utf-8'):
        line = line.rstrip('\n')
        if line.startswith('REVIEW|'):
            p = line.split('|')
            cur = {'time': int(p[1]), 'kind': p[2], 'label': p[3],
                   'meta': '|'.join(p[4:]), 'key': '', 'mvp': '', 'pts': ''}
            entries.append(cur)
        elif cur is not None and line.startswith('KEY|'):
            cur['key'] = line[4:]
        elif cur is not None and line.startswith('MVP|'):
            cur['mvp'] = line[4:]
        elif cur is not None and line.startswith('PTS|'):
            cur['pts'] = line[4:]
    # Dedupe by fingerprint key (double-clicks bank the same mesh twice).
    seen, out = set(), []
    for e in entries:
        if e['key'] in seen:
            continue
        seen.add(e['key'])
        out.append(e)
    return out


def parse_pts(pts):
    """PTS field -> list of {x,y,z,r,g,b} verts (triangle-ordered stream)."""
    verts = []
    for p in pts.split(';'):
        f = p.split(',')
        if len(f) < 6:
            continue
        verts.append({'x': int(f[0]), 'y': int(f[1]), 'z': int(f[2]),
                      'r': int(f[3]), 'g': int(f[4]), 'b': int(f[5])})
    return verts


def build_mesh_index(d):
    """Map fingerprint key -> full mesh verts, from the review bank + archive.
    Only ~15 cataloged keys still have a mesh here; the rest fall back to
    swatches in the Catalog tab."""
    index = {}
    for fn in ('resource_review.txt', 'resource_review_archive.txt'):
        p = os.path.join(d, fn)
        if not os.path.exists(p):
            continue
        cur = None
        for line in io.open(p, encoding='utf-8'):
            line = line.rstrip('\n')
            if line.startswith('REVIEW|'):
                cur = {'key': '', 'pts': ''}
            elif cur is not None and line.startswith('KEY|'):
                cur['key'] = line[4:]
            elif cur is not None and line.startswith('PTS|'):
                cur['pts'] = line[4:]
                if cur['key'] and cur['key'] not in index:
                    verts = parse_pts(cur['pts'])
                    if verts:
                        index[cur['key']] = verts
    return index


def resource_type(name):
    for key in ('ORE', 'TREE', 'HERB', 'DINO'):
        if key in name:
            return key.lower()
    return 'other'


GROUP_ORDER = ['ore', 'tree', 'herb', 'dino', 'other']


def parse_catalog(d, mesh_index):
    """Group resources.txt entries by name; attach a mesh (if the bank has
    one for any print) or the 5-vert signature colours, plus every print's
    vertex count. Returns groups in GROUP_ORDER, each sorted by tier."""
    p = os.path.join(d, 'resources.txt')
    by_name = {}
    if not os.path.exists(p):
        return []
    for line in io.open(p, encoding='utf-8'):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        v2 = line.startswith('V2|')
        parts = line.split('|')
        if v2:
            # V2|NAME|tier|n|...  -- no 5-vert signature to swatch/render.
            name, tier, n = parts[1], parts[2], parts[3]
            colors, key = None, None
        else:
            name, tier, n = parts[0], parts[1], parts[2]
            vparts = parts[3:]
            colors = []
            for vp in vparts:
                f = vp.split(',')
                if len(f) >= 7:
                    colors.append([int(f[4]), int(f[5]), int(f[6])])
            key = n + '|' + '|'.join(vparts)
        e = by_name.setdefault(name, {
            'name': name, 'tier': int(tier), 'prints': [],
            'colors': None, 'mesh': None})
        e['prints'].append(int(n))
        if not v2 and e['colors'] is None:
            e['colors'] = colors
        if not v2 and e['mesh'] is None and key in mesh_index:
            e['mesh'] = mesh_index[key]
    groups = {g: [] for g in GROUP_ORDER}
    for e in by_name.values():
        e['prints'].sort()
        groups[resource_type(e['name'])].append(e)
    out = []
    for g in GROUP_ORDER:
        ents = sorted(groups[g], key=lambda e: (e['tier'], e['name']))
        if ents:
            out.append({'type': g, 'entries': ents})
    return out


HTML = '''<!DOCTYPE html><html><head><meta charset="utf-8">
<title>resource review</title>
<style>
  body { background: #14100a; color: #cbb; font: 13px monospace; margin: 16px; }
  h2 { color: #dab260; }
  .row { display: flex; gap: 14px; margin-bottom: 18px; align-items: flex-start;
         border: 1px solid #3a3226; border-radius: 6px; padding: 10px; }
  canvas { background: #1e1a12; border: 1px solid #3a3226; cursor: grab; }
  .meta { flex: 1; }
  .meta div { margin-bottom: 6px; }
  input { background: #2a2418; color: #eee; border: 1px solid #3a3226;
          padding: 3px 6px; font: 13px monospace; width: 180px; }
  .hint { color: #776; font-size: 11px; }
  textarea { width: 100%; height: 140px; background: #1e1a12; color: #cbb;
             border: 1px solid #3a3226; font: 12px monospace; }
  button { background: #2a2418; color: #dab260; border: 1px solid #3a3226;
           padding: 4px 10px; cursor: pointer; }
  #main { margin-right: 820px; }
  #refs { position: fixed; top: 0; right: 0; bottom: 0; width: 800px;
          overflow-y: auto; background: #100d08; border-left: 1px solid #3a3226;
          padding: 10px; box-sizing: border-box; }
  #refs h3 { color: #dab260; margin: 8px 0 4px 0; font-size: 13px;
             text-transform: uppercase; }
  #refs img { width: 100%; display: block; border: 1px solid #3a3226;
              border-radius: 4px; margin-bottom: 10px; }
  #tabs { margin-bottom: 14px; }
  .tab { margin-right: 6px; }
  .tab.active { background: #dab260; color: #14100a; }
  .tabpage { display: none; }
  .tabpage.active { display: block; }
  .grid { display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 22px; }
  .card { width: 160px; border: 1px solid #3a3226; border-radius: 6px;
          padding: 8px; box-sizing: border-box; background: #17130b; }
  .card canvas { width: 142px; height: 142px; }
  .swatch { display: flex; width: 142px; height: 142px;
            border: 1px solid #3a3226; }
  .swatch div { flex: 1; }
  .clabel { margin-top: 6px; }
  .clabel .tier { color: #776; }
  .verts { color: #998; font-size: 11px; margin-top: 4px; }
</style></head><body>
<div id="refs">__REFS__</div>
<div id="main">
<div id="tabs">
  <button class="tab" id="tab-review-btn" data-page="page-review">Review (__COUNT__)</button>
  <button class="tab" id="tab-catalog-btn" data-page="page-catalog">Catalog (__CATCOUNT__)</button>
</div>

<div class="tabpage" id="page-review">
<h2>resource review (__COUNT__ meshes)</h2>
<div class="hint">drag = rotate, wheel = zoom. Type a catalog name per entry
(e.g. T7_TREE, T10_DINO); tier is read from the name. Then Export.</div>
<div id="rows"></div>
<h2>export</h2>
<button id="export">Build catalog lines</button>
<textarea id="out" placeholder="NAME|tier|key lines appear here"></textarea>
</div>

<div class="tabpage" id="page-catalog">
<h2>catalog (__CATCOUNT__ resources)</h2>
<div class="hint">everything in resources.txt, grouped by type and sorted by
tier. A 3D preview where the bank still has the mesh; otherwise a colour
swatch of the fingerprint plus each duplicate print's vertex count.</div>
<div id="catalog"></div>
</div>
</div>
<script>
const DATA = __DATA__;
const CATALOG = __CATALOG__;
const rows = document.getElementById("rows");
DATA.forEach((e, i) => {
  const row = document.createElement("div"); row.className = "row";
  const cv = document.createElement("canvas"); cv.width = 260; cv.height = 260;
  row.appendChild(cv);
  const meta = document.createElement("div"); meta.className = "meta";
  meta.innerHTML = `<div><b>#${i + 1}</b>  ${e.kind}  label=${e.label}</div>` +
    `<div>${e.meta}</div>` +
    `<div>verts captured: ${e.verts.length}</div>` +
    `<div>name: <input id="nm${i}" placeholder="T?_TYPE"></div>`;
  row.appendChild(meta);
  rows.appendChild(row);
  attachViewer(cv, e.verts);
});
function attachViewer(canvas, verts) {
  let yaw = Math.PI / 4, pitch = 0.5, zoom = 1;
  let cx = 0, cy = 0, cz = 0;
  for (const v of verts) { cx += v.x; cy += v.y; cz += v.z; }
  const n = Math.max(1, verts.length);
  cx /= n; cy /= n; cz /= n;
  let r2 = 1;
  for (const v of verts) {
    const dx = v.x - cx, dy = v.y - cy, dz = v.z - cz;
    r2 = Math.max(r2, dx*dx + dy*dy + dz*dz);
  }
  const radius = Math.sqrt(r2);
  const draw = () => {
    const w = canvas.width, h = canvas.height;
    const ctx = canvas.getContext("2d");
    ctx.fillStyle = "#1e1a12"; ctx.fillRect(0, 0, w, h);
    const cyw = Math.cos(yaw), syw = Math.sin(yaw);
    const cp = Math.cos(pitch), sp = Math.sin(pitch);
    const A = [[cyw, 0, syw], [sp*syw, cp, -sp*cyw], [-cp*syw, sp, cp*cyw]];
    const s = 1 / (radius * 1.1 / zoom);
    const P = new Array(verts.length);
    for (let i = 0; i < verts.length; i++) {
      const v = verts[i];
      const x = v.x - cx, y = v.y - cy, z = v.z - cz;
      P[i] = {
        px: ( (A[0][0]*x + A[0][1]*y + A[0][2]*z) * s * 0.5 + 0.5) * w,
        py: (-(A[1][0]*x + A[1][1]*y + A[1][2]*z) * s * 0.5 + 0.5) * h,
        z:  -(A[2][0]*x + A[2][1]*y + A[2][2]*z),
        r: v.r, g: v.g, b: v.b,
      };
    }
    const img = ctx.getImageData(0, 0, w, h);
    const px = img.data;
    const zbuf = new Float32Array(w * h); zbuf.fill(Infinity);
    const edge = (ax, ay, bx, by, ex, ey) => (bx-ax)*(ey-ay) - (by-ay)*(ex-ax);
    for (let t = 0; t + 2 < P.length; t += 3) {
      const v0 = P[t], v1 = P[t+1], v2 = P[t+2];
      const area = edge(v0.px, v0.py, v1.px, v1.py, v2.px, v2.py);
      if (area === 0) continue;
      const minx = Math.max(0, Math.floor(Math.min(v0.px, v1.px, v2.px)));
      const maxx = Math.min(w - 1, Math.floor(Math.max(v0.px, v1.px, v2.px)));
      const miny = Math.max(0, Math.floor(Math.min(v0.py, v1.py, v2.py)));
      const maxy = Math.min(h - 1, Math.floor(Math.max(v0.py, v1.py, v2.py)));
      for (let y = miny; y <= maxy; y++) {
        for (let x = minx; x <= maxx; x++) {
          const fx = x + 0.5, fy = y + 0.5;
          const w0 = edge(v1.px, v1.py, v2.px, v2.py, fx, fy) / area;
          const w1 = edge(v2.px, v2.py, v0.px, v0.py, fx, fy) / area;
          const w2 = edge(v0.px, v0.py, v1.px, v1.py, fx, fy) / area;
          if (w0 < 0 || w1 < 0 || w2 < 0) continue;
          const z = w0*v0.z + w1*v1.z + w2*v2.z;
          const off = y * w + x;
          if (z >= zbuf[off]) continue;
          zbuf[off] = z;
          const po = off * 4;
          px[po]   = Math.min(255, Math.floor(w0*v0.r + w1*v1.r + w2*v2.r));
          px[po+1] = Math.min(255, Math.floor(w0*v0.g + w1*v1.g + w2*v2.g));
          px[po+2] = Math.min(255, Math.floor(w0*v0.b + w1*v1.b + w2*v2.b));
          px[po+3] = 255;
        }
      }
    }
    ctx.putImageData(img, 0, 0);
  };
  let drag = null;
  canvas.addEventListener("mousedown", (e) => { drag = {x: e.clientX, y: e.clientY}; e.preventDefault(); });
  window.addEventListener("mousemove", (e) => {
    if (!drag) return;
    yaw += (e.clientX - drag.x) * 0.012;
    pitch = Math.max(-1.55, Math.min(1.55, pitch + (e.clientY - drag.y) * 0.012));
    drag = {x: e.clientX, y: e.clientY};
    draw();
  });
  window.addEventListener("mouseup", () => { drag = null; });
  canvas.addEventListener("wheel", (e) => {
    e.preventDefault();
    zoom = Math.max(0.2, Math.min(8, zoom * (e.deltaY < 0 ? 1.12 : 1/1.12)));
    draw();
  }, { passive: false });
  draw();
}
document.getElementById("export").addEventListener("click", () => {
  const lines = [];
  DATA.forEach((e, i) => {
    const nm = document.getElementById("nm" + i).value.trim();
    if (!nm) return;
    const m = nm.match(/^[Tt](\\d+)_/);
    const tier = m ? m[1] : "0";
    lines.push(`${nm.toUpperCase()}|${tier}|${e.key}`);
  });
  document.getElementById("out").value = lines.join("\\n");
});

// ---- Catalog tab -----------------------------------------------------------
const catalog = document.getElementById("catalog");
CATALOG.forEach(group => {
  const total = group.entries.length;
  const h = document.createElement("h2");
  h.textContent = group.type.toUpperCase() + " (" + total + ")";
  catalog.appendChild(h);
  const grid = document.createElement("div"); grid.className = "grid";
  group.entries.forEach(e => {
    const card = document.createElement("div"); card.className = "card";
    if (e.mesh) {
      const cv = document.createElement("canvas");
      cv.width = 142; cv.height = 142;
      card.appendChild(cv);
      attachViewer(cv, e.mesh);
    } else {
      const sw = document.createElement("div"); sw.className = "swatch";
      (e.colors || []).forEach(c => {
        const d = document.createElement("div");
        d.style.background = `rgb(${c[0]},${c[1]},${c[2]})`;
        sw.appendChild(d);
      });
      card.appendChild(sw);
    }
    const label = document.createElement("div"); label.className = "clabel";
    label.innerHTML = `<b>${e.name}</b> <span class="tier">T${e.tier}</span>`;
    card.appendChild(label);
    if (!e.mesh) {
      const vl = document.createElement("div"); vl.className = "verts";
      const nprints = e.prints.length;
      vl.textContent = nprints + " print" + (nprints > 1 ? "s" : "") +
        ": " + e.prints.join(", ") + " verts";
      card.appendChild(vl);
    }
    grid.appendChild(card);
  });
  catalog.appendChild(grid);
});

// ---- Tab switching ---------------------------------------------------------
const tabBtns = document.querySelectorAll(".tab");
function showPage(pageId) {
  document.querySelectorAll(".tabpage").forEach(p =>
    p.classList.toggle("active", p.id === pageId));
  tabBtns.forEach(b => b.classList.toggle("active", b.dataset.page === pageId));
}
tabBtns.forEach(b => b.addEventListener("click", () => showPage(b.dataset.page)));
showPage(DATA.length ? "page-review" : "page-catalog");
</script></body></html>
'''


# Every catalog that NAMES a mesh by v1 fingerprint. A mark is done with review
# once it appears in any of them -- not just resources.txt. Guardian doors and
# puzzle ghosts are identified meshes that deliberately never become resources
# (they must not reach the queue, the catalog or the parity evidence), so
# reading only resources.txt left them stranded in the review list forever.
NAMED_CATALOGS = ('resources.txt', 'guardian_doors.txt', 'ghosts.txt')


def catalog_keys(d):
    """v1 fingerprint keys already named: NAME|tier|<key> lines."""
    keys = set()
    for fn in NAMED_CATALOGS:
        p = os.path.join(d, fn)
        if not os.path.exists(p):
            continue
        for line in io.open(p, encoding='utf-8'):
            line = line.strip()
            if not line or line.startswith('#') or line.startswith('V2|'):
                continue
            parts = line.split('|', 2)
            if len(parts) == 3:
                keys.add(parts[2])
    return keys


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DIR
    src = os.path.join(d, 'resource_review.txt')
    entries = parse_review(src)
    # Resolved marks disappear: anything whose fingerprint is now cataloged
    # (named via export, the queue flow, or a self-upgrade) is done with
    # review. The bank file keeps everything as history.
    done = catalog_keys(d)
    before = len(entries)
    entries = [e for e in entries if e['key'] not in done]
    skipped = before - len(entries)
    data = []
    for e in entries:
        data.append({'kind': e['kind'], 'label': e['label'], 'meta': e['meta'],
                     'key': e['key'], 'verts': parse_pts(e['pts'])})
    mesh_index = build_mesh_index(d)
    catalog = parse_catalog(d, mesh_index)
    cat_count = sum(len(g['entries']) for g in catalog)
    cat_meshes = sum(1 for g in catalog for e in g['entries'] if e['mesh'])
    refs = []
    for name in REF_IMAGES:
        p = os.path.join(DATA_DIR, name)
        if not os.path.exists(p):
            continue
        b64 = base64.b64encode(open(p, 'rb').read()).decode('ascii')
        title = os.path.splitext(name)[0]
        refs.append('<h3>%s</h3><img src="data:image/png;base64,%s">'
                    % (title, b64))
    out = os.path.join(d, 'review.html')
    html = HTML.replace('__COUNT__', str(len(data)))
    html = html.replace('__CATCOUNT__', str(cat_count))
    html = html.replace('__REFS__', '\n'.join(refs)
                        or '<div class="hint">(no tier charts in data/)</div>')
    html = html.replace('__DATA__', json.dumps(data))
    html = html.replace('__CATALOG__', json.dumps(catalog))
    io.open(out, 'w', encoding='utf-8').write(html)
    print('%d review meshes (%d cataloged, hidden); catalog %d resources '
          '(%d with 3D mesh, %d swatch); %d tier charts -> %s'
          % (len(data), skipped, cat_count, cat_meshes,
             cat_count - cat_meshes, len(refs), out))


if __name__ == '__main__':
    main()
