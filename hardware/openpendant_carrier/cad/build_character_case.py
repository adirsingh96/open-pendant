#!/usr/bin/env python3
"""Orbit O case. Separate from the twin-ear case.

Same 23 x 38 mm carrier and the same two shells. The card stays inside:
the shells open when it has to come out, and there is no slot in the
outer wall. A short bail on the back, near the top, takes a 5 mm chain.
The front carries the logo: a tall O drawn as an orbit, inlaid flush
with the lid, with the button hat as the planet on its upper right.
The inlays are their own bodies so the slicer can give them their own
filament. Coordinates match KiCad: X across, Y up the pendant, USB
at Y = 0, Z = 0 against the chest, the front at +Z.

Print notes live in cad/character/PRINT.txt. Short version: 0.4 mm nozzle,
0.2 mm layers, PETG, no supports. The face is added onto the lid, not cut
into the 1.2 mm wall.
"""

import os

import adsk.core
import adsk.fusion

CAD = "/Users/aditidutt/ai_pendent/hardware/openpendant_carrier/cad"
OUT_DIR = os.path.join(CAD, "character")

# Board and the parts that sit on it. The fabricated board is the
# mirror of the KiCad file in X: USB-C facing down, the button is on
# the left. XIAO and the USB plug are centered, so they do not move.
PCB_W, PCB_H, PCB_T = 23.0, 38.0, 1.6
XIAO = (2.6, 0.0, 17.8, 21.0, 3.5)       # x, y, w, l, h
USB = (6.8, -2.2, 16.2, 0.4, 3.2)        # x1, y1, x2, y2, h above the board
SD = (8.3, 24.9, 22.0, 37.9, 1.5)
SD_MOUTH = (9.8, 37.6, 20.8, 41.2, 1.0)  # card guide, hangs off the board
BTN = (3.8, 30.2, 4.2, 3.0, 1.8)         # center x, y, w, l, h
CAP = (14.0, 22.9, 2.0, 1.25, 1.15)
CELL = (1.5, 8.0, 20.0, 30.0, 6.0)       # wire bay is y = 0..8, on the back
MIC = (11.5, 17.0, 3.0)                  # over the antenna end of the XIAO
LED = (6.2, 3.8, 1.8)                    # charge light, USB end

# 1.2 mm is three 0.4 mm perimeters. The skirt matches the wall so
# the catches have something to grow out of.
WALL = 1.2
GAP = 0.35
SKIRT_T = 1.2
SKIRT_GAP = 0.25
LIP = 3.6
# 0.4 mm over the cell, plus 1.5 mm so the leads can lie on it.
CELL_AIR = 1.9
FRONT_AIR = 0.8
OUTER_R = 4.0

# Cavity is the board, plus room for the USB plug and the card guide.
CAV_X1, CAV_X2 = -GAP, PCB_W + GAP
CAV_Y1, CAV_Y2 = -2.6, 41.8
BACK_X1, BACK_X2 = CAV_X1 - WALL, CAV_X2 + WALL
BACK_Y1, BACK_Y2 = CAV_Y1 - WALL, CAV_Y2 + WALL
FRONT_X1 = BACK_X1 - SKIRT_GAP - SKIRT_T
FRONT_X2 = BACK_X2 + SKIRT_GAP + SKIRT_T
FRONT_Y1 = BACK_Y1 - SKIRT_GAP - SKIRT_T
FRONT_Y2 = BACK_Y2 + SKIRT_GAP + SKIRT_T
# The card, including the bit that sticks out of the socket, stays inside
# the cavity. The bail is the only thing past the top wall.
CHAIN_D = 5.0
BAIL_WALL = 1.6
BAIL_W = 8.0

Z_CELL = WALL
Z_PCB = Z_CELL + CELL[4] + CELL_AIR
Z_SPLIT = Z_PCB + PCB_T
Z_CAVITY = XIAO[4] + FRONT_AIR
Z_FRONT = Z_SPLIT + Z_CAVITY + WALL
# The 5 mm hole is past the front skirt. A lower neck joins it to the
# shell without entering the skirt, which hangs 2 mm over the back.
BAIL_Y1 = BACK_Y2 - 0.4
HEAD_Y1 = FRONT_Y2 + 0.3
HEAD_Y2 = HEAD_Y1 + BAIL_WALL + CHAIN_D + BAIL_WALL
# Flush with the chest face. A 0.5 mm step under the bail is too
# small for the slicer to support, and it is not needed.
HEAD_Z1 = 0.0
HEAD_Z2 = HEAD_Z1 + BAIL_WALL + CHAIN_D + BAIL_WALL
NECK_Z2 = Z_SPLIT - LIP - 0.4
# The art is a flush inlay: pockets this deep in the 1.2 mm lid,
# filled level with the surface. Nothing stands proud of the face.
INLAY_D = 0.6
# The O, centered on the front face. Outer and inner ellipse radii.
ORBIT_CX = (FRONT_X1 + FRONT_X2) / 2
ORBIT_CY = 20.5
ORBIT_RX_OUT, ORBIT_RY_OUT = 11.6, 16.2
ORBIT_RX_IN, ORBIT_RY_IN = 8.1, 12.7


def mm(value):
    """Fusion lengths are centimetres."""
    return value * 0.1


