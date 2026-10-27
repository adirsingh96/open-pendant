#!/usr/bin/env python3
"""Place and route the carrier.

Board is 23 x 38 mm, 2 layers, 1.6 mm. KiCad's Y axis points up: the outline
origin is the bottom-left corner, the XIAO USB jack hangs off y = 0, and the
microSD mouth opens off the top edge. The cell wires solder to two pads on
the back, in an open bay between the USB edge and the cell. Those pads meet
the XIAO's underside VBAT and GND pads.

Tracks are 0.2 mm, clearance 0.2 mm, vias 0.6 / 0.3 mm. That is inside
JLCPCB's standard 2-layer process.
"""

from __future__ import annotations

import math
import os
import re
import sys
import uuid

sys.path.insert(0, "/Users/aditidutt/ai_pendent/hardware/openpendant_v1/scripts")
from netlist import load  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BOARD = os.path.join(ROOT, "openpendant_carrier.kicad_pcb")
NETLIST = os.path.join(ROOT, "output", "netlist.net")
FPDIR = "/Applications/KiCad/KiCad.app/Contents/SharedSupport/footprints"
LOCAL = {
    "Seeed_XIAO": os.path.join(ROOT, "lib", "Seeed_XIAO.pretty"),
    "Battery": os.path.join(ROOT, "lib", "Battery.pretty"),
}

W, H = 23.0, 38.0
TRACK = 0.2
CLEARANCE = 0.2
VIA_D, VIA_DRILL = 0.6, 0.3
EDGE = 0.2

# Y up. USB of the module is the low-Y end of the footprint.
PLACEMENT = {
    "U1": (2.6, 21.05, 0),
    "J1": (7.84, 31.4, 180),
    "C1": (9.0, 22.9, 0),
    "SW1": (19.2, 30.2, 0),
    # Back-side wire pads. Long axis points at the cell. The cell itself
    # starts at y = 8, leaving a bay for the insulated leads.
    "J2": (11.5, 2.85, 0),
}
# The card guide is meant to stick past the top edge.
OVERHANG = {"J1": 4.0}


def uid() -> str:
    return str(uuid.uuid4())


def fp_path(fp: str) -> str:
    lib, name = fp.split(":")
    base = LOCAL.get(lib, os.path.join(FPDIR, f"{lib}.pretty"))
    return os.path.join(base, f"{name}.kicad_mod")


def blocks(text: str, tag: str, indent: str = "\t") -> list[tuple[int, int]]:
    spans = []
    for m in re.finditer(rf"\n{indent}\({tag}[\s\n]", text):
        i = m.start() + 1
        depth, j = 0, i
        while True:
            c = text[j]
            if c == '"':
                j += 1
                while text[j] != '"' or text[j - 1] == "\\":
                    j += 1
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        spans.append((i, j + 1))
    return spans


def rot_xy(x: float, y: float, deg: float) -> tuple[float, float]:
    """KiCad board rotation is counter-clockwise and Y points up."""
    r = math.radians(deg)
    return x * math.cos(r) - y * math.sin(r), x * math.sin(r) + y * math.cos(r)


class Pad:
    def __init__(self, ref, num, x, y, aabb, layer):
        self.ref, self.num = ref, num
        self.x, self.y, self.aabb, self.layer = x, y, aabb, layer


def footprint_pads(fp: str, ref: str, ox: float, oy: float, rot: float) -> list[Pad]:
    text = open(fp_path(fp)).read()
    out = []
    for i, j in blocks(text, "pad", indent="\t"):
        pad = text[i:j]
        num = re.match(r'\(pad "([^"]*)"', pad.lstrip()).group(1)
        at = re.search(r"\(at ([-\d.]+) ([-\d.]+)(?: ([-\d.]+))?\)", pad)
        size = re.search(r"\(size ([-\d.]+) ([-\d.]+)\)", pad)
        layers = re.search(r'\(layers ([^)]*)\)', pad).group(1)
        px, py = float(at.group(1)), float(at.group(2))
        pang = float(at.group(3) or 0)
        w, h = float(size.group(1)), float(size.group(2))
        bx, by = rot_xy(px, py, rot)
        bx, by = ox + bx, oy + by
        ang = (pang + rot) % 360
        if int(round(ang)) % 180 == 90:
            w, h = h, w
        layer = "B.Cu" if '"B.Cu"' in layers else "F.Cu"
        aabb = (bx - w / 2, by - h / 2, bx + w / 2, by + h / 2)
        out.append(Pad(ref, num, bx, by, aabb, layer))
    return out


