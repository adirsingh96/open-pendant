#!/usr/bin/env python3
"""Printable case and a dummy of the carrier, for the Fusion overview.

Sized to the 23 x 38 mm board in openpendant_carrier.kicad_pcb.
Coordinates are millimetres and match KiCad: X across, Y up the pendant,
USB at Y = 0, the card mouth at the top. Z = 0 is the outside of the
back shell (the face against the chest). The front is +Z.

The front skirt wraps the outside of the back, so the lip never lands
on a solder pad. Print on a 0.4 mm nozzle, 0.2 mm layers. PETG if you
have it (the skirt has to flex once); PLA is fine for a fit check.
No supports.
  Back: chest face on the bed, cavity up.
  Front: skirt on the bed, so the cord ears point up. The ears stand
  either side of the card slot. The cord runs above the slot, and the
  card slides in under the cord.
  Button hat: wide disc on the bed, head pointing up. The head is
  smaller than the hole, so it pushes through from inside the shell.
  The disc stays inside and cannot pull out.
"""

import os

import adsk.core
import adsk.fusion

CAD = "/Users/aditidutt/ai_pendent/hardware/openpendant_carrier/cad"
PRINT_DIR = os.path.join(CAD, "print")

# Board and the parts that sit on it. These are the KiCad placements.
PCB_W, PCB_H, PCB_T = 23.0, 38.0, 1.6
XIAO = (2.6, 0.0, 17.8, 21.0, 3.5)       # x, y, w, l, h
USB = (6.8, -2.2, 16.2, 0.4, 3.2)        # x1, y1, x2, y2, h above the board
SD = (1.0, 24.9, 14.7, 37.9, 1.5)
SD_MOUTH = (2.2, 37.6, 13.2, 41.2, 1.0)  # card guide, hangs off the board
BTN = (19.2, 30.2, 4.2, 3.0, 1.8)        # center x, y, w, l, h
CAP = (9.0, 22.9, 2.0, 1.25, 1.15)
CELL = (1.5, 8.0, 20.0, 30.0, 6.0)       # wire bay is y = 0..8, on the back
MIC = (11.5, 17.0, 3.0)                  # over the antenna end of the XIAO
LED = (16.8, 3.8, 1.8)                   # charge light, USB end

# 1.2 mm is three 0.4 mm perimeters. The skirt is two.
WALL = 1.2
GAP = 0.35
SKIRT_T = 0.8
SKIRT_GAP = 0.25
LIP = 2.0
CELL_AIR = 0.4
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
# Cord ears stand either side of the card. The opening between them is
# clear from the socket mouth out past the case, and the cord hole sits
# above that opening.
CARD_X1, CARD_X2 = 1.2, 14.8
EAR_Y2 = FRONT_Y2 + 8.0
LANYARD_D = 4.2

Z_CELL = WALL
Z_PCB = Z_CELL + CELL[4] + CELL_AIR
Z_SPLIT = Z_PCB + PCB_T
Z_CAVITY = XIAO[4] + FRONT_AIR
Z_FRONT = Z_SPLIT + Z_CAVITY + WALL
# Slot top, then 0.6 mm, then the 4.2 mm hole, then 1.2 mm of plastic.
EAR_Z1 = Z_SPLIT + 2.2 + 0.6 + LANYARD_D + 1.2


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


