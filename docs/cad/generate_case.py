#!/usr/bin/env python3
"""Emit printable STLs for the OpenPendant clamshell (stdlib only).

Two-piece snap case: USB-C window on the bottom seam, no SD slot,
fingernail grooves, cord bail on the back. Open the lid to reach the card.
"""

from __future__ import annotations

import math
import struct
from pathlib import Path

# 8×18-hole strip (2.54 mm → 20.32 × 45.72 mm) matching the built proto:
# USB + XIAO + SD on the world face, LiPo taped on the back after wiring.
INNER_W = 23.0
INNER_H = 48.0
INNER_D_BACK = 8.0
INNER_D_FRONT = 7.0
WALL = 1.6
LIP = 1.2
LIP_H = 1.8

USB_W = 12.0
USB_H = 5.4

MIC_X = 0.0
MIC_Y = 17.0
MIC_R = 1.5

LED_Y = 7.0
LED_R = 1.2

# Ø6 tactile in the spare holes above the SD module.
BTN_X = 1.27
BTN_Y = 44.5
BTN_R = 3.3

ISLAND_W = 20.8
ISLAND_H = 46.2

NAIL_W = 10.0
NAIL_H = 3.2
NAIL_D = 1.0

SNAP_W = 7.2
SNAP_T = 1.15
SNAP_LEN = 4.2
BARB = 0.85

BAIL_H = 8.0
BAIL_T = 3.0
BAIL_W = 16.0

OUTER_W = INNER_W + 2 * WALL
OUTER_H = INNER_H + 2 * WALL
OUTER_BACK = INNER_D_BACK + WALL
OUTER_FRONT = INNER_D_FRONT + WALL


class Mesh:
    def __init__(self) -> None:
        self.tris: list[tuple[tuple[float, float, float], ...]] = []

    def tri(self, a, b, c) -> None:
        self.tris.append((a, b, c))

    def quad(self, a, b, c, d) -> None:
        self.tri(a, b, c)
        self.tri(a, c, d)

    def box(self, x0, y0, z0, x1, y1, z1) -> None:
        if x1 < x0:
            x0, x1 = x1, x0
        if y1 < y0:
            y0, y1 = y1, y0
        if z1 < z0:
            z0, z1 = z1, z0
        if x1 - x0 < 1e-6 or y1 - y0 < 1e-6 or z1 - z0 < 1e-6:
            return
        p = [
            (x0, y0, z0),
            (x1, y0, z0),
            (x1, y1, z0),
            (x0, y1, z0),
            (x0, y0, z1),
            (x1, y0, z1),
            (x1, y1, z1),
            (x0, y1, z1),
        ]
        self.quad(p[0], p[3], p[2], p[1])
        self.quad(p[4], p[5], p[6], p[7])
        self.quad(p[0], p[1], p[5], p[4])
        self.quad(p[3], p[7], p[6], p[2])
        self.quad(p[0], p[4], p[7], p[3])
        self.quad(p[1], p[2], p[6], p[5])

    def translated(self, dx, dy, dz) -> Mesh:
        out = Mesh()
        for a, b, c in self.tris:
            out.tri(
                (a[0] + dx, a[1] + dy, a[2] + dz),
                (b[0] + dx, b[1] + dy, b[2] + dz),
                (c[0] + dx, c[1] + dy, c[2] + dz),
            )
        return out

    def write(self, path: Path) -> None:
        buf = bytearray(80)
        buf += struct.pack("<I", len(self.tris))
        for a, b, c in self.tris:
            ux, uy, uz = b[0] - a[0], b[1] - a[1], b[2] - a[2]
            vx, vy, vz = c[0] - a[0], c[1] - a[1], c[2] - a[2]
            nx = uy * vz - uz * vy
            ny = uz * vx - ux * vz
            nz = ux * vy - uy * vx
            n = math.sqrt(nx * nx + ny * ny + nz * nz) or 1.0
            buf += struct.pack("<3f", nx / n, ny / n, nz / n)
            buf += struct.pack("<3f", *a)
            buf += struct.pack("<3f", *b)
            buf += struct.pack("<3f", *c)
            buf += struct.pack("<H", 0)
        path.write_bytes(buf)


def snap_ys() -> tuple[float, float]:
    iy0 = WALL
    return iy0 + INNER_H * 0.30, iy0 + INNER_H * 0.70