def largest_profile(sketch):
    best, area = None, -1.0
    for i in range(sketch.profiles.count):
        profile = sketch.profiles.item(i)
        size = abs(profile.areaProperties().area)
        if size > area:
            best, area = profile, size
    if best is None:
        raise RuntimeError(f"sketch {sketch.name} has no profiles")
    return best


def profile_nearest(sketch, x, y):
    """Profile whose centroid is closest to a point, in millimetres."""
    best, best_d = None, None
    for i in range(sketch.profiles.count):
        profile = sketch.profiles.item(i)
        c = profile.areaProperties().centroid
        d = (c.x * 10.0 - x) ** 2 + (c.y * 10.0 - y) ** 2
        if best is None or d < best_d:
            best, best_d = profile, d
    if best is None:
        raise RuntimeError(f"sketch {sketch.name} has no profiles")
    return best


def ring_profile(sketch):
    for i in range(sketch.profiles.count):
        profile = sketch.profiles.item(i)
        if profile.profileLoops.count > 1:
            return profile
    raise RuntimeError(f"sketch {sketch.name} has no ring profile")


def add_rect(sketch, x1, y1, x2, y2):
    sketch.sketchCurves.sketchLines.addTwoPointRectangle(
        adsk.core.Point3D.create(mm(x1), mm(y1), 0),
        adsk.core.Point3D.create(mm(x2), mm(y2), 0),
    )


def add_thick_arc(sketch, cx, cy, r_in, r_out, a0, a1):
    """Closed arc stroke. Angles are degrees, 0 along +X, counterclockwise."""
    import math

    def pt(radius, deg):
        a = math.radians(deg)
        return adsk.core.Point3D.create(
            mm(cx + radius * math.cos(a)),
            mm(cy + radius * math.sin(a)),
            0,
        )

    center = adsk.core.Point3D.create(mm(cx), mm(cy), 0)
    sweep = math.radians(a1 - a0)
    curves = sketch.sketchCurves
    curves.sketchArcs.addByCenterStartSweep(center, pt(r_out, a0), sweep)
    curves.sketchArcs.addByCenterStartSweep(center, pt(r_in, a1), -sweep)
    curves.sketchLines.addByTwoPoints(pt(r_out, a0), pt(r_in, a0))
    curves.sketchLines.addByTwoPoints(pt(r_out, a1), pt(r_in, a1))


def add_ellipse(sketch, cx, cy, rx, ry):
    """Ellipse with a vertical major axis."""
    curves = sketch.sketchCurves.sketchEllipses
    curves.add(
        adsk.core.Point3D.create(mm(cx), mm(cy), 0),
        adsk.core.Point3D.create(mm(cx), mm(cy + ry), 0),
        adsk.core.Point3D.create(mm(cx + rx), mm(cy), 0),
    )


def add_sparkle(sketch, cx, cy, radius, waist):
    """Four-point star, the kind drawn in the margin of a notebook."""
    pts = [
        (cx, cy + radius), (cx + waist, cy + waist),
        (cx + radius, cy), (cx + waist, cy - waist),
        (cx, cy - radius), (cx - waist, cy - waist),
        (cx - radius, cy), (cx - waist, cy + waist),
    ]
    add_polygon(sketch, pts)


def add_circle(sketch, x, y, diameter):
    sketch.sketchCurves.sketchCircles.addByCenterRadius(
        adsk.core.Point3D.create(mm(x), mm(y), 0),
        mm(diameter) * 0.5,
    )


def add_polygon(sketch, pts):
    lines = sketch.sketchCurves.sketchLines
    for i, a in enumerate(pts):
        b = pts[(i + 1) % len(pts)]
        lines.addByTwoPoints(
            adsk.core.Point3D.create(mm(a[0]), mm(a[1]), 0),
            adsk.core.Point3D.create(mm(b[0]), mm(b[1]), 0),
        )


def add_rounded_rect(sketch, x1, y1, x2, y2, radius):
    r = min(radius, abs(x2 - x1) * 0.5 - 0.05, abs(y2 - y1) * 0.5 - 0.05)
    lines = sketch.sketchCurves.sketchLines
    arcs = sketch.sketchCurves.sketchArcs
    pts = {
        "b0": (x1 + r, y1), "b1": (x2 - r, y1),
        "r0": (x2, y1 + r), "r1": (x2, y2 - r),
        "t0": (x2 - r, y2), "t1": (x1 + r, y2),
        "l0": (x1, y2 - r), "l1": (x1, y1 + r),
        "cbr": (x2 - r, y1 + r), "ctr": (x2 - r, y2 - r),
        "ctl": (x1 + r, y2 - r), "cbl": (x1 + r, y1 + r),
    }

    def p(name):
        a, b = pts[name]
        return adsk.core.Point3D.create(mm(a), mm(b), 0)

    lines.addByTwoPoints(p("b0"), p("b1"))
    arcs.addByCenterStartEnd(p("cbr"), p("b1"), p("r0"))
    lines.addByTwoPoints(p("r0"), p("r1"))
    arcs.addByCenterStartEnd(p("ctr"), p("r1"), p("t0"))
    lines.addByTwoPoints(p("t0"), p("t1"))
    arcs.addByCenterStartEnd(p("ctl"), p("t1"), p("l0"))
    lines.addByTwoPoints(p("l0"), p("l1"))
    arcs.addByCenterStartEnd(p("cbl"), p("l1"), p("b0"))


