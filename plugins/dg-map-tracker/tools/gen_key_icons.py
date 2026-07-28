#!/usr/bin/env python3
"""Regenerate key_icons.txt (cursor-hint images) from the captured key meshes.

Rasterises every color_shape key in icons.txt from its mesh in icons_data.txt,
using the SAME math as the keys.html / rooms.html panel rasterisers (including
the per-shape rotations saved in shape_rot.txt), and writes the results in
key_icons.txt format: name|w|h|rgba_hex. Replaces the low-res icon images that
were originally captured from the minimap plugin.

Reads from the LIVE config dir; writes key_icons.txt there, to the repo seed
(data/key_icons.txt), and to the deployed plugin's data/ copy. Also drops a
contact-sheet PNG next to this script for eyeballing (git-ignored by name).

Usage: python tools/gen_key_icons.py [--dry-run]
"""
import json
import math
import os
import sys

CFG = os.path.expandvars(
    r"%APPDATA%\bolt-launcher\config\plugins\075a2748-ac3e-4fd2-9626-4964463427bf")
REPO_DATA = os.path.join(os.path.dirname(__file__), "..", "data")
DEPLOY_DATA = os.path.expandvars(
    r"%APPDATA%\bolt-launcher\data\plugins\dg-map-tracker\data")

# Must stay in sync with keys.html / rooms.html rasterisers.
ATLAS_PX = 64
SS = 4
LIGHT = (-0.5, 0.71, -0.5)
BASE, RANGE = 0.70, 0.85
DEFAULT_ROT = {"pitch": 0, "yaw": 0, "roll": 0, "scale": 1, "tx": 0, "ty": 0}

COLORS = {"blue", "purple", "green", "silver", "orange", "crimson", "gold", "yellow"}
SHAPES = {"triangle", "rectangle", "wedge", "corner", "pentagon", "diamond",
          "shield", "crescent"}


def key_lower(name):
    ln = name.lower()
    parts = ln.split("_", 1)
    if len(parts) == 2 and parts[0] in COLORS and parts[1] in SHAPES:
        return ln
    return None


def load_catalog():
    """name(lower) -> canonical icons_data key."""
    out = {}
    for line in open(os.path.join(CFG, "icons.txt"), encoding="utf-8").read().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, _, key = line.partition("|")
        kn = key_lower(name)
        if kn:
            out[kn] = key
    return out


def load_icons_data():
    """canonical key -> (sw, sh, mvp16, verts)."""
    out = {}
    for line in open(os.path.join(CFG, "icons_data.txt"), encoding="utf-8").read().splitlines():
        at = line.find("|SW=")
        if at < 0:
            continue
        key, tail = line[:at], line[at + 1:]
        fields = {}
        for part in tail.split("|"):
            k, _, v = part.partition("=")
            fields[k] = v
        try:
            sw, sh = int(fields["SW"]), int(fields["SH"])
            mvp = [float(x) for x in fields["MVP"].split(",")]
            verts = []
            for chunk in fields["PTS"].split(";"):
                p = chunk.split(",")
                if len(p) == 6:
                    verts.append(tuple(float(x) for x in p))
        except (KeyError, ValueError):
            continue
        if len(mvp) == 16 and len(verts) >= 3:
            out[key] = (sw, sh, mvp, verts)
    return out