def courtyard(fp: str, ox: float, oy: float, rot: float):
    text = open(fp_path(fp)).read()
    xs, ys = [], []
    for m in re.finditer(
        r"\(fp_(?:line|rect)\s*\(start ([-\d.]+) ([-\d.]+)\)\s*"
        r"\(end ([-\d.]+) ([-\d.]+)\)[\s\S]{0,240}?\(layer \"([^\"]+)\"\)", text
    ):
        if "CrtYd" not in m.group(5):
            continue
        for px, py in ((float(m.group(1)), float(m.group(2))),
                       (float(m.group(3)), float(m.group(4)))):
            rx, ry = rot_xy(px, py, rot)
            xs.append(ox + rx)
            ys.append(oy + ry)
    if not xs:
        raise SystemExit(f"{fp}: no courtyard")
    return min(xs), min(ys), max(xs), max(ys)


def footprint_block(ref: str, value: str, fp: str, x: float, y: float,
                    rot: float, nets: dict) -> str:
    text = open(fp_path(fp)).read().rstrip()
    body = text[text.index("\n"):]
    assert body.endswith(")")
    body = body[:-1].rstrip()
    for tag in ("version", "generator", "generator_version", "layer"):
        for i, j in sorted(blocks(body, tag, indent="\t"), reverse=True):
            body = body[:i] + body[j:]
    body = re.sub(r"\n\t+(?=\n)", "", body)
    body = body.replace('(property "Reference" "REF**"', f'(property "Reference" "{ref}"', 1)
    body = re.sub(r'\(property "Value" "[^"]*"', f'(property "Value" "{value}"', body, count=1)

    out, last = [], 0
    for i, j in blocks(body, "pad", indent="\t"):
        pad = body[i:j]
        num = re.match(r'\(pad "([^"]*)"', pad.lstrip()).group(1)
        net = nets.get((ref, num))
        if net:
            pad = pad[:-1].rstrip() + f'\n\t\t\t(net {net[0]} "{net[1]}")\n\t\t)'
        out.append(body[last:i] + pad)
        last = j
    body = "".join(out) + body[last:]
    body = body.replace("\n\t", "\n\t\t")
    rot_txt = f" {rot:g}" if rot else ""
    return (f'\t(footprint "{fp}"\n\t\t(layer "F.Cu")\n\t\t(uuid "{uid()}")\n'
            f'\t\t(at {x:g} {y:g}{rot_txt}){body}\n\t)\n')


# ------------------------------------------------------------------- routing

class Copper:
    def __init__(self):
        self.segs = []   # (net, layer, x1, y1, x2, y2)
        self.vias = []   # (net, x, y)

    def track(self, net, layer, pts):
        for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
            if math.hypot(x2 - x1, y2 - y1) < 1e-6:
                continue
            self.segs.append((net, layer, x1, y1, x2, y2))

    def via(self, net, x, y):
        self.vias.append((net, x, y))


def leaf(name: str) -> str:
    return name[1:] if name.startswith("/") else name