def plate_with_holes(m: Mesh, x0, y0, z0, x1, y1, z1, holes) -> None:
    xs = [x0, x1]
    ys = [y0, y1]
    for hx, hy, hr in holes:
        xs += [hx - hr, hx + hr]
        ys += [hy - hr, hy + hr]
    xs = sorted({round(v, 4) for v in xs if x0 - 1e-6 <= v <= x1 + 1e-6})
    ys = sorted({round(v, 4) for v in ys if y0 - 1e-6 <= v <= y1 + 1e-6})

    def in_hole(cx, cy) -> bool:
        return any(abs(cx - hx) <= hr and abs(cy - hy) <= hr for hx, hy, hr in holes)

    for i in range(len(xs) - 1):
        for j in range(len(ys) - 1):
            cx = (xs[i] + xs[i + 1]) / 2
            cy = (ys[j] + ys[j + 1]) / 2
            if in_hole(cx, cy):
                continue
            m.box(xs[i], ys[j], z0, xs[i + 1], ys[j + 1], z1)


def side_wall(m: Mesh, x0, x1, y0, y1, z0, z1, *, windows: list[tuple[float, float]] | None = None) -> None:
    """Wall in X, optional Y-span windows that punch through (snap catches)."""
    windows = windows or []
    cuts = [(y0, y1)]
    for wy0, wy1 in windows:
        nxt = []
        for a, b in cuts:
            if wy1 <= a or wy0 >= b:
                nxt.append((a, b))
                continue
            if wy0 > a:
                nxt.append((a, wy0))
            if wy1 < b:
                nxt.append((wy1, b))
        cuts = nxt
    for a, b in cuts:
        m.box(x0, a, z0, x1, b, z1)


def back_shell() -> Mesh:
    m = Mesh()
    ox0, ox1 = -OUTER_W / 2, OUTER_W / 2
    oy0, oy1 = 0.0, OUTER_H
    oz1 = OUTER_BACK
    ix0, ix1 = -INNER_W / 2, INNER_W / 2
    iy0, iy1 = WALL, WALL + INNER_H
    usb0, usb1 = -USB_W / 2, USB_W / 2

    m.box(ox0, oy0, 0, ox1, oy1, WALL)

    # Top wall
    m.box(ox0, iy1, WALL, ox1, oy1, oz1)

    # Bottom wall: USB notch at the OPEN rim (XIAO lives toward the lid)
    usb_z0 = oz1 - USB_H
    m.box(ox0, oy0, WALL, usb0, iy0, oz1)
    m.box(usb1, oy0, WALL, ox1, iy0, oz1)
    m.box(usb0, oy0, WALL, usb1, iy0, usb_z0)

    # Sides with fingernail recesses on the outer face at the rim
    for x0, x1, outer_neg in ((ox0, ix0, True), (ix1, ox1, False)):
        thin = NAIL_D
        if outer_neg:
            inner0, inner1 = x0 + thin, x1
            out0, out1 = x0, x0 + thin
        else:
            inner0, inner1 = x0, x1 - thin
            out0, out1 = x1 - thin, x1
        m.box(inner0, iy0, WALL, inner1, iy1, oz1)
        yc = (iy0 + iy1) / 2
        n0, n1 = yc - NAIL_W / 2, yc + NAIL_W / 2
        m.box(out0, iy0, WALL, out1, iy1, oz1 - NAIL_H)
        m.box(out0, iy0, oz1 - NAIL_H, out1, n0, oz1)
        m.box(out0, n1, oz1 - NAIL_H, out1, iy1, oz1)

    # Snap hooks on the rim (45° barb, printable)
    for y in snap_ys():
        for x, s in ((ix0, -1.0), (ix1, 1.0)):
            x1 = x + s * SNAP_T
            m.box(min(x, x1), y - SNAP_W / 2, oz1, max(x, x1), y + SNAP_W / 2, oz1 + SNAP_LEN)
            xb0, xb1 = x1, x1 + s * BARB
            m.box(
                min(xb0, xb1),
                y - SNAP_W / 2,
                oz1 + SNAP_LEN - BARB,
                max(xb0, xb1),
                y + SNAP_W / 2,
                oz1 + SNAP_LEN,
            )

    # Cord bail
    bx0, bx1 = -BAIL_W / 2, BAIL_W / 2
    m.box(bx0, oy1, 0, bx0 + BAIL_T, oy1 + BAIL_H, BAIL_T)
    m.box(bx1 - BAIL_T, oy1, 0, bx1, oy1 + BAIL_H, BAIL_T)
    m.box(bx0, oy1 + BAIL_H - BAIL_T, 0, bx1, oy1 + BAIL_H, BAIL_T)

    # LiPo stays in this half, taped to the back of the strip after wiring.
    m.box(ix0, iy0 + 4.0, WALL, ix0 + 1.2, iy0 + 36.0, WALL + 2.6)
    m.box(ix1 - 1.2, iy0 + 4.0, WALL, ix1, iy0 + 36.0, WALL + 2.6)

    return m