def extrude(comp, profile, height_mm, operation, bodies=None, negative=False):
    features = comp.features.extrudeFeatures
    inp = features.createInput(profile, operation)
    extent = adsk.fusion.DistanceExtentDefinition.create(
        adsk.core.ValueInput.createByReal(mm(abs(height_mm)))
    )
    direction = (
        adsk.fusion.ExtentDirections.NegativeExtentDirection
        if negative
        else adsk.fusion.ExtentDirections.PositiveExtentDirection
    )
    inp.setOneSideExtent(extent, direction)
    inp.isSolid = True
    if bodies is not None:
        inp.participantBodies = bodies
    return features.add(inp)


def new_body(comp, profile, height_mm, negative=False):
    return extrude(
        comp, profile, height_mm,
        adsk.fusion.FeatureOperations.NewBodyFeatureOperation,
        negative=negative,
    )


def join_body(comp, profile, height_mm, bodies, negative=False):
    return extrude(
        comp, profile, height_mm,
        adsk.fusion.FeatureOperations.JoinFeatureOperation,
        bodies=bodies, negative=negative,
    )


def cut_body(comp, profile, height_mm, bodies, negative=False):
    return extrude(
        comp, profile, height_mm,
        adsk.fusion.FeatureOperations.CutFeatureOperation,
        bodies=bodies, negative=negative,
    )


def last_body(feature):
    return feature.bodies.item(0)


def name_body(body, name, opacity=1.0):
    body.name = name
    body.opacity = opacity
    return body


def plane_at(comp, z_mm, name):
    planes = comp.constructionPlanes
    inp = planes.createInput()
    inp.setByOffset(
        comp.xYConstructionPlane,
        adsk.core.ValueInput.createByReal(mm(z_mm)),
    )
    plane = planes.add(inp)
    plane.name = name
    return plane


def plane_at_x(comp, x_mm, name):
    planes = comp.constructionPlanes
    inp = planes.createInput()
    inp.setByOffset(
        comp.yZConstructionPlane,
        adsk.core.ValueInput.createByReal(mm(x_mm)),
    )
    plane = planes.add(inp)
    plane.name = name
    return plane


def plane_at_y(comp, y_mm, name):
    planes = comp.constructionPlanes
    inp = planes.createInput()
    inp.setByOffset(
        comp.xZConstructionPlane,
        adsk.core.ValueInput.createByReal(mm(y_mm)),
    )
    plane = planes.add(inp)
    plane.name = name
    return plane


def component(root, name):
    occ = root.occurrences.addNewComponent(adsk.core.Matrix3D.create())
    comp = occ.component
    comp.name = name
    return comp


def paint(design, wanted):
    """Tint bodies so the dummy board reads through the shells."""
    app = adsk.core.Application.get()
    library = None
    for i in range(app.materialLibraries.count):
        item = app.materialLibraries.item(i)
        if item.name == "Fusion Appearance Library":
            library = item
            break
    copies = {}
    root = design.rootComponent
    for occ in root.allOccurrences:
        for body in occ.bRepBodies:
            appearance_name = wanted.get(body.name)
            if appearance_name is None:
                continue
            if appearance_name not in copies:
                source = library.appearances.itemByName(appearance_name)
                copy = design.appearances.itemByName(appearance_name)
                if copy is None:
                    copy = design.appearances.addByCopy(source, appearance_name)
                copies[appearance_name] = copy
            body.appearance = copies[appearance_name]


def paint_bodies(design, bodies, appearance_name):
    """Give a list of bodies one appearance from the Fusion library."""
    app = adsk.core.Application.get()
    library = None
    for i in range(app.materialLibraries.count):
        item = app.materialLibraries.item(i)
        if item.name == "Fusion Appearance Library":
            library = item
            break
    copy = design.appearances.itemByName(appearance_name)
    if copy is None:
        copy = design.appearances.addByCopy(
            library.appearances.itemByName(appearance_name), appearance_name
        )
    for body in bodies:
        body.appearance = copy


def _drop_front_onto_bed(path, z_mm):
    """Move an exported front down so the skirt sits on z = 0."""
    import struct
    import zipfile

    if path.endswith(".stl"):
        data = bytearray(open(path, "rb").read())
        count = struct.unpack_from("<I", data, 80)[0]
        for i in range(count):
            at = 84 + i * 50
            for slot in (5, 8, 11):
                z = struct.unpack_from("<f", data, at + slot * 4)[0]
                struct.pack_into("<f", data, at + slot * 4, z - z_mm)
        open(path, "wb").write(data)
        return

    with zipfile.ZipFile(path) as archive:
        files = {name: archive.read(name) for name in archive.namelist()}
    text = files["3D/3dmodel.model"].decode("utf-8")

    def lower(match):
        z = float(match.group(1)) - z_mm
        return f'z="{z:.6f}"'

    import re
    files["3D/3dmodel.model"] = re.sub(
        r'z="([-0-9.]+)"', lower, text
    ).encode("utf-8")
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, content in files.items():
            archive.writestr(name, content)