def build_routes(pads: list[Pad]) -> Copper:
    by = {}
    for p in pads:
        by.setdefault((p.ref, p.num), []).append(p)

    def c(ref, num):
        return by[(ref, num)][0].x, by[(ref, num)][0].y

    cu = Copper()

    def fcu(net, *pts):
        cu.track(net, "F.Cu", pts)

    def bcu(net, *pts):
        cu.track(net, "B.Cu", pts)

    # Card-slot contacts are one row, so each signal drops on the top copper
    # to its own via. The back-side bus runs under the socket. The net with
    # the higher via has the righter spine, which keeps those spines from
    # cutting the horizontals. The last hop to a XIAO pad is on the top
    # again, so it can cross the spines.
    # net, SD pin, XIAO pin, via Y, spine X
    bus = (
        ("SD_DAT0", "7", "8", 34.7, 14.2),
        ("SD_CLK", "5", "10", 33.7, 13.2),
        ("SD_CMD", "3", "9", 32.7, 12.2),
        ("+3V3", "4", "12", 31.7, 11.2),
    )
    for net, sd_pin, xiao_pin, drop_y, spine in bus:
        sx, sy = c("J1", sd_pin)
        cu.via(net, sx, drop_y)
        fcu(net, (sx, sy), (sx, drop_y))
        px, py = c("U1", xiao_pin)
        cu.via(net, spine, py)
        bcu(net, (sx, drop_y), (spine, drop_y), (spine, py))
        fcu(net, (spine, py), (px, py))

    # CS stays on the left edge. D6 is the top-left pad of the module.
    sx, sy = c("J1", "2")
    cu.via("SD_CS", sx, 35.5)
    fcu("SD_CS", (sx, sy), (sx, 35.5))
    dx, dy = c("U1", "7")
    cu.via("SD_CS", 0.75, dy)
    bcu("SD_CS", (sx, 35.5), (0.75, 35.5), (0.75, dy))
    fcu("SD_CS", (0.75, dy), (dx, dy))

    # 3V3 also feeds the capacitor, off the left side of its spine.
    cap_x, cap_y = c("C1", "1")
    cu.via("+3V3", 6.9, cap_y)
    bcu("+3V3", (11.2, cap_y), (6.9, cap_y))
    fcu("+3V3", (6.9, cap_y), (cap_x, cap_y))
    gx, gy = c("C1", "2")
    cu.via("GND", gx, gy + 1.5)
    fcu("GND", (gx, gy), (gx, gy + 1.5))

    # Button. Down the left side on the back, across above the module on
    # the top so it can pass over the card spines, then up into the switch.
    d1x, d1y = c("U1", "2")
    cu.via("BTN", 1.45, d1y)
    fcu("BTN", (d1x, d1y), (1.45, d1y))
    bx, b1y = c("SW1", "1")
    cu.via("BTN", 1.45, 25.0)
    bcu("BTN", (1.45, d1y), (1.45, 25.0))
    fcu("BTN", (1.45, 25.0), (bx, 25.0), (bx, b1y))
    sw2x, sw2y = c("SW1", "2")
    cu.via("GND", sw2x, sw2y + 1.7)
    fcu("GND", (sw2x, sw2y), (sw2x, sw2y + 1.7))

    # Cell. The VBAT via sits just above the underside pad, then the back
    # trace drops in the gap between the left-edge pads and that pad.
    vx, vy = c("U1", "19")
    cu.via("VBAT", vx, vy + 1.15)
    fcu("VBAT", (vx, vy), (vx, vy + 1.15))
    jx, jy = c("J2", "1")
    bcu("VBAT", (vx, vy + 1.15), (5.2, vy + 1.15), (5.2, jy), (jx, jy))

    # One ground via for every top-side ground pad, so the back pour ties them.
    x, y = c("J1", "6")
    cu.via("GND", x, y)
    for p in by[("J1", "SH")]:
        cu.via("GND", p.x, p.y)
    for num, dx, dy in (("13", -1.7, 0.0), ("18", 0.0, 0.0), ("20", 1.9, -1.4)):
        x, y = c("U1", num)
        cu.via("GND", x + dx, y + dy)
        if dx or dy:
            fcu("GND", (x, y), (x + dx, y + dy))
    return cu


# ------------------------------------------------------------------- checks

def seg_seg(a1, a2, b1, b2) -> float:
    def clamp(v):
        return max(0.0, min(1.0, v))
    eps = 1e-12
    ux, uy = a2[0] - a1[0], a2[1] - a1[1]
    vx, vy = b2[0] - b1[0], b2[1] - b1[1]
    rx, ry = a1[0] - b1[0], a1[1] - b1[1]
    a = ux * ux + uy * uy
    e = vx * vx + vy * vy
    f = vx * rx + vy * ry
    if a <= eps and e <= eps:
        return math.hypot(rx, ry)
    if a <= eps:
        s, t = 0.0, clamp(f / e)
    else:
        c = ux * rx + uy * ry
        if e <= eps:
            t, s = 0.0, clamp(-c / a)
        else:
            b = ux * vx + uy * vy
            den = a * e - b * b
            s = clamp((b * f - c * e) / den) if den > eps else 0.0
            t = (b * s + f) / e
            if t < 0.0:
                t, s = 0.0, clamp(-c / a)
            elif t > 1.0:
                t, s = 1.0, clamp((b - c) / a)
    return math.hypot(rx + s * ux - t * vx, ry + s * uy - t * vy)


def point_seg(p, a, b) -> float:
    return seg_seg(p, p, a, b)


def point_rect(px, py, r) -> float:
    x1, y1, x2, y2 = r
    return math.hypot(px - min(max(px, x1), x2), py - min(max(py, y1), y2))


