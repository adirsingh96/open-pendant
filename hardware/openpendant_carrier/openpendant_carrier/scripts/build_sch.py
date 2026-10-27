#!/usr/bin/env python3
"""Draw the carrier schematic.

The nets are the ones already proven on the XIAO nRF52840 Sense:

    D9 CLK, D8 CMD, D7 DAT0, D6 CS, D1 button, 3V3 to the card, VBAT to the cell.

Everything else on the module is left open on purpose. D4 and D5 stay free
because they are the onboard IMU.
"""

from __future__ import annotations

import os
import sys
import uuid

sys.path.insert(0, "/Users/aditidutt/ai_pendent/hardware/openpendant_v1/scripts")
from build_nets import flatten_lib_symbol, label, no_connect, power_symbol, wire  # noqa: E402
from symlib import pins  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCH = os.path.join(ROOT, "openpendant_carrier.kicad_sch")
SEEED = os.path.join(ROOT, "lib", "Seeed_Studio_XIAO_Series.kicad_sym")
SHEET = "9a0e30c9-4dd0-4c54-b74b-cac101aefdff"
STUB = 2.54

# pin number -> net. Missing pins get a no-connect.
U1_NETS = {
    "2": "BTN",
    "7": "SD_CS",
    "8": "SD_DAT0",
    "9": "SD_CMD",
    "10": "SD_CLK",
    "12": "+3V3",
    "13": "GND",
    "18": "GND",
    "19": "VBAT",
    "20": "GND",
}
J1_NETS = {
    "2": "SD_CS",
    "3": "SD_CMD",
    "4": "+3V3",
    "5": "SD_CLK",
    "6": "GND",
    "7": "SD_DAT0",
    "SH": "GND",
}
PARTS = [
    # The Seeed symbol keeps the back pads (SWD, VBAT, NFC) on the same unit
    # as the edge pins, so one instance carries every pad.
    # ref, lib, symbol, x, y, value, footprint, nets, unit, pin numbers
    ("U1", "Seeed_Studio_XIAO_Series", "XIAO-nRF52840-SMD", 139.7, 114.3,
     "XIAO-nRF52840-Sense", "Seeed_XIAO:XIAO-nRF52840-SMD", U1_NETS, 1,
     [str(n) for n in range(1, 23)]),
    ("J1", "Connector", "Micro_SD_Card_Det2", 50.8, 114.3,
     "microSD", "Connector_Card:microSD_HC_Molex_104031-0811", J1_NETS, 1, None),
    ("C1", "Device", "C", 241.3, 101.6,
     "22uF", "Capacitor_SMD:C_0805_2012Metric", {"1": "+3V3", "2": "GND"}, 1, None),
    ("SW1", "Switch", "SW_Push", 241.3, 127.0,
     "SW_Push", "Button_Switch_SMD:SW_SPST_TS-1088-xR020", {"1": "BTN", "2": "GND"}, 1, None),
    ("J2", "Connector", "Conn_01x02_Pin", 241.3, 152.4,
     "BAT", "Battery:BAT_PADS", {"1": "VBAT", "2": "GND"}, 1, None),
]
POWER = {"GND", "+3V3"}


def uid() -> str:
    return str(uuid.uuid4())


def extract(text: str, name: str) -> str:
    token = f'(symbol "{name}"'
    start = text.find(token)
    if start < 0:
        raise KeyError(name)
    line = text.rfind("\n", 0, start) + 1
    depth = 0
    i = start
    while i < len(text):
        c = text[i]
        if c == '"':
            i += 1
            while text[i] != '"' or text[i - 1] == "\\":
                i += 1
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return text[line:i + 1]
        i += 1
    raise RuntimeError(f"unbalanced symbol {name}")