def _write_printable_front(path):
    """Rewrite the front 3MF as one mesh Bambu Studio will actually slice.

    A saved Bambu project marked the part not printable and shifted the
    inlay out of its pocket, so the preview plate came out empty. This
    file is one solid: the shell on filament 1, the O on filament 2.
    """
    import re
    import zipfile

    with zipfile.ZipFile(path) as archive:
        model = archive.read("3D/3dmodel.model").decode("utf-8")

    chunks = re.split(r"<object\b", model)[1:]
    meshes = []
    for chunk in chunks:
        name = re.search(r'name="([^"]+)"', chunk)
        verts = [
            (float(x), float(y), float(z))
            for x, y, z in re.findall(
                r'<vertex x="([^"]+)" y="([^"]+)" z="([^"]+)"', chunk
            )
        ]
        tris = [
            (int(a), int(b), int(c))
            for a, b, c in re.findall(
                r'<triangle v1="(\d+)" v2="(\d+)" v3="(\d+)"', chunk
            )
        ]
        if verts and tris:
            meshes.append((name.group(1) if name else "", verts, tris))
    if not meshes:
        raise RuntimeError("front 3MF has no mesh")

    all_verts = [v for _, verts, _ in meshes for v in verts]
    min_x = min(v[0] for v in all_verts)
    min_y = min(v[1] for v in all_verts)
    min_z = min(v[2] for v in all_verts)
    # Park it in the middle of a 256 mm plate, skirt on the bed.
    shift = (128 - (min_x + max(v[0] for v in all_verts)) / 2,
             128 - (min_y + max(v[1] for v in all_verts)) / 2,
             -min_z)

    vertices = []
    triangles = []
    for name, verts, tris in meshes:
        base = len(vertices)
        ink = "8" if "inlay" in name.lower() or "orbit" in name.lower() else "4"
        vertices.extend(
            (x + shift[0], y + shift[1], z + shift[2]) for x, y, z in verts
        )
        triangles.extend((base + a, base + b, base + c, ink) for a, b, c in tris)

    vert_xml = "\n".join(
        f'      <vertex x="{x:.6f}" y="{y:.6f}" z="{z:.6f}"/>'
        for x, y, z in vertices
    )
    tri_xml = "\n".join(
        f'      <triangle v1="{a}" v2="{b}" v3="{c}" paint_color="{ink}"/>'
        for a, b, c, ink in triangles
    )
    model_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
  <metadata name="Title">Front shell</metadata>
  <resources>
    <object id="1" name="Front shell" type="model">
      <mesh>
        <vertices>
{vert_xml}
        </vertices>
        <triangles>
{tri_xml}
        </triangles>
      </mesh>
    </object>
  </resources>
  <build>
    <item objectid="1" printable="1"/>
  </build>
</model>
"""
    content_types = """<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
</Types>
"""
    rels = """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