def seg_rect(a, b, r) -> float:
    if point_rect(*a, r) == 0 or point_rect(*b, r) == 0:
        return 0.0
    x1, y1, x2, y2 = r
    edges = [((x1, y1), (x2, y1)), ((x2, y1), (x2, y2)),
             ((x2, y2), (x1, y2)), ((x1, y2), (x1, y1))]
    return min(seg_seg(a, b, c, d) for c, d in edges)


def check(pads: list[Pad], cu: Copper, nets: dict) -> list[str]:
    problems = []
    items = []
    for p in pads:
        if (p.ref, p.num) not in nets:
            continue
        items.append((nets[(p.ref, p.num)][1], p.layer, "pad", p.aabb, None, p.ref + "." + p.num))
    for net, layer, x1, y1, x2, y2 in cu.segs:
        items.append((net, layer, "track", None, ((x1, y1), (x2, y2)), net))
    for net, x, y in cu.vias:
        items.append((net, "F.Cu", "via", (x, y), None, "via"))
        items.append((net, "B.Cu", "via", (x, y), None, "via"))

    def gap(a, b):
        na, la, ka, ra, sa, _ = a
        nb, lb, kb, rb, sb, _ = b
        if la != lb or na == nb:
            return None
        pairs = {ka, kb}
        if pairs == {"track"}:
            return seg_seg(sa[0], sa[1], sb[0], sb[1]) - TRACK
        if pairs == {"via"}:
            return math.hypot(ra[0] - rb[0], ra[1] - rb[1]) - VIA_D
        if pairs == {"pad"}:
            return seg_rect((ra[0], ra[1]), (ra[2], ra[3]),
                            (rb[0], rb[1], rb[0], rb[1])) if False else _pad_pad(ra, rb)
        if ka == "track" and kb == "pad":
            return seg_rect(sa[0], sa[1], rb) - TRACK / 2
        if kb == "track" and ka == "pad":
            return seg_rect(sb[0], sb[1], ra) - TRACK / 2
        if ka == "via" and kb == "pad":
            return point_rect(ra[0], ra[1], rb) - VIA_D / 2
        if kb == "via" and ka == "pad":
            return point_rect(rb[0], rb[1], ra) - VIA_D / 2
        if ka == "via" and kb == "track":
            return point_seg(ra, sb[0], sb[1]) - VIA_D / 2 - TRACK / 2
        if kb == "via" and ka == "track":
            return point_seg(rb, sa[0], sa[1]) - VIA_D / 2 - TRACK / 2
        return None

    def _pad_pad(a, b):
        # Distance between two filled rectangles.
        ax1, ay1, ax2, ay2 = a
        bx1, by1, bx2, by2 = b
        dx = max(bx1 - ax2, ax1 - bx2, 0.0)
        dy = max(by1 - ay2, ay1 - by2, 0.0)
        return math.hypot(dx, dy)

    for i, a in enumerate(items):
        for b in items[i + 1:]:
            g = gap(a, b)
            if g is not None and g < CLEARANCE - 1e-6:
                problems.append(
                    f"clearance {g:.3f} mm  {a[5]} {a[1]} {a[0]}  vs  {b[5]} {b[1]} {b[0]}")

    rad = TRACK / 2
    for net, layer, x1, y1, x2, y2 in cu.segs:
        for x, y in ((x1, y1), (x2, y2), ((x1 + x2) / 2, (y1 + y2) / 2)):
            if x - rad < EDGE or y - rad < EDGE or x + rad > W - EDGE or y + rad > H - EDGE:
                problems.append(f"edge {net} {layer} at ({x:.2f},{y:.2f})")
                break
    for net, x, y in cu.vias:
        if x - VIA_D / 2 < EDGE or y - VIA_D / 2 < EDGE or x + VIA_D / 2 > W - EDGE or y + VIA_D / 2 > H - EDGE:
            problems.append(f"via edge {net} at ({x:.2f},{y:.2f})")
    return problems