def seeed_symbol() -> str:
    blk = extract(open(SEEED).read(), "XIAO-nRF52840-SMD")
    blk = blk.replace('(symbol "XIAO-nRF52840-SMD"',
                      '(symbol "Seeed_Studio_XIAO_Series:XIAO-nRF52840-SMD"', 1)
    blk = blk.replace("Seeed_Studio_XIAO_Series:XIAO-nRF52840-SMD",
                      "Seeed_XIAO:XIAO-nRF52840-SMD")
    # The replace above also rewrote the lib_id we just set. Put that back.
    blk = blk.replace('(symbol "Seeed_XIAO:XIAO-nRF52840-SMD"',
                      '(symbol "Seeed_Studio_XIAO_Series:XIAO-nRF52840-SMD"', 1)
    blk = blk.replace("\n\t\t(embedded_fonts no)", "")
    return "\t" + blk.replace("\n\t", "\n\t\t") + "\n"


def step(direction: float) -> tuple[float, float]:
    return {0: (1.0, 0.0), 90: (0.0, -1.0), 180: (-1.0, 0.0), 270: (0.0, 1.0)}[direction]


def power_rotation(net: str, stub_dir: float) -> float:
    """Turn the power symbol so its pin faces back toward the part."""
    base = 90 if net == "GND" else 270
    return (stub_dir + 180 - base) % 360


def symbol_block(ref, lib, name, x, y, value, footprint, unit, pin_nums) -> str:
    pins_txt = "".join(
        f'\t\t(pin "{n}"\n\t\t\t(uuid "{uid()}")\n\t\t)\n' for n in pin_nums)
    return (
        f'\t(symbol\n'
        f'\t\t(lib_id "{lib}:{name}")\n'
        f'\t\t(at {x:g} {y:g} 0)\n'
        f'\t\t(unit {unit})\n'
        f'\t\t(body_style 1)\n'
        f'\t\t(exclude_from_sim no)\n'
        f'\t\t(in_bom yes)\n'
        f'\t\t(on_board yes)\n'
        f'\t\t(in_pos_files yes)\n'
        f'\t\t(dnp no)\n'
        f'\t\t(uuid "{uid()}")\n'
        f'\t\t(property "Reference" "{ref}"\n'
        f'\t\t\t(at {x:g} {y - 5.08:g} 0)\n'
        f'\t\t\t(show_name no)\n\t\t\t(do_not_autoplace no)\n'
        f'\t\t\t(effects (font (size 1.27 1.27)))\n\t\t)\n'
        f'\t\t(property "Value" "{value}"\n'
        f'\t\t\t(at {x:g} {y + 5.08:g} 0)\n'
        f'\t\t\t(show_name no)\n\t\t\t(do_not_autoplace no)\n'
        f'\t\t\t(effects (font (size 1.27 1.27)))\n\t\t)\n'
        f'\t\t(property "Footprint" "{footprint}"\n'
        f'\t\t\t(at {x:g} {y:g} 0)\n'
        f'\t\t\t(hide yes)\n\t\t\t(show_name no)\n\t\t\t(do_not_autoplace no)\n'
        f'\t\t\t(effects (font (size 1.27 1.27)))\n\t\t)\n'
        f'\t\t(property "Datasheet" "~"\n'
        f'\t\t\t(at {x:g} {y:g} 0)\n'
        f'\t\t\t(hide yes)\n\t\t\t(show_name no)\n\t\t\t(do_not_autoplace no)\n'
        f'\t\t\t(effects (font (size 1.27 1.27)))\n\t\t)\n'
        f'{pins_txt}'
        f'\t\t(instances\n'
        f'\t\t\t(project "openpendant_carrier"\n'
        f'\t\t\t\t(path "/{SHEET}"\n'
        f'\t\t\t\t\t(reference "{ref}")\n'
        f'\t\t\t\t\t(unit {unit})\n'
        f'\t\t\t\t)\n'
        f'\t\t\t)\n'
        f'\t\t)\n'
        f'\t)\n'
    )


def lib_pins(lib: str, name: str) -> dict:
    if lib == "Seeed_Studio_XIAO_Series":
        # symlib looks in the KiCad system libraries. Read the local copy.
        text = open(SEEED).read()
        import re
        token = f'(symbol "{name}"'
        start = text.find(token)
        end = text.find('\n\t(symbol "', start + 10)
        blk = text[start:end if end > 0 else len(text)]
        out = {}
        pat = re.compile(
            r'\(pin (\w+) \w+\s*\n\s*\(at ([-\d.]+) ([-\d.]+) ([-\d.]+)\)\s*\n\s*'
            r'\(length ([-\d.]+)\)(?:.|\n)*?\(name "([^"]*)"(?:.|\n)*?\(number "([^"]*)"')
        for m in pat.finditer(blk):
            etype, x, y, ang, length, pname, num = m.groups()
            out[num] = {"name": pname, "x": float(x), "y": float(y),
                        "angle": float(ang), "length": float(length), "etype": etype}
        return out
    return pins(lib, name)