</Relationships>
"""
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", content_types)
        archive.writestr("_rels/.rels", rels)
        archive.writestr("3D/3dmodel.model", model_xml)
    zs = [v[2] for v in vertices]
    print(
        f"printable front: {len(triangles)} tris, "
        f"z[{min(zs):.2f},{max(zs):.2f}], "
        f"white tris {sum(1 for t in triangles if t[3] == '8')}"
    )


def box(comp, x, y, z, w, l, h, name, opacity=1.0):
    """Axis-aligned box. z is the bottom face."""
    sk = comp.sketches.add(plane_at(comp, z, f"plane_{name}"))
    sk.name = name
    add_rect(sk, x, y, x + w, y + l)
    return name_body(last_body(new_body(comp, largest_profile(sk), h)), name, opacity)


def run(_context):
    app = adsk.core.Application.get()
    app.documents.add(adsk.core.DocumentTypes.FusionDesignDocumentType)
    design = adsk.fusion.Design.cast(app.activeProduct)
    design.designType = adsk.fusion.DesignTypes.ParametricDesignType
    root = design.rootComponent
    app.activeDocument.name = "OpenPendant character case"
    design.rootComponent.description = (
        "Orbit O case. Card sealed inside, shells still open. "
        "5 mm chain bail on the back. Orbit inlaid flush, button hat is "
        "the planet on the ring. See cad/character/PRINT.txt."
    )

    # --- dummy electronics, in the assembled position -------------------
    elec = component(root, "Electronics")
    box(elec, 0, 0, Z_PCB, PCB_W, PCB_H, PCB_T, "PCB", 0.95)
    box(elec, XIAO[0], XIAO[1], Z_SPLIT, XIAO[2], XIAO[3], XIAO[4], "XIAO", 1.0)
    box(
        elec, USB[0], USB[1], Z_SPLIT,
        USB[2] - USB[0], USB[3] - USB[1], USB[4], "USB_C", 1.0,
    )
    box(
        elec, SD[0], SD[1], Z_SPLIT,
        SD[2] - SD[0], SD[3] - SD[1], SD[4], "SD_socket", 1.0,
    )
    box(
        elec, SD_MOUTH[0], SD_MOUTH[1], Z_SPLIT + 0.25,
        SD_MOUTH[2] - SD_MOUTH[0], SD_MOUTH[3] - SD_MOUTH[1], SD_MOUTH[4],
        "SD_mouth", 1.0,
    )
    box(
        elec, BTN[0] - BTN[2] / 2, BTN[1] - BTN[3] / 2, Z_SPLIT,
        BTN[2], BTN[3], BTN[4], "Button", 1.0,
    )
    box(
        elec, CAP[0] - CAP[2] / 2, CAP[1] - CAP[3] / 2, Z_SPLIT,
        CAP[2], CAP[3], CAP[4], "Cap_22uF", 1.0,
    )
    box(elec, CELL[0], CELL[1], Z_CELL, CELL[2], CELL[3], CELL[4], "Cell", 0.85)

    # --- back shell: chest face is Z = 0 --------------------------------
    back_comp = component(root, "Back shell")
    sk = back_comp.sketches.add(back_comp.xYConstructionPlane)
    sk.name = "Back_outline"
    add_rounded_rect(sk, BACK_X1, BACK_Y1, BACK_X2, BACK_Y2, OUTER_R)
    back = name_body(
        last_body(new_body(back_comp, largest_profile(sk), Z_SPLIT)),
        "Back_Shell", 1.0,
    )

    # Board drops in and sits on the ledge around the cell pocket.
    sk = back_comp.sketches.add(plane_at(back_comp, Z_PCB, "plane_board"))
    sk.name = "Board_pocket"
    add_rect(sk, CAV_X1, CAV_Y1, CAV_X2, CAV_Y2)
    cut_body(back_comp, largest_profile(sk), Z_SPLIT - Z_PCB + 0.2, [back])

    sk = back_comp.sketches.add(plane_at(back_comp, Z_CELL, "plane_cell"))
    sk.name = "Cell_pocket"
    add_rect(
        sk,
        CELL[0] - 0.3, CELL[1] - 0.3,
        CELL[0] + CELL[2] + 0.3, CELL[1] + CELL[3] + 0.3,
    )
    cut_body(back_comp, largest_profile(sk), CELL[4] + CELL_AIR, [back])

    # Open bay under the board, from the USB end up to the cell. The soldered
    # leads live here. They cannot run between the cell and the board.
    sk = back_comp.sketches.add(plane_at(back_comp, Z_CELL, "plane_wires"))
    sk.name = "Wire_bay"
    add_rect(sk, 0.8, 0.6, 22.2, CELL[1] + 0.4)
    cut_body(back_comp, largest_profile(sk), CELL[4] + CELL_AIR, [back])

    # The pocket is long, so the USB plug and the card guide fit. Without
    # these stops the board slides in that extra room. The ends leave
    # 0.15 mm. The long sides leave 0.5 mm: a closer stop prints tight
    # and shears off when the board is pressed in. The side ribs sit
    # beside the board, not over it. The lid keeps the board down.
    play = 0.15
    side_gap = 0.5
    for name, x1, y1, x2, y2 in (
        ("Lock_S_left", 0.6, -1.4, 4.4, -play),
        ("Lock_S_right", 18.6, -1.4, 22.4, -play),
        ("Lock_N_left", 0.4, PCB_H + play, 2.6, PCB_H + 1.3),
        ("Lock_N_right", 21.0, PCB_H + play, 22.6, PCB_H + 1.3),
        ("Lock_W", -1.5, 14.0, -side_gap, 18.0),
        ("Lock_E", PCB_W + side_gap, 14.0, PCB_W + 1.5, 18.0),
    ):
        sk = back_comp.sketches.add(plane_at(back_comp, Z_PCB, f"plane_{name}"))
        sk.name = name
        add_rect(sk, x1, y1, x2, y2)
        join_body(back_comp, largest_profile(sk), PCB_T, [back])
    # The pocket wall is only 0.35 mm from the board. Open it to the
    # same 0.5 mm as the side stops, or the wall becomes the new stop.
    for name, x1, x2 in (
        ("Side_gap_W", -side_gap, CAV_X1),
        ("Side_gap_E", CAV_X2, PCB_W + side_gap),
    ):
        sk = back_comp.sketches.add(plane_at(back_comp, Z_PCB, f"plane_{name}"))
        sk.name = name
        add_rect(sk, x1, -0.2, x2, PCB_H + 0.2)
        cut_body(back_comp, largest_profile(sk), PCB_T + 0.2, [back])
    for name, x1, x2 in (
        ("Clip_W", -1.4, -side_gap),
        ("Clip_E", PCB_W + side_gap, PCB_W + 1.4),
    ):
        sk = back_comp.sketches.add(plane_at(back_comp, Z_SPLIT - 0.2, f"plane_{name}"))
        sk.name = name
        add_rect(sk, x1, 20.0, x2, 22.8)
        join_body(back_comp, largest_profile(sk), 0.7, [back])

    # Chain bail. A sketch on the YZ plane maps sketch X to -Z and sketch Y
    # to Y. The hole runs left to right, past the skirt, clear of the card.
    bail_x = (BACK_X1 + BACK_X2) / 2 - BAIL_W / 2
    sk = back_comp.sketches.add(plane_at_x(back_comp, bail_x, "plane_bail_neck"))
    sk.name = "Chain_neck"
    add_rounded_rect(sk, -NECK_Z2, BAIL_Y1, -HEAD_Z1, HEAD_Y1 + 0.6, 1.2)
    join_body(back_comp, largest_profile(sk), BAIL_W, [back])
    sk = back_comp.sketches.add(plane_at_x(back_comp, bail_x, "plane_bail"))
    sk.name = "Chain_bail"
    add_rounded_rect(sk, -HEAD_Z2, HEAD_Y1, -HEAD_Z1, HEAD_Y2, 1.6)
    join_body(back_comp, largest_profile(sk), BAIL_W, [back])
    hole_y = HEAD_Y1 + BAIL_WALL + CHAIN_D / 2
    hole_z = HEAD_Z1 + BAIL_WALL + CHAIN_D / 2
    sk = back_comp.sketches.add(plane_at_x(back_comp, bail_x - 0.2, "plane_bail_hole"))
    sk.name = "Chain_hole"
    add_circle(sk, -hole_z, hole_y, CHAIN_D)
    cut_body(back_comp, largest_profile(sk), BAIL_W + 0.4, [back])

    # Pockets for the lid catches. Shallow, so the wall stays whole.
    # The catch ramp needs the full height; the flat top is what holds.
    catch_ys = (7.5, 24.5)
    catch_l = 8.0
    catch_z0 = Z_SPLIT - 2.7
    catch_z2 = Z_SPLIT - 0.8
    for side, x1, x2 in (
        ("L", BACK_X1 - 0.3, BACK_X1 + 0.55),
        ("R", BACK_X2 - 0.55, BACK_X2 + 0.3),
    ):
        for n, y1 in enumerate(catch_ys):
            sk = back_comp.sketches.add(
                plane_at(back_comp, catch_z0 - 0.25, f"plane_pocket_{side}_{n}")
            )
            sk.name = f"Snap_pocket_{side}_{n}"
            add_rect(sk, x1, y1 - 0.35, x2, y1 + catch_l + 0.35)
            cut_body(
                back_comp, largest_profile(sk),
                catch_z2 - catch_z0 + 0.55, [back],
            )

    # --- front shell, skirt wraps the back -------------------------------
    front_comp = component(root, "Front shell")
    sk = front_comp.sketches.add(plane_at(front_comp, Z_SPLIT, "plane_front"))
    sk.name = "Front_outline"
    add_rounded_rect(sk, FRONT_X1, FRONT_Y1, FRONT_X2, FRONT_Y2, OUTER_R)
    front = name_body(
        last_body(new_body(front_comp, largest_profile(sk), Z_FRONT - Z_SPLIT)),
        "Front_Shell", 1.0,
    )

    # Skirt. Inner edge clears the back by SKIRT_GAP, so it is a ring.
    sk = front_comp.sketches.add(plane_at(front_comp, Z_SPLIT, "plane_skirt"))
    sk.name = "Front_skirt"
    add_rounded_rect(sk, FRONT_X1, FRONT_Y1, FRONT_X2, FRONT_Y2, OUTER_R)
    add_rounded_rect(
        sk,
        BACK_X1 - SKIRT_GAP, BACK_Y1 - SKIRT_GAP,
        BACK_X2 + SKIRT_GAP, BACK_Y2 + SKIRT_GAP,
        max(OUTER_R - SKIRT_T - SKIRT_GAP, 1.5),
    )
    join_body(front_comp, ring_profile(sk), LIP, [front], negative=True)

    sk = front_comp.sketches.add(plane_at(front_comp, Z_SPLIT, "plane_cavity"))
    sk.name = "Front_cavity"
    add_rect(sk, CAV_X1, CAV_Y1, CAV_X2, CAV_Y2)
    cut_body(front_comp, largest_profile(sk), Z_CAVITY, [front])

    # A catch is a ramp on the skirt, not a tooth. The whole skirt
    # flexes over it. The flat top sits in the pocket and holds the lid.
    # Sketch on the XZ plane: sketch X is world X, sketch Y is world Z.
    z_ramp = Z_SPLIT - 1.6
    for side, sign in (("L", 1), ("R", -1)):
        if sign > 0:
            x_root = BACK_X1 - SKIRT_GAP - 0.3
            x_tip = BACK_X1 + 0.40
            x_lead = BACK_X1 - SKIRT_GAP + 0.12
        else:
            x_root = BACK_X2 + SKIRT_GAP + 0.3
            x_tip = BACK_X2 - 0.40
            x_lead = BACK_X2 + SKIRT_GAP - 0.12
        for n, y1 in enumerate(catch_ys):
            sk = front_comp.sketches.add(
                plane_at_y(front_comp, y1, f"plane_catch_{side}_{n}")
            )
            sk.name = f"Snap_catch_{side}_{n}"
            # On this plane sketch Y points along -Z.
            add_polygon(sk, [
                (x_root, -catch_z0),
                (x_lead, -catch_z0),
                (x_tip, -z_ramp),
                (x_tip, -catch_z2),
                (x_root, -catch_z2),
            ])
            join_body(front_comp, largest_profile(sk), catch_l, [front])

    both = [front, back]

    # The USB-C metal face is the end of the case, the way a finished
    # product is built. The cable's metal tongue plugs straight into the
    # receptacle; the plastic housing never has to enter the case.
    usb_face = USB[1]
    sk = front_comp.sketches.add(plane_at(front_comp, -0.4, "plane_usb_trim"))
    sk.name = "USB_trim"
    add_rect(sk, FRONT_X1 - 1.0, FRONT_Y1 - 1.0, FRONT_X2 + 1.0, usb_face)
    cut_body(front_comp, largest_profile(sk), Z_FRONT + 1.0, both)
    # Close the end again. The trim opens the cavity, and this wall is
    # what the connector sits in.
    sk = front_comp.sketches.add(plane_at(front_comp, Z_SPLIT, "plane_usb_wall"))
    sk.name = "USB_wall"
    add_rect(sk, CAV_X1, usb_face, CAV_X2, usb_face + WALL)
    join_body(front_comp, largest_profile(sk), Z_CAVITY, [front])
    sk = back_comp.sketches.add(plane_at(back_comp, Z_PCB, "plane_usb_wall_back"))
    sk.name = "USB_wall_back"
    add_rect(sk, CAV_X1, usb_face, CAV_X2, usb_face + WALL)
    join_body(back_comp, largest_profile(sk), PCB_T, [back])
    # The receptacle sits on the XIAO, so its top is higher than the
    # carrier. A short opening leaves the front shell covering the
    # metal. This one clears the connector on every side.
    sk = front_comp.sketches.add(plane_at(front_comp, Z_SPLIT - 0.5, "plane_usb"))
    sk.name = "USB_port"
    add_rounded_rect(
        sk, USB[0] - 0.5, usb_face - 0.5, USB[2] + 0.5, usb_face + WALL + 0.4, 1.5,
    )
    cut_body(front_comp, largest_profile(sk), 5.3, both)

    # The trim leaves the USB end square. Round those two corners to
    # the same radius as the top, so all four corners match. The flat
    # middle of the end stays on the connector.
    r = OUTER_R
    cy = usb_face + r
    for name, x_out, cx in (
        ("L", FRONT_X1, FRONT_X1 + r),
        ("R", FRONT_X2, FRONT_X2 - r),
    ):
        sk = front_comp.sketches.add(plane_at(front_comp, -0.4, f"plane_usb_round_{name}"))
        sk.name = f"USB_round_{name}"
        if x_out < cx:
            add_rect(sk, x_out - 0.6, usb_face - 0.6, cx - 0.05, cy - 0.05)
        else:
            add_rect(sk, cx + 0.05, usb_face - 0.6, x_out + 0.6, cy - 0.05)
        add_circle(sk, cx, cy, r * 2)
        cut_body(
            front_comp, profile_nearest(sk, x_out, usb_face),
            Z_FRONT + 1.0, both,
        )

    sk = front_comp.sketches.add(plane_at(front_comp, Z_SPLIT + Z_CAVITY, "plane_mic"))
    sk.name = "Mic_hole"
    add_circle(sk, MIC[0], MIC[1], MIC[2])
    cut_body(front_comp, largest_profile(sk), WALL + 0.4, [front])

    sk = front_comp.sketches.add(plane_at(front_comp, Z_SPLIT + Z_CAVITY, "plane_led"))
    sk.name = "LED_hole"
    add_circle(sk, LED[0], LED[1], LED[2])
    cut_body(front_comp, largest_profile(sk), WALL + 0.4, [front])

    sk = front_comp.sketches.add(plane_at(front_comp, Z_SPLIT + Z_CAVITY, "plane_btn"))
    sk.name = "Button_hole"
    # Larger than the hat head, smaller than the retaining disc.
    add_circle(sk, BTN[0], BTN[1], 6.6)
    cut_body(front_comp, largest_profile(sk), WALL + 0.4, [front])

    # The logo: a tall O drawn as an orbit, centered on the face. It is
    # an inlay, not a relief. Each shape is a pocket 0.6 mm deep in the
    # lid, filled flush by its own white body, so the face stays flat
    # and the slicer can give the inlays their own filament. The ring
    # stroke is 3.5 mm wide so a 0.4 mm nozzle prints it solid. The
    # pocket floor leaves 0.6 mm of lid under the art.
    inlays = []

    def inlay(name, profile):
        body = name_body(
            last_body(new_body(front_comp, profile, INLAY_D, negative=True)),
            name, 1.0,
        )
        cut_body(front_comp, profile, INLAY_D, [front], negative=True)
        inlays.append(body)

    sk = front_comp.sketches.add(plane_at(front_comp, Z_FRONT, "plane_orbit"))
    sk.name = "Orbit_Inlay"
    add_ellipse(sk, ORBIT_CX, ORBIT_CY, ORBIT_RX_OUT, ORBIT_RY_OUT)
    add_ellipse(sk, ORBIT_CX, ORBIT_CY, ORBIT_RX_IN, ORBIT_RY_IN)
    inlay("Orbit_Inlay", ring_profile(sk))

    # The planet seam. The button hole above was cut before the inlay
    # existed, so cut it again through the inlay and the lid. The hat
    # head (5.2 mm) sits in this 6.6 mm hole with black shell around it.
    sk = front_comp.sketches.add(plane_at(front_comp, Z_FRONT, "plane_seam"))
    sk.name = "Planet_seam"
    add_circle(sk, BTN[0], BTN[1], 6.6)
    cut_body(
        front_comp, largest_profile(sk), INLAY_D + WALL + 0.4,
        [front] + inlays, negative=True,
    )

    # Fingernail notches between the snaps, straddling the seam.
    for side, (x1, x2) in enumerate((
        (FRONT_X1 - 0.2, FRONT_X1 + 1.3),
        (FRONT_X2 - 1.3, FRONT_X2 + 0.2),
    )):
        sk = front_comp.sketches.add(
            plane_at(front_comp, Z_SPLIT - 1.1, f"plane_nail_{side}")
        )
        sk.name = f"Nail_{side}"
        add_rect(sk, x1, 17.0, x2, 23.0)
        cut_body(front_comp, largest_profile(sk), 2.2, both)

    # The head is the small end. Push it out through the hole from inside
    # the shell. The disc is the wide end, against the inside of the lid,
    # and it cannot follow. Print the disc on the bed.
    hat_comp = component(root, "Button hat")
    ceiling = Z_SPLIT + Z_CAVITY
    rest = Z_SPLIT + BTN[4] + 0.35
    sk = hat_comp.sketches.add(plane_at(hat_comp, rest, "plane_flange"))
    sk.name = "Hat_disc"
    add_circle(sk, BTN[0], BTN[1], 7.4)
    hat = name_body(
        last_body(new_body(hat_comp, largest_profile(sk), ceiling - rest)),
        "Button_Hat", 1.0,
    )

    sk = hat_comp.sketches.add(plane_at(hat_comp, ceiling, "plane_shaft"))
    sk.name = "Hat_shaft"
    add_circle(sk, BTN[0], BTN[1], 3.8)
    join_body(hat_comp, largest_profile(sk), WALL, [hat])

    # The planet stands 1 mm proud of the flush face. That is the one
    # bump kept on purpose: it is how a finger finds the button.
    sk = hat_comp.sketches.add(plane_at(hat_comp, Z_FRONT, "plane_head"))
    sk.name = "Hat_head"
    add_circle(sk, BTN[0], BTN[1], 5.2)
    join_body(hat_comp, largest_profile(sk), 1.0, [hat])

    paint(design, {
        "PCB": "Plastic - Matte (Green)",
        "XIAO": "Plastic - Matte (Black)",
        "USB_C": "Plastic - Matte (Gray)",
        "SD_socket": "Plastic - Matte (Black)",
        "SD_mouth": "Plastic - Matte (Gray)",
        "Button": "Plastic - Matte (White)",
        "Cap_22uF": "Plastic - Matte (Yellow)",
        "Cell": "Plastic - Matte (Blue)",
        "Back_Shell": "Plastic - Matte (Black)",
        "Front_Shell": "Plastic - Matte (Black)",
        "Button_Hat": "Plastic - Matte (White)",
    })
    paint_bodies(design, inlays, "Plastic - Matte (White)")

    # --- files a slicer can open ------------------------------------------
    os.makedirs(OUT_DIR, exist_ok=True)
    export = design.exportManager
    exported = []
    # The front exports as a whole component, so the STL carries the
    # shell and every inlay body, each as its own part for the slicer.
    front_occ = None
    for occ in root.occurrences:
        if occ.component.name == "Front shell":
            front_occ = occ
            break
    for item, filename in (
        (back, "character_back.stl"),
        (front_occ, "character_front.stl"),
        (hat, "character_button_hat.stl"),
    ):
        path = os.path.join(OUT_DIR, filename)
        opts = export.createSTLExportOptions(item, path)
        opts.meshRefinement = adsk.fusion.MeshRefinementSettings.MeshRefinementMedium
        export.execute(opts)
        exported.append(path)

    # The front also goes out as a 3MF, because that format keeps the
    # body names: Front_Shell and Orbit_Inlay arrive in the slicer as
    # two named parts of one model, ready for two filaments.
    path = os.path.join(OUT_DIR, "character_front.3mf")
    opts = export.createC3MFExportOptions(front_occ, path)
    export.execute(opts)
    exported.append(path)
    # Fusion writes the mesh in assembly coordinates, so the skirt
    # starts at z = 7.2 mm. A slicer then shows an empty plate until
    # you scroll up. Shift the exported front down onto the bed.
    _drop_front_onto_bed(os.path.join(OUT_DIR, "character_front.stl"), Z_SPLIT - LIP)
    _drop_front_onto_bed(os.path.join(OUT_DIR, "character_front.3mf"), Z_SPLIT - LIP)
    _write_printable_front(os.path.join(OUT_DIR, "character_front.3mf"))

    archive = os.path.join(OUT_DIR, "character_case.f3d")
    opts = export.createFusionArchiveExportOptions(archive, root)
    export.execute(opts)
    exported.append(archive)

    for occ in root.allOccurrences:
        for i in range(occ.component.sketches.count):
            occ.component.sketches.item(i).isVisible = False
        for i in range(occ.component.constructionPlanes.count):
            occ.component.constructionPlanes.item(i).isLightBulbOn = False

    app.activeViewport.fit()
    width = FRONT_X2 - FRONT_X1
    print(
        f"closed {width:.1f} mm wide | seam z={Z_SPLIT:.1f} | "
        f"bail y {BAIL_Y1:.1f}..{HEAD_Y2:.1f} | chain {CHAIN_D:.1f} mm | "
        f"orbit inlay {INLAY_D:.1f} mm flush"
    )
    for path in exported:
        print("exported", path)