def connected(pads: list[Pad], cu: Copper, want: dict) -> list[str]:
    """Union pads, tracks and vias. `want` is net -> [(ref, pin)] for signal nets."""
    problems = []
    parent = {}

    def find(a):
        parent.setdefault(a, a)
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    for net, nodes in want.items():
        ids = []
        for ref, pin in nodes:
            for i, p in enumerate(pads):
                if p.ref == ref and p.num == pin and leaf_of_pad(p, net):
                    ids.append(("pad", i))
        for i, seg in enumerate(cu.segs):
            if seg[0] == net:
                ids.append(("seg", i))
        for i, via in enumerate(cu.vias):
            if via[0] == net:
                ids.append(("via", i))
        for a in ids:
            for b in ids:
                if a >= b:
                    continue
                if touches(a, b, pads, cu):
                    union((net, a), (net, b))
        roots = {find((net, i)) for i in ids}
        pad_ids = [i for i in ids if i[0] == "pad"]
        if not pad_ids:
            problems.append(f"{net}: no pads")
            continue
        root0 = find((net, pad_ids[0]))
        loose = [ids_label(i, pads) for i in pad_ids if find((net, i)) != root0]
        if loose or len(roots) > 1 and loose:
            problems.append(f"{net}: not joined {loose}")
    return problems


def ids_label(i, pads):
    kind, n = i
    if kind == "pad":
        return f"{pads[n].ref}.{pads[n].num}"
    return kind


def leaf_of_pad(p, net) -> bool:
    return True


def touches(a, b, pads, cu) -> bool:
    def pad_hit(idx, x, y):
        return point_rect(x, y, pads[idx].aabb) <= 0.02

    def seg_hit_point(idx, x, y):
        _, _, x1, y1, x2, y2 = cu.segs[idx]
        return point_seg((x, y), (x1, y1), (x2, y2)) <= 0.05

    def seg_layer(idx):
        return cu.segs[idx][1]

    ka, ia = a
    kb, ib = b
    if ka == "seg" and kb == "seg":
        if seg_layer(ia) != seg_layer(ib):
            return False
        a1, a2 = cu.segs[ia][2:4], cu.segs[ia][4:6]
        b1, b2 = cu.segs[ib][2:4], cu.segs[ib][4:6]
        return seg_seg(a1, a2, b1, b2) <= 0.05
    if ka == "via" and kb == "via":
        return math.hypot(cu.vias[ia][1] - cu.vias[ib][1],
                          cu.vias[ia][2] - cu.vias[ib][2]) <= 0.05
    if {ka, kb} == {"seg", "via"}:
        si, vi = (ia, ib) if ka == "seg" else (ib, ia)
        return seg_hit_point(si, cu.vias[vi][1], cu.vias[vi][2])
    if {ka, kb} == {"pad", "via"}:
        pi, vi = (ia, ib) if ka == "pad" else (ib, ia)
        return pad_hit(pi, cu.vias[vi][1], cu.vias[vi][2])
    if {ka, kb} == {"pad", "seg"}:
        pi, si = (ia, ib) if ka == "pad" else (ib, ia)
        if seg_layer(si) != pads[pi].layer:
            return False
        _, _, x1, y1, x2, y2 = cu.segs[si]
        return seg_rect((x1, y1), (x2, y2), pads[pi].aabb) <= 0.02
    return False


# -------------------------------------------------------------------- file

def edge_cuts() -> str:
    pts = [(0, 0), (W, 0), (W, H), (0, H)]
    out = ""
    for i in range(4):
        x1, y1 = pts[i]
        x2, y2 = pts[(i + 1) % 4]
        out += (f"\t(gr_line\n\t\t(start {x1:g} {y1:g})\n\t\t(end {x2:g} {y2:g})\n"
                f'\t\t(stroke (width 0.1) (type default))\n\t\t(layer "Edge.Cuts")\n'
                f'\t\t(uuid "{uid()}")\n\t)\n')
    return out


def zone(code, name, layers, rect, keepout=False) -> str:
    x1, y1, x2, y2 = rect
    pts = f"(xy {x1:g} {y1:g}) (xy {x2:g} {y1:g}) (xy {x2:g} {y2:g}) (xy {x1:g} {y2:g})"
    layer_str = " ".join(f'"{layer}"' for layer in layers)
    if keepout:
        rule = ("\t\t(keepout (tracks allowed) (vias allowed) (pads allowed)\n"
                "\t\t\t(copperpour not_allowed) (footprints allowed))\n")
    else:
        rule = (f"\t\t(connect_pads yes (clearance {CLEARANCE:g}))\n"
                "\t\t(min_thickness 0.2)\n\t\t(filled_areas_thickness no)\n"
                "\t\t(fill yes (thermal_gap 0.3) (thermal_bridge_width 0.4))\n")
    return (f"\t(zone\n\t\t(net {code})\n\t\t(net_name \"{name}\")\n"
            f"\t\t(layers {layer_str})\n\t\t(uuid \"{uid()}\")\n"
            f"\t\t(hatch edge 0.5)\n{rule}"
            f"\t\t(polygon\n\t\t\t(pts {pts})\n\t\t)\n\t)\n")