def main() -> None:
    libs = ["power:GND", "power:+3V3", "power:PWR_FLAG",
            "Connector:Micro_SD_Card_Det2", "Device:C", "Switch:SW_Push",
            "Connector:Conn_01x02_Pin"]
    lib_txt = seeed_symbol()
    for full in libs:
        lib, name = full.split(":")
        lib_txt += flatten_lib_symbol(lib, name)

    body = []
    pwr_n = 0
    flag_points = []  # (net, x, y) where a flag can land on an existing stub
    for ref, lib, name, x, y, value, fp, nets, unit, pin_nums in PARTS:
        allpins = lib_pins(lib, name)
        use = pin_nums if pin_nums is not None else list(allpins)
        unknown = set(nets) - set(allpins)
        if unknown:
            raise SystemExit(f"{ref}: no such pins {sorted(unknown)}")
        body.append(symbol_block(ref, lib, name, x, y, value, fp, unit, use))
        sym = {"lib_id": f"{lib}:{name}", "x": x, "y": y, "rot": 0, "mirror": None}
        for num in use:
            pin = allpins[num]
            px = x + pin["x"]
            py = y - pin["y"]
            out_dir = (pin["angle"] + 180) % 360
            net = nets.get(num)
            if net is None:
                body.append(no_connect(px, py))
                continue
            dx, dy = step(out_dir)
            ex, ey = px + dx * STUB, py + dy * STUB
            body.append(wire(px, py, ex, ey))
            if net in POWER:
                pwr_n += 1
                body.append(power_symbol(f"power:{net}", net, ex, ey,
                                          f"#PWR{pwr_n:03d}",
                                          power_rotation(net, out_dir))
                            .replace("openpendant_v1", "openpendant_carrier")
                            .replace("{PATH}", f"/{SHEET}"))
                if ref == "C1":
                    flag_points.append((net, ex, ey, dx, dy))
            else:
                body.append(label("label", net, ex, ey, out_dir))

    for net, ex, ey, dx, dy in flag_points:
        fx, fy = ex + dx * STUB, ey + dy * STUB
        body.append(wire(ex, ey, fx, fy))
        pwr_n += 1
        body.append(power_symbol("power:PWR_FLAG", "PWR_FLAG", fx, fy,
                                  f"#FLG{pwr_n:03d}", 0)
                    .replace("openpendant_v1", "openpendant_carrier")
                    .replace("{PATH}", f"/{SHEET}"))

    note = (
        '\t(text "Carrier for the tested XIAO nRF52840 Sense. '
        'SD uses D9 CLK, D8 CMD, D7 DAT0, D6 CS. Button is D1, active low. '
        'Cell wires land on VBAT and GND. D4 and D5 stay open for the IMU."\n'
        '\t\t(at 25.4 30.48 0)\n'
        '\t\t(effects (font (size 1.27 1.27)))\n'
        f'\t\t(uuid "{uid()}")\n\t)\n'
    )
    text = (
        '(kicad_sch\n'
        '\t(version 20260306)\n'
        '\t(generator "eeschema")\n'
        '\t(generator_version "10.0")\n'
        f'\t(uuid "{SHEET}")\n'
        '\t(paper "A3")\n'
        f'\t(lib_symbols\n{lib_txt}\t)\n'
        f'{"".join(body)}{note}'
        '\t(sheet_instances\n'
        '\t\t(path "/"\n'
        '\t\t\t(page "1")\n'
        '\t\t)\n'
        '\t)\n'
        ')\n'
    )
    open(SCH, "w").write(text)
    print(f"wrote {SCH}")


if __name__ == "__main__":
    main()