def rasterize(sw, sh, m, raw_verts, rot):
    """Port of keys.html rasterizeMesh. Returns (outW, outH, rgba bytes)."""
    pitch, yaw, roll = rot["pitch"], rot["yaw"], rot.get("roll", 0)
    scale = 1 if rot.get("scale") is None else rot["scale"]
    tx, ty = rot.get("tx", 0), rot.get("ty", 0)
    cP, sP = math.cos(pitch), math.sin(pitch)
    cY, sY = math.cos(yaw), math.sin(yaw)
    cR, sR = math.cos(roll), math.sin(roll)
    verts = []
    for (x, y, z, r, g, b) in raw_verts:
        x, y, z = x * scale, y * scale, z * scale
        y1 = y * cP - z * sP
        z1 = y * sP + z * cP
        x2 = x * cY + z1 * sY
        z2 = -x * sY + z1 * cY
        x3 = x2 * cR - y1 * sR
        y3 = x2 * sR + y1 * cR
        verts.append((x3, y3, z2, r, g, b))

    fit = ATLAS_PX / max(sw, sh)
    outW = max(1, round(sw * fit))
    outH = max(1, round(sh * fit))
    rw, rh = outW * SS, outH * SS

    P = [None] * len(verts)
    for i, (x, y, z, r, g, b) in enumerate(verts):
        cx = m[0] * x + m[4] * y + m[8] * z + m[12]
        cy = m[1] * x + m[5] * y + m[9] * z + m[13]
        cz = m[2] * x + m[6] * y + m[10] * z + m[14]
        cw = m[3] * x + m[7] * y + m[11] * z + m[15]
        if cw > 0:
            P[i] = ((cx / cw * 0.5 + 0.5) * rw + tx * rw,
                    (cy / cw * -0.5 + 0.5) * rh - ty * rh,
                    cz / cw, r, g, b)

    px = bytearray(rw * rh * 4)
    zbuf = [math.inf] * (rw * rh)
    llen = math.hypot(*LIGHT) or 1
    lx, ly, lz = LIGHT[0] / llen, LIGHT[1] / llen, LIGHT[2] / llen

    def edge(ax, ay, bx, by, cx_, cy_):
        return (bx - ax) * (cy_ - ay) - (by - ay) * (cx_ - ax)

    for t in range(0, len(verts) - 2, 3):
        v0, v1, v2 = P[t], P[t + 1], P[t + 2]
        if not (v0 and v1 and v2):
            continue
        area = edge(v0[0], v0[1], v1[0], v1[1], v2[0], v2[1])
        if area == 0:
            continue
        a, b, c = verts[t], verts[t + 1], verts[t + 2]
        nx = (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
        ny = (b[2] - a[2]) * (c[0] - a[0]) - (b[0] - a[0]) * (c[2] - a[2])
        nz = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
        nlen = math.hypot(nx, ny, nz) or 1
        dot = (nx * lx + ny * ly + nz * lz) / nlen
        shade = BASE + RANGE * (0.5 + 0.5 * dot)
        minx = max(0, math.floor(min(v0[0], v1[0], v2[0])))
        maxx = min(rw - 1, math.floor(max(v0[0], v1[0], v2[0])))
        miny = max(0, math.floor(min(v0[1], v1[1], v2[1])))
        maxy = min(rh - 1, math.floor(max(v0[1], v1[1], v2[1])))
        for yy in range(miny, maxy + 1):
            fy = yy + 0.5
            for xx in range(minx, maxx + 1):
                fx = xx + 0.5
                w0 = edge(v1[0], v1[1], v2[0], v2[1], fx, fy) / area
                w1 = edge(v2[0], v2[1], v0[0], v0[1], fx, fy) / area
                w2 = edge(v0[0], v0[1], v1[0], v1[1], fx, fy) / area
                if w0 < 0 or w1 < 0 or w2 < 0:
                    continue
                z = w0 * v0[2] + w1 * v1[2] + w2 * v2[2]
                off = yy * rw + xx
                if z >= zbuf[off]:
                    continue
                zbuf[off] = z
                po = off * 4
                px[po] = min(255, max(0, round((w0 * v0[3] + w1 * v1[3] + w2 * v2[3]) * shade)))
                px[po + 1] = min(255, max(0, round((w0 * v0[4] + w1 * v1[4] + w2 * v2[4]) * shade)))
                px[po + 2] = min(255, max(0, round((w0 * v0[5] + w1 * v1[5] + w2 * v2[5]) * shade)))
                px[po + 3] = 255

    out = bytearray(outW * outH * 4)
    nsub = SS * SS
    for y in range(outH):
        for x in range(outW):
            sr = sg = sb = sa = 0
            for sy in range(SS):
                o = ((y * SS + sy) * rw + x * SS) * 4
                for _ in range(SS):
                    aa = px[o + 3]
                    if aa:
                        sr += px[o] * aa
                        sg += px[o + 1] * aa
                        sb += px[o + 2] * aa
                        sa += aa
                    o += 4
            if sa == 0:
                continue
            q = (y * outW + x) * 4
            out[q] = round(sr / sa)
            out[q + 1] = round(sg / sa)
            out[q + 2] = round(sb / sa)
            out[q + 3] = round(sa / nsub)
    return outW, outH, bytes(out)


def main():
    dry = "--dry-run" in sys.argv
    catalog = load_catalog()
    data = load_icons_data()
    rot_path = os.path.join(CFG, "shape_rot.txt")
    shape_rot = json.load(open(rot_path, encoding="utf-8")) if os.path.exists(rot_path) else {}

    lines = [
        "# Cursor-hint key icons, rasterised from the captured key meshes",
        "# (icons_data.txt) with the panel rasteriser + shape_rot.txt rotations.",
        "# Regenerate with tools/gen_key_icons.py after changing rotations.",
        "# Format: name|w|h|rgba_hex  (h rows of w*4 bytes, top-to-bottom).",
    ]
    rendered, missing = [], []
    for name in sorted(catalog):
        key = catalog[name]
        if key not in data:
            missing.append(name)
            continue
        sw, sh, mvp, verts = data[key]
        shape = name.split("_", 1)[1]
        rot = {**DEFAULT_ROT, **shape_rot.get(shape, {})}
        w, h, rgba = rasterize(sw, sh, mvp, verts, rot)
        lines.append("%s|%d|%d|%s" % (name, w, h, rgba.hex()))
        rendered.append((name, w, h, rgba))
        print("  %-18s %dx%d" % (name, w, h))
    body = "\n".join(lines) + "\n"
    print("rendered=%d  missing=%s  bytes=%d" % (len(rendered), missing or "none", len(body)))

    try:
        from PIL import Image
        cols = 8
        cell = ATLAS_PX + 4
        rows = (len(rendered) + cols - 1) // cols
        sheet = Image.new("RGBA", (cols * cell, rows * cell), (30, 30, 30, 255))
        for i, (name, w, h, rgba) in enumerate(rendered):
            img = Image.frombytes("RGBA", (w, h), rgba)
            sheet.paste(img, ((i % cols) * cell + 2, (i // cols) * cell + 2), img)
        sheet_path = os.path.join(os.path.dirname(__file__), "key_icons_sheet.png")
        sheet.save(sheet_path)
        print("contact sheet: %s" % sheet_path)
    except ImportError:
        print("PIL not available; no contact sheet")

    if dry:
        print("dry run: nothing written")
        return
    for target in (os.path.join(CFG, "key_icons.txt"),
                   os.path.join(REPO_DATA, "key_icons.txt"),
                   os.path.join(DEPLOY_DATA, "key_icons.txt")):
        with open(target, "w", encoding="utf-8", newline="") as f:
            f.write(body)
        print("wrote %s" % target)


if __name__ == "__main__":
    main()