def main() -> None:
    comps, raw_nets = load(NETLIST)
    code = {}
    n = 1
    for name in sorted(raw_nets):
        if name.startswith("unconnected-"):
            continue
        code[name] = n
        n += 1
    pad_net = {}
    for name, nodes in raw_nets.items():
        if name.startswith("unconnected-"):
            continue
        for ref, pin in nodes:
            pad_net[(ref, pin)] = (code[name], name)

    pads = []
    fp_txt = ""
    print("placement")
    boxes = {}
    for ref, (x, y, rot) in PLACEMENT.items():
        value, fp = comps[ref]
        box = courtyard(fp, x, y, rot)
        boxes[ref] = box
        slack = OVERHANG.get(ref, 0.0)
        x1, y1, x2, y2 = box
        if x1 < -slack or y1 < -slack or x2 > W + slack or y2 > H + slack:
            raise SystemExit(f"{ref} courtyard outside the board: {box}")
        print(f"  {ref:4} ({x:.2f},{y:.2f}) rot {rot:3}  "
              f"courtyard ({x1:.2f},{y1:.2f})-({x2:.2f},{y2:.2f})")
        pads.extend(footprint_pads(fp, ref, x, y, rot))
        fp_txt += footprint_block(ref, value, fp, x, y, rot, pad_net)

    # J2 is soldered on the back. Its outline sits under the module on
    # purpose: the iron meets it from the back, and the module is on the front.
    back_side = {"J2"}
    refs = sorted(boxes)
    for i, a in enumerate(refs):
        ax1, ay1, ax2, ay2 = boxes[a]
        for b in refs[i + 1:]:
            if {a, b} & back_side:
                continue
            bx1, by1, bx2, by2 = boxes[b]
            ox = min(ax2, bx2) - max(ax1, bx1)
            oy = min(ay2, by2) - max(ay1, by1)
            if ox > 0.05 and oy > 0.05:
                raise SystemExit(f"{a} overlaps {b} by {ox:.2f} x {oy:.2f} mm")

    cu = build_routes(pads)
    # The checker speaks leaf net names. Map the sheet-prefixed names back.
    named = {}
    for (ref, pin), (num, name) in pad_net.items():
        named[(ref, pin)] = (num, leaf(name))
    renamed = Copper()
    for net, layer, x1, y1, x2, y2 in cu.segs:
        renamed.segs.append((net, layer, x1, y1, x2, y2))
    renamed.vias = list(cu.vias)

    problems = check(pads, renamed, named)
    want = {}
    for name, nodes in raw_nets.items():
        if name.startswith("unconnected-") or leaf(name) == "GND":
            continue
        want[leaf(name)] = nodes
    problems += connected(pads, renamed, want)
    if problems:
        print(f"{len(problems)} PROBLEMS")
        for p in problems[:40]:
            print("  -", p)
        raise SystemExit(1)
    print(f"routes ok: {len(cu.segs)} tracks, {len(cu.vias)} vias")

    gnd_name = next(name for name in code if leaf(name) == "GND")
    tracks = ""
    for net, layer, x1, y1, x2, y2 in cu.segs:
        full = next(name for name in code if leaf(name) == net)
        tracks += (f"\t(segment (start {x1:.4f} {y1:.4f}) (end {x2:.4f} {y2:.4f})\n"
                   f"\t\t(width {TRACK:g}) (layer \"{layer}\")\n"
                   f"\t\t(net {code[full]}) (uuid \"{uid()}\"))\n")
    for net, x, y in cu.vias:
        full = next(name for name in code if leaf(name) == net)
        tracks += (f"\t(via (at {x:.4f} {y:.4f}) (size {VIA_D:g}) (drill {VIA_DRILL:g})\n"
                   f"\t\t(layers \"F.Cu\" \"B.Cu\") (net {code[full]}) (uuid \"{uid()}\"))\n")

    nets_txt = "".join(f'\t(net {code[name]} "{name}")\n' for name in sorted(code, key=code.get))
    silk = (f'\t(gr_text "USB" (at {W / 2:g} 1.05 0)\n\t\t(layer "F.SilkS")\n'
            f'\t\t(uuid "{uid()}")\n'
            f'\t\t(effects (font (size 0.7 0.7) (thickness 0.1)))\n\t)\n')
    text = (
        "(kicad_pcb\n"
        "\t(version 20260206)\n"
        '\t(generator "pcbnew")\n'
        '\t(generator_version "10.0")\n'
        "\t(general (thickness 1.6) (legacy_teardrops no))\n"
        '\t(paper "A4")\n'
        "\t(layers\n"
        '\t\t(0 "F.Cu" signal)\n\t\t(2 "B.Cu" signal)\n'
        '\t\t(9 "F.Adhes" user "F.Adhesive")\n\t\t(11 "B.Adhes" user "B.Adhesive")\n'
        '\t\t(13 "F.Paste" user)\n\t\t(15 "B.Paste" user)\n'
        '\t\t(5 "F.SilkS" user "F.Silkscreen")\n\t\t(7 "B.SilkS" user "B.Silkscreen")\n'
        '\t\t(1 "F.Mask" user)\n\t\t(3 "B.Mask" user)\n'
        '\t\t(25 "Edge.Cuts" user)\n'
        '\t\t(31 "F.CrtYd" user "F.Courtyard")\n\t\t(29 "B.CrtYd" user "B.Courtyard")\n'
        '\t\t(35 "F.Fab" user)\n\t\t(33 "B.Fab" user)\n'
        "\t)\n"
        "\t(setup\n"
        "\t\t(pad_to_mask_clearance 0)\n"
        "\t\t(allow_soldermask_bridges_in_footprints no)\n"
        "\t\t(stackup\n"
        '\t\t\t(layer "F.SilkS" (type "Top Silk Screen"))\n'
        '\t\t\t(layer "F.Paste" (type "Top Solder Paste"))\n'
        '\t\t\t(layer "F.Mask" (type "Top Solder Mask") (thickness 0.01))\n'
        '\t\t\t(layer "F.Cu" (type "copper") (thickness 0.035))\n'
        '\t\t\t(layer "dielectric 1" (type "core") (thickness 1.51)'
        ' (material "FR4") (epsilon_r 4.5) (loss_tangent 0.02))\n'
        '\t\t\t(layer "B.Cu" (type "copper") (thickness 0.035))\n'
        '\t\t\t(layer "B.Mask" (type "Bottom Solder Mask") (thickness 0.01))\n'
        '\t\t\t(layer "B.Paste" (type "Bottom Solder Paste"))\n'
        '\t\t\t(layer "B.SilkS" (type "Bottom Silk Screen"))\n'
        '\t\t\t(copper_finish "HASL")\n\t\t\t(dielectric_constraints no)\n'
        "\t\t)\n\t)\n"
        f"{nets_txt}{edge_cuts()}{silk}{fp_txt}{tracks}"
        # Back ground pour. The top 6 mm of the module is its antenna, so the
        # pour is kept off that patch.
        + zone(code[gnd_name], gnd_name, ["B.Cu"], (0.3, 0.3, W - 0.3, H - 0.3))
        + zone(0, "", ["B.Cu"], (2.4, 15.2, 20.6, 21.3), keepout=True)
        + "\t(embedded_fonts no)\n)\n"
    )
    open(BOARD, "w").write(text)
    print(f"wrote {BOARD}")
    fill_zones()


def fill_zones() -> None:
    """The back ground pour carries no copper until KiCad fills it."""
    kipy = ("/Applications/KiCad/KiCad.app/Contents/Frameworks/"
            "Python.framework/Versions/3.9/bin/python3")
    script = (
        "import pcbnew\n"
        f"board = pcbnew.LoadBoard({BOARD!r})\n"
        "zones = list(board.Zones())\n"
        "filler = pcbnew.ZONE_FILLER(board)\n"
        "assert filler.Fill(zones), 'zone fill failed'\n"
        "board.BuildConnectivity()\n"
        "n = board.GetConnectivity().GetUnconnectedCount(False)\n"
        "print('unconnected', n)\n"
        "assert n == 0, 'ratsnest is not clear'\n"
        f"pcbnew.SaveBoard({BOARD!r}, board)\n"
    )
    import subprocess
    subprocess.run([kipy, "-c", script], check=True)


if __name__ == "__main__":
    main()