def front_lid() -> Mesh:
    m = Mesh()
    ox0, ox1 = -OUTER_W / 2, OUTER_W / 2
    oy0, oy1 = 0.0, OUTER_H
    oz1 = OUTER_FRONT
    ix0, ix1 = -INNER_W / 2, INNER_W / 2
    iy0, iy1 = WALL, WALL + INNER_H
    usb0, usb1 = -USB_W / 2, USB_W / 2

    iy_mic = iy0 + MIC_Y
    iy_led = iy0 + LED_Y
    plate_with_holes(
        m,
        ox0,
        oy0,
        oz1 - WALL,
        ox1,
        oy1,
        oz1,
        [
            (MIC_X, iy_mic, MIC_R),
            (0.0, iy_led, LED_R),
            (BTN_X, iy0 + BTN_Y, BTN_R),
        ],
    )

    # Bottom wall: USB notch from the split up to USB_H
    m.box(ox0, oy0, 0, usb0, iy0, oz1 - WALL)
    m.box(usb1, oy0, 0, ox1, iy0, oz1 - WALL)
    m.box(usb0, oy0, USB_H, usb1, iy0, oz1 - WALL)

    # Top wall
    m.box(ox0, iy1, 0, ox1, oy1, oz1 - WALL)

    # Side walls with snap windows through the rim
    windows = [(y - SNAP_W / 2 - 0.35, y + SNAP_W / 2 + 0.35) for y in snap_ys()]
    side_wall(m, ox0, ix0, iy0, iy1, 0, oz1 - WALL, windows=windows)
    side_wall(m, ix1, ox1, iy0, iy1, 0, oz1 - WALL, windows=windows)
    # Close the window toward the outer face so the barb catches a ledge
    for y0w, y1w in windows:
        m.box(ox0, y0w, 2.6, ix0, y1w, oz1 - WALL)
        m.box(ix1, y0w, 2.6, ox1, y1w, oz1 - WALL)

    # Lip nests into the back opening (negative Z)
    lip_x0, lip_x1 = ix0 + 0.2, ix1 - 0.2
    lip_y0, lip_y1 = iy0 + 0.2, iy1 - 0.2
    m.box(lip_x0, lip_y0, -LIP_H, lip_x0 + LIP, lip_y1, 0)
    m.box(lip_x1 - LIP, lip_y0, -LIP_H, lip_x1, lip_y1, 0)
    m.box(lip_x0, lip_y1 - LIP, -LIP_H, lip_x1, lip_y1, 0)
    m.box(lip_x0, lip_y0, -LIP_H, usb0, lip_y0 + LIP, 0)
    m.box(usb1, lip_y0, -LIP_H, lip_x1, lip_y0 + LIP, 0)

    # Island + XIAO cradle: side rails and a top stop so a USB cable cannot shove the board.
    island_top = iy0 + ISLAND_H
    rail = (INNER_W - ISLAND_W) / 2
    m.box(ix0, iy0, 0, ix0 + rail, island_top, 3.4)
    m.box(ix1 - rail, iy0, 0, ix1, island_top, 3.4)
    m.box(-ISLAND_W / 2, island_top, 0, ISLAND_W / 2, island_top + 1.4, 3.4)

    return m


def main() -> None:
    out = Path(__file__).resolve().parent
    back = back_shell()
    front = front_lid().translated(0, 0, LIP_H)
    plate = Mesh()
    plate.tris.extend(back.tris)
    shifted = front.translated(OUTER_W + 8.0, 0, 0)
    plate.tris.extend(shifted.tris)
    back.write(out / "pendant_case_back.stl")
    front.write(out / "pendant_case_front.stl")
    plate.write(out / "pendant_case_print.stl")
    print(f"Wrote STLs in {out}")
    print(
        "Closed outer "
        f"{OUTER_W:.1f} x {OUTER_H + BAIL_H:.1f} x {OUTER_BACK + OUTER_FRONT:.1f} mm "
        f"({len(back.tris)} + {len(front.tris)} tris)"
    )


if __name__ == "__main__":
    main()