def add_circle(sketch, x, y, diameter):
    sketch.sketchCurves.sketchCircles.addByCenterRadius(
        adsk.core.Point3D.create(mm(x), mm(y), 0),
        mm(diameter) * 0.5,
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
    design.rootComponent.description = (
        "23 x 38 mm carrier, dummy electronics, and a two-piece printed case. "
        "0.4 mm nozzle, 0.2 mm layers, PETG preferred. No supports."
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
        "Back_Shell", 0.35,
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

    # Snap windows in the long walls, where the skirt wraps them.
    for side, (x1, x2) in enumerate((
        (BACK_X1 - 0.2, CAV_X1 + 0.05),
        (CAV_X2 - 0.05, BACK_X2 + 0.2),
    )):
        for n, y1 in enumerate((10.0, 26.0)):
            sk = back_comp.sketches.add(
                plane_at(back_comp, Z_SPLIT - 1.5, f"plane_win_{side}_{n}")
            )
            sk.name = f"Snap_window_{side}_{n}"
            add_rect(sk, x1, y1, x2, y1 + 4.0)
            cut_body(back_comp, largest_profile(sk), 1.15, [back])

    # --- front shell, skirt wraps the back -------------------------------
    front_comp = component(root, "Front shell")
    sk = front_comp.sketches.add(plane_at(front_comp, Z_SPLIT, "plane_front"))
    sk.name = "Front_outline"
    add_rounded_rect(sk, FRONT_X1, FRONT_Y1, FRONT_X2, FRONT_Y2, OUTER_R)
    front = name_body(
        last_body(new_body(front_comp, largest_profile(sk), Z_FRONT - Z_SPLIT)),
        "Front_Shell", 0.35,
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

    # Two ears. The card corridor between them stays open. The cord hole
    # is above the slot, so the chain crosses over the card, not through it.
    ear_y1 = FRONT_Y2 - 0.8
    ear_z0 = Z_SPLIT - 0.2
    for name, x1, x2 in (
        ("Ear_left", FRONT_X1, CARD_X1 - 0.2),
        ("Ear_right", CARD_X2 + 7.2, FRONT_X2),
    ):
        sk = front_comp.sketches.add(plane_at(front_comp, ear_z0, f"plane_{name}"))
        sk.name = name
        add_rounded_rect(sk, x1, ear_y1, x2, EAR_Y2, 1.6)
        join_body(front_comp, largest_profile(sk), EAR_Z1 - ear_z0, [front])

    hole_z = Z_SPLIT + 2.2 + 0.6 + LANYARD_D / 2
    hole_y = FRONT_Y2 + 4.0
    for name, x0, length in (
        ("Lanyard_left", FRONT_X1 - 1.0, (CARD_X1 - 0.2) - FRONT_X1 + 2.0),
        ("Lanyard_right", CARD_X2 + 7.2 - 1.0, FRONT_X2 - (CARD_X2 + 7.2) + 2.0),
    ):
        sk = front_comp.sketches.add(plane_at_x(front_comp, x0, f"plane_{name}"))
        sk.name = name
        # A sketch on a YZ plane maps sketch X to -Z and sketch Y to Y.
        add_circle(sk, -hole_z, hole_y, LANYARD_D)
        cut_body(front_comp, largest_profile(sk), length, [front])

    sk = front_comp.sketches.add(plane_at(front_comp, Z_SPLIT, "plane_cavity"))
    sk.name = "Front_cavity"
    add_rect(sk, CAV_X1, CAV_Y1, CAV_X2, CAV_Y2)
    cut_body(front_comp, largest_profile(sk), Z_CAVITY, [front])

    # Teeth on the inside of the skirt, 0.25 mm into the back wall.
    for side, x1 in enumerate((
        BACK_X1 - SKIRT_GAP - 0.15,
        BACK_X2 + SKIRT_GAP - 0.55,
    )):
        for n, y1 in enumerate((10.7, 26.7)):
            sk = front_comp.sketches.add(
                plane_at(front_comp, Z_SPLIT - 1.35, f"plane_tooth_{side}_{n}")
            )
            sk.name = f"Snap_tooth_{side}_{n}"
            add_rect(sk, x1, y1, x1 + 0.7, y1 + 2.6)
            join_body(front_comp, largest_profile(sk), 0.9, [front])

    both = [front, back]

    # The USB-C metal face is the end of the case. The opening is only
    # the connector, so a cable plugs straight in.
    usb_face = USB[1]
    sk = front_comp.sketches.add(plane_at(front_comp, -0.4, "plane_usb_trim"))
    sk.name = "USB_trim"
    add_rect(sk, FRONT_X1 - 1.0, FRONT_Y1 - 1.0, FRONT_X2 + 1.0, usb_face)
    cut_body(front_comp, largest_profile(sk), Z_FRONT + 1.0, both)
    sk = front_comp.sketches.add(plane_at(front_comp, Z_SPLIT, "plane_usb_wall"))
    sk.name = "USB_wall"
    add_rect(sk, CAV_X1, usb_face, CAV_X2, usb_face + WALL)
    join_body(front_comp, largest_profile(sk), Z_CAVITY, [front])
    sk = back_comp.sketches.add(plane_at(back_comp, Z_PCB, "plane_usb_wall_back"))
    sk.name = "USB_wall_back"
    add_rect(sk, CAV_X1, usb_face, CAV_X2, usb_face + WALL)
    join_body(back_comp, largest_profile(sk), PCB_T, [back])
    sk = front_comp.sketches.add(plane_at(front_comp, Z_SPLIT - 0.5, "plane_usb"))
    sk.name = "USB_port"
    add_rounded_rect(
        sk, USB[0] - 0.5, usb_face - 0.5, USB[2] + 0.5, usb_face + WALL + 0.4, 1.5,
    )
    cut_body(front_comp, largest_profile(sk), 5.3, both)

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

    sk = front_comp.sketches.add(plane_at(front_comp, Z_SPLIT, "plane_sd"))
    sk.name = "SD_slot"
    add_rect(sk, CARD_X1, 36.2, CARD_X2, EAR_Y2 + 0.4)
    cut_body(front_comp, largest_profile(sk), 2.2, both)

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

    sk = hat_comp.sketches.add(plane_at(hat_comp, Z_FRONT, "plane_head"))
    sk.name = "Hat_head"
    add_circle(sk, BTN[0], BTN[1], 5.2)
    join_body(hat_comp, largest_profile(sk), 1.5, [hat])

    paint(design, {
        "PCB": "Plastic - Matte (Green)",
        "XIAO": "Plastic - Matte (Black)",
        "USB_C": "Plastic - Matte (Gray)",
        "SD_socket": "Plastic - Matte (Black)",
        "SD_mouth": "Plastic - Matte (Gray)",
        "Button": "Plastic - Matte (White)",
        "Cap_22uF": "Plastic - Matte (Yellow)",
        "Cell": "Plastic - Matte (Blue)",
        "Back_Shell": "Plastic - Translucent Matte (White)",
        "Front_Shell": "Plastic - Translucent Matte (White)",
        "Button_Hat": "Plastic - Matte (White)",
    })

    # --- files a slicer can open ------------------------------------------
    os.makedirs(PRINT_DIR, exist_ok=True)
    export = design.exportManager
    exported = []
    for body, filename in (
        (back, "carrier_back.stl"),
        (front, "carrier_front.stl"),
        (hat, "carrier_button_hat.stl"),
    ):
        path = os.path.join(PRINT_DIR, filename)
        opts = export.createSTLExportOptions(body, path)
        opts.meshRefinement = adsk.fusion.MeshRefinementSettings.MeshRefinementMedium
        export.execute(opts)
        exported.append(path)

    archive = os.path.join(CAD, "openpendant_carrier_case.f3d")
    opts = export.createFusionArchiveExportOptions(archive, root)
    export.execute(opts)
    exported.append(archive)

    app.activeViewport.fit()
    width = FRONT_X2 - FRONT_X1
    length = EAR_Y2 - FRONT_Y1
    print(
        f"closed {width:.1f} x {length:.1f} x {Z_FRONT:.1f} mm | "
        f"seam z={Z_SPLIT:.1f}"
    )
    for path in exported:
        print("exported", path)
