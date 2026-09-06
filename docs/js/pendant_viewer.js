/* global THREE */
/** Millimetres. Matches docs/cad/generate_case.py */
const INNER_W = 23;
const INNER_H = 48;
const WALL = 1.6;
const INNER_D_BACK = 8.0;
const INNER_D_FRONT = 7.0;
const OUTER_W = INNER_W + 2 * WALL;
const OUTER_H = INNER_H + 2 * WALL;
const USB_W = 12;
const USB_H = 5.4;
const BAIL_H = 8;
const BAIL_T = 3;
const BAIL_W = 16;
const MIC_Y = 17;
const LED_Y = 7;
const BTN_Y = 44.5;
const BTN_HOLE_R = 3.3;

const HOLE = 2.54;
const COLS = 8;
const ROWS = 18;
const BOARD = { w: COLS * HOLE, h: ROWS * HOLE, t: 1.6 };
const ISLAND_W = 20.8;
const ISLAND_H = 46.2;

const XIAO = { w: 17.5, h: 21, t: 3.5 };
const SD = { w: 18, h: 20, t: 3 };
const LIPO = { w: 20, h: 30, t: 6 };
const BTN = { bodyR: 3.0, bodyH: 5.0, plungerR: 1.6, plungerH: 1.8, pinPitch: 5.08 };
const CAP = { d: 5.0, h: 3.5 };

const COL = {
  xiao: 0x1a1a1a,
  board: 0xc4a574,
  sd: 0x111111,
  lipo: 0xc5c8cc,
  tape: 0xe8c44a,
  case: 0x2a241c,
  usb: 0x888888,
  mic: 0x5fbf82,
};

const parts = [];
let explode = 0.65;
let caseMode = "ghost";
let showLabels = true;
let scene, camera, renderer, controls, root, labelGroup;

function mat(color, extra = {}) {
  return new THREE.MeshStandardMaterial({
    color,
    metalness: 0.12,
    roughness: 0.55,
    ...extra,
  });
}

function boxMesh(w, h, t, color, extra) {
  const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, t), mat(color, extra));
  m.castShadow = true;
  m.receiveShadow = true;
  return m;
}

function labelSprite(text) {
  const c = document.createElement("canvas");
  c.width = 512;
  c.height = 128;
  const g = c.getContext("2d");
  g.clearRect(0, 0, c.width, c.height);
  g.fillStyle = "rgba(12,11,10,0.82)";
  if (typeof g.roundRect === "function") g.roundRect(8, 24, 496, 80, 16);
  else g.fillRect(8, 24, 496, 80);
  g.fill();
  g.strokeStyle = "#ff4d00";
  g.lineWidth = 3;
  g.stroke();
  g.fillStyle = "#f4eee6";
  g.font = "600 42px ui-sans-serif, system-ui, sans-serif";
  g.textAlign = "center";
  g.textBaseline = "middle";
  g.fillText(text, 256, 64);
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  const s = new THREE.Sprite(
    new THREE.SpriteMaterial({ map: tex, depthTest: false, transparent: true }),
  );
  s.scale.set(14, 3.5, 1);
  s.renderOrder = 10;
  return s;
}

function addPart(name, object, rest, explodeDir, labelPos) {
  const wrap = new THREE.Group();
  wrap.add(object);
  wrap.userData = { name, rest: rest.clone(), explodeDir: explodeDir.clone() };
  const lab = labelSprite(name);
  lab.position.copy(labelPos);
  wrap.add(lab);
  wrap.userData.label = lab;
  root.add(wrap);
  parts.push(wrap);
  return wrap;
}

function roundedRectShape(x, y, w, h, r) {
  const s = new THREE.Shape();
  s.moveTo(x + r, y);
  s.lineTo(x + w - r, y);
  s.quadraticCurveTo(x + w, y, x + w, y + r);
  s.lineTo(x + w, y + h - r);
  s.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
  s.lineTo(x + r, y + h);
  s.quadraticCurveTo(x, y + h, x, y + h - r);
  s.lineTo(x, y + r);
  s.quadraticCurveTo(x, y, x + r, y);
  return s;
}

function hole(cx, cy, r) {
  const p = new THREE.Path();
  p.absarc(cx, cy, r, 0, Math.PI * 2, true);
  return p;
}

function makeFrontLid() {
  const g = new THREE.Group();
  const face = roundedRectShape(-OUTER_W / 2, 0, OUTER_W, OUTER_H, 2.2);
  const iy0 = WALL;
  face.holes.push(hole(0, iy0 + MIC_Y, 1.5));
  face.holes.push(hole(0, iy0 + LED_Y, 1.2));
  face.holes.push(hole(1.27, iy0 + BTN_Y, BTN_HOLE_R));
  const plate = new THREE.Mesh(
    new THREE.ExtrudeGeometry(face, { depth: WALL, bevelEnabled: false }),
    mat(COL.case),
  );
  plate.position.z = INNER_D_FRONT;
  g.add(plate);

  const sideMat = mat(COL.case);
  const top = boxMesh(OUTER_W, WALL, INNER_D_FRONT, COL.case);
  top.position.set(0, OUTER_H - WALL / 2, INNER_D_FRONT / 2);
  g.add(top);
  const left = boxMesh(WALL, INNER_H, INNER_D_FRONT, COL.case);
  left.position.set(-OUTER_W / 2 + WALL / 2, WALL + INNER_H / 2, INNER_D_FRONT / 2);
  g.add(left);
  const right = boxMesh(WALL, INNER_H, INNER_D_FRONT, COL.case);
  right.position.set(OUTER_W / 2 - WALL / 2, WALL + INNER_H / 2, INNER_D_FRONT / 2);
  g.add(right);
  const bw = (OUTER_W - USB_W) / 2;
  const bl = boxMesh(bw, WALL, INNER_D_FRONT, COL.case);
  bl.position.set(-OUTER_W / 2 + bw / 2, WALL / 2, INNER_D_FRONT / 2);
  g.add(bl);
  const br = boxMesh(bw, WALL, INNER_D_FRONT, COL.case);
  br.position.set(OUTER_W / 2 - bw / 2, WALL / 2, INNER_D_FRONT / 2);
  g.add(br);
  const usbSill = boxMesh(USB_W, WALL, Math.max(0.2, INNER_D_FRONT - USB_H));
  usbSill.material = sideMat;
  usbSill.position.set(0, WALL / 2, USB_H + (INNER_D_FRONT - USB_H) / 2);
  if (INNER_D_FRONT > USB_H) g.add(usbSill);
  const rail = (INNER_W - ISLAND_W) / 2;
  const islandTop = WALL + ISLAND_H;
  const xRailL = boxMesh(rail, ISLAND_H, 3.4, COL.case);
  xRailL.position.set(-INNER_W / 2 + rail / 2, WALL + ISLAND_H / 2, 1.7);
  const xRailR = boxMesh(rail, ISLAND_H, 3.4, COL.case);
  xRailR.position.set(INNER_W / 2 - rail / 2, WALL + ISLAND_H / 2, 1.7);
  const topStop = boxMesh(ISLAND_W, 1.4, 3.4, COL.case);
  topStop.position.set(0, islandTop + 0.7, 1.7);
  g.add(xRailL, xRailR, topStop);
  return g;
}

function makeBackShell() {
  const g = new THREE.Group();
  const floor = roundedRectShape(-OUTER_W / 2, 0, OUTER_W, OUTER_H + BAIL_H, 2.2);
  const plate = new THREE.Mesh(
    new THREE.ExtrudeGeometry(floor, { depth: WALL, bevelEnabled: false }),
    mat(COL.case),
  );
  plate.position.z = -INNER_D_BACK - WALL;
  g.add(plate);

  const top = boxMesh(OUTER_W, WALL, INNER_D_BACK, COL.case);
  top.position.set(0, OUTER_H - WALL / 2, -INNER_D_BACK / 2);
  g.add(top);
  const left = boxMesh(WALL, INNER_H, INNER_D_BACK, COL.case);
  left.position.set(-OUTER_W / 2 + WALL / 2, WALL + INNER_H / 2, -INNER_D_BACK / 2);
  g.add(left);
  const right = boxMesh(WALL, INNER_H, INNER_D_BACK, COL.case);
  right.position.set(OUTER_W / 2 - WALL / 2, WALL + INNER_H / 2, -INNER_D_BACK / 2);
  g.add(right);
  const bw = (OUTER_W - USB_W) / 2;
  const bl = boxMesh(bw, WALL, INNER_D_BACK, COL.case);
  bl.position.set(-OUTER_W / 2 + bw / 2, WALL / 2, -INNER_D_BACK / 2);
  g.add(bl);
  const br = boxMesh(bw, WALL, INNER_D_BACK, COL.case);
  br.position.set(OUTER_W / 2 - bw / 2, WALL / 2, -INNER_D_BACK / 2);
  g.add(br);
  const sillH = INNER_D_BACK - USB_H;
  if (sillH > 0.2) {
    const sill = boxMesh(USB_W, WALL, sillH, COL.case);
    sill.position.set(0, WALL / 2, -USB_H - sillH / 2);
    g.add(sill);
  }
  const postL = boxMesh(BAIL_T, BAIL_H, BAIL_T, COL.case);
  postL.position.set(-BAIL_W / 2 + BAIL_T / 2, OUTER_H + BAIL_H / 2, -INNER_D_BACK - WALL + BAIL_T / 2);
  g.add(postL);
  const postR = boxMesh(BAIL_T, BAIL_H, BAIL_T, COL.case);
  postR.position.set(BAIL_W / 2 - BAIL_T / 2, OUTER_H + BAIL_H / 2, -INNER_D_BACK - WALL + BAIL_T / 2);
  g.add(postR);
  const bar = boxMesh(BAIL_W, BAIL_T, BAIL_T, COL.case);
  bar.position.set(0, OUTER_H + BAIL_H - BAIL_T / 2, -INNER_D_BACK - WALL + BAIL_T / 2);
  g.add(bar);
  const railL = boxMesh(1.2, 24, 3, COL.case);
  railL.position.set(-INNER_W / 2 + 0.6, WALL + 16, -1.5);
  const railR = boxMesh(1.2, 24, 3, COL.case);
  railR.position.set(INNER_W / 2 - 0.6, WALL + 16, -1.5);
  g.add(railL, railR);
  return g;
}

function holeXY(col, row) {
  const x = -BOARD.w / 2 + HOLE / 2 + (col - 1) * HOLE;
  const y = BOARD.h / 2 - HOLE / 2 - (row - 1) * HOLE;
  return { x, y };
}

function addBox(g, w, h, t, x, y, z, color) {
  const m = boxMesh(w, h, t, color);
  m.position.set(x, y, z);
  g.add(m);
  return m;
}

function makeIsland() {
  const g = new THREE.Group();
  const t = BOARD.t;
  const w = BOARD.w;
  const h = BOARD.h;
  const wx0 = holeXY(6, 16).x - 1.1;
  const wx1 = w / 2 - 1.6;
  const wy0 = holeXY(1, 16).y - 1.2;
  const wy1 = holeXY(1, 15).y + 1.2;
  addBox(g, wx0 - -w / 2, h, t, (-w / 2 + wx0) / 2, 0, 0, COL.board);
  addBox(g, w / 2 - wx1, h, t, (w / 2 + wx1) / 2, 0, 0, COL.board);
  addBox(g, wx1 - wx0, wy0 - -h / 2, t, (wx0 + wx1) / 2, (-h / 2 + wy0) / 2, 0, COL.board);
  addBox(g, wx1 - wx0, h / 2 - wy1, t, (wx0 + wx1) / 2, (h / 2 + wy1) / 2, 0, COL.board);
  addBox(g, wx1 - wx0, wy1 - wy0, 0.18, (wx0 + wx1) / 2, (wy0 + wy1) / 2, t / 2 + 0.04, 0x3a2a14);

  const holeMat = mat(0x2a241c);
  for (let col = 1; col <= COLS; col += 1) {
    for (let row = 1; row <= ROWS; row += 1) {
      if (col >= 6 && col <= 7 && row >= 15 && row <= 16) continue;
      const { x, y } = holeXY(col, row);
      const cyl = new THREE.Mesh(new THREE.CylinderGeometry(0.45, 0.45, t + 0.12, 10), holeMat);
      cyl.rotation.x = Math.PI / 2;
      cyl.position.set(x, y, 0);
      g.add(cyl);
    }
  }

  const zBus = t / 2 + 0.22;
  const gnd = [1, 11, 17].map((row) => holeXY(1, row));
  for (let i = 0; i < gnd.length - 1; i += 1) {
    g.add(
      wireSeg(
        new THREE.Vector3(gnd[i].x, gnd[i].y, zBus),
        new THREE.Vector3(gnd[i + 1].x, gnd[i + 1].y, zBus),
        0.22,
        0x888888,
      ),
    );
  }
  g.add(
    wireSeg(
      new THREE.Vector3(holeXY(1, 11).x, holeXY(1, 11).y, zBus),
      new THREE.Vector3(holeXY(2, 11).x, holeXY(2, 11).y, zBus),
      0.22,
      0x888888,
    ),
  );
  g.add(
    wireSeg(
      new THREE.Vector3(holeXY(1, 1).x, holeXY(1, 1).y, zBus),
      new THREE.Vector3(holeXY(6, 1).x, holeXY(6, 1).y, zBus),
      0.22,
      0x888888,
    ),
  );
  g.add(
    wireSeg(
      new THREE.Vector3(holeXY(1, 16).x, holeXY(1, 16).y, zBus),
      new THREE.Vector3(holeXY(1, 11).x, holeXY(1, 11).y, zBus),
      0.22,
      0xff4d00,
    ),
  );
  g.add(
    wireSeg(
      new THREE.Vector3(holeXY(8, 17).x, holeXY(8, 17).y, zBus),
      new THREE.Vector3(holeXY(4, 1).x, holeXY(4, 1).y, zBus),
      0.22,
      0x9b5cff,
    ),
  );
  return g;
}

function makeCap() {
  const g = new THREE.Group();
  const body = new THREE.Mesh(
    new THREE.CylinderGeometry(CAP.d / 2, CAP.d / 2, CAP.h, 20),
    mat(0xd4d8dc, { metalness: 0.35, roughness: 0.4 }),
  );
  body.rotation.z = Math.PI / 2;
  g.add(body);
  const stripe = new THREE.Mesh(
    new THREE.CylinderGeometry(CAP.d / 2 + 0.05, CAP.d / 2 + 0.05, 0.7, 20),
    mat(0x444444),
  );
  stripe.rotation.z = Math.PI / 2;
  stripe.position.x = 1.15;
  g.add(stripe);
  return g;
}

function makeXiao() {
  const g = new THREE.Group();
  const body = boxMesh(XIAO.w, XIAO.h, XIAO.t, COL.xiao);
  g.add(body);
  const usb = boxMesh(8.9, 7.2, 3.2, COL.usb);
  usb.position.set(0, -XIAO.h / 2 - 0.4, 0.2);
  g.add(usb);
  const mic = new THREE.Mesh(new THREE.CircleGeometry(1.2, 24), mat(COL.mic));
  mic.position.set(0, 6.5, XIAO.t / 2 + 0.02);
  g.add(mic);
  const gold = mat(0xd4a017, { metalness: 0.8, roughness: 0.25 });
  const padZ = -XIAO.t / 2 - 0.12;
  // Seeed bottom silkscreen: BAT between D2 and D3 on the D0–D6 edge.
  // Component face, USB at −Y: that edge is +X (right). D10/5V is −X (left).
  const batX = XIAO.w / 2 - 2.1;
  const plus = new THREE.Mesh(new THREE.BoxGeometry(1.8, 1.6, 0.25), gold);
  plus.position.set(batX, -0.2, padZ);
  const minus = new THREE.Mesh(new THREE.BoxGeometry(1.8, 1.6, 0.25), gold);
  minus.position.set(batX, -2.9, padZ);
  g.add(plus, minus);
  const tp = mat(0x5a6570, { metalness: 0.4, roughness: 0.45 });
  const swd = [
    [-1.2, -XIAO.h / 2 + 3.2],
    [1.2, -XIAO.h / 2 + 3.2],
    [-1.2, -XIAO.h / 2 + 5.4],
    [1.2, -XIAO.h / 2 + 5.4],
  ];
  for (const [sx, sy] of swd) {
    const d = new THREE.Mesh(new THREE.CylinderGeometry(0.55, 0.55, 0.2, 12), tp);
    d.rotation.x = Math.PI / 2;
    d.position.set(sx, sy, padZ);
    g.add(d);
  }
  const sidePad = mat(0xc9a227, { metalness: 0.7, roughness: 0.3 });
  for (let i = 0; i < 7; i++) {
    const yy = -XIAO.h / 2 + 2.2 + i * 2.7;
    for (const sx of [-1, 1]) {
      const p = new THREE.Mesh(new THREE.BoxGeometry(1.1, 1.5, 0.2), sidePad);
      p.position.set(sx * (XIAO.w / 2 + 0.05), yy, 0);
      g.add(p);
    }
  }
  return g;
}

function wireSeg(a, b, r, color) {
  const dir = new THREE.Vector3().subVectors(b, a);
  const len = dir.length();
  const m = new THREE.Mesh(new THREE.CylinderGeometry(r, r, len, 8), mat(color));
  m.position.copy(a).add(b).multiplyScalar(0.5);
  m.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), dir.clone().normalize());
  return m;
}

function makeBatLeads() {
  const g = new THREE.Group();
  const red = 0xc0392b;
  const blk = 0x1a1a1a;
  const r = 0.45;
  const padX = XIAO.w / 2 - 2.1;
  const padZ = -XIAO.t / 2;
  const outX = XIAO.w / 2 + 3.5;
  const backZ = padZ - 7;
  g.add(
    wireSeg(new THREE.Vector3(padX, -0.2, padZ), new THREE.Vector3(outX, -0.2, padZ), r, red),
    wireSeg(new THREE.Vector3(outX, -0.2, padZ), new THREE.Vector3(outX, -0.2, backZ), r, red),
    wireSeg(new THREE.Vector3(outX, -0.2, backZ), new THREE.Vector3(outX - 4, -6, backZ - 1), r, red),
    wireSeg(new THREE.Vector3(padX, -2.9, padZ), new THREE.Vector3(outX, -2.9, padZ), r, blk),
    wireSeg(new THREE.Vector3(outX, -2.9, padZ), new THREE.Vector3(outX, -2.9, backZ), r, blk),
    wireSeg(new THREE.Vector3(outX, -2.9, backZ), new THREE.Vector3(outX - 4, -8, backZ - 1), r, blk),
  );
  return g;
}

function makeSd() {
  const g = new THREE.Group();
  const body = boxMesh(SD.w, SD.h, SD.t, COL.sd);
  g.add(body);
  const slot = boxMesh(12, 14, 1.2, 0xc0c4c8);
  slot.position.set(0, 1.2, SD.t / 2 + 0.15);
  g.add(slot);
  const hdr = boxMesh(SD.w - 1, 2.2, 1.0, 0x222222);
  hdr.position.set(0, -SD.h / 2 + 1.2, SD.t / 2 + 0.2);
  g.add(hdr);
  return g;
}

function makeSpiLeads() {
  const g = new THREE.Group();
  const z0 = -BOARD.t / 2;
  const links = [
    [1, 11, 1, 16, 0xff4d00],
    [2, 11, 1, 17, 0x888888],
    [3, 11, 1, 14, 0x3d7ea6],
    [4, 11, 8, 12, 0x9b5cff],
    [5, 11, 1, 13, 0x5fbf82],
    [6, 11, 1, 12, 0xc9a227],
  ];
  links.forEach(([c0, r0, c1, r1, color]) => {
    const a = holeXY(c0, r0);
    const b = holeXY(c1, r1);
    g.add(
      wireSeg(new THREE.Vector3(a.x, a.y, z0), new THREE.Vector3(a.x, a.y, z0 - 1.2), 0.22, color),
      wireSeg(new THREE.Vector3(a.x, a.y, z0 - 1.2), new THREE.Vector3(b.x, b.y, z0 - 1.2), 0.22, color),
      wireSeg(new THREE.Vector3(b.x, b.y, z0 - 1.2), new THREE.Vector3(b.x, b.y, z0), 0.22, color),
    );
  });
  return g;
}

function makeButton() {
  const g = new THREE.Group();
  const body = new THREE.Mesh(
    new THREE.CylinderGeometry(BTN.bodyR, BTN.bodyR, BTN.bodyH, 32),
    mat(0x1a1a1a),
  );
  body.rotation.x = Math.PI / 2;
  g.add(body);
  const plunger = new THREE.Mesh(
    new THREE.CylinderGeometry(BTN.plungerR, BTN.plungerR, BTN.plungerH, 24),
    mat(0x2c2c2c),
  );
  plunger.rotation.x = Math.PI / 2;
  plunger.position.z = BTN.bodyH / 2 + BTN.plungerH / 2;
  g.add(plunger);
  const pinMat = mat(0xb0b4b8, { metalness: 0.7, roughness: 0.25 });
  for (const x of [-BTN.pinPitch / 2, BTN.pinPitch / 2]) {
    const pin = new THREE.Mesh(new THREE.CylinderGeometry(0.35, 0.35, 4, 8), pinMat);
    pin.position.set(x, 0, -BTN.bodyH / 2 - 1.5);
    g.add(pin);
  }
  return g;
}

function buildAssembly() {
  root = new THREE.Group();
  scene.add(root);

  const yUsb = WALL;
  const yIsland = yUsb + BOARD.h / 2;
  const zIsland = 0;
  const zFront = BOARD.t / 2;
  const zXiao = zFront + XIAO.t / 2;
  const zSd = zFront + SD.t / 2;
  const zLipo = -BOARD.t / 2 - 0.5 - LIPO.t / 2;
  const yXiao = yUsb + XIAO.h / 2;
  const ySd = yUsb + XIAO.h + 2.4 + SD.h / 2;
  const btnLocal = holeXY(4, 1);
  const btnLocal2 = holeXY(6, 1);
  const xBtn = (btnLocal.x + btnLocal2.x) / 2;
  const yBtn = yIsland + btnLocal.y;
  const zBtn = zFront + BTN.bodyH / 2;
  const capA = holeXY(1, 11);
  const capB = holeXY(2, 11);

  addPart(
    "Back case",
    makeBackShell(),
    new THREE.Vector3(0, 0, 0),
    new THREE.Vector3(0, 0, -22),
    new THREE.Vector3(-18, 24, -12),
  ).userData.kind = "case";

  const lipo = new THREE.Group();
  const cell = boxMesh(LIPO.w, LIPO.h, LIPO.t, COL.lipo);
  const tape = boxMesh(LIPO.w, 3, LIPO.t + 0.05, COL.tape);
  tape.position.y = -LIPO.h / 2 + 1.5;
  lipo.add(cell, tape);
  addPart(
    "LiPo on back",
    lipo,
    new THREE.Vector3(0, yXiao + 4, zLipo),
    new THREE.Vector3(0, 0, -14),
    new THREE.Vector3(16, 18, -8),
  );

  addPart(
    "8×18 strip",
    makeIsland(),
    new THREE.Vector3(0, yIsland, zIsland),
    new THREE.Vector3(0, 0, 3),
    new THREE.Vector3(-18, 22, 2),
  );

  addPart(
    "microSD (front)",
    makeSd(),
    new THREE.Vector3(0, ySd, zSd),
    new THREE.Vector3(0, 8, 8),
    new THREE.Vector3(16, 34, 8),
  );

  addPart(
    "22 µF on SD 3V3/GND",
    makeCap(),
    new THREE.Vector3(
      (capA.x + capB.x) / 2,
      yIsland + capA.y,
      -BOARD.t / 2 - CAP.h / 2,
    ),
    new THREE.Vector3(-8, 4, -4),
    new THREE.Vector3(-16, 30, -2),
  );

  addPart(
    "XIAO nRF52840",
    makeXiao(),
    new THREE.Vector3(0, yXiao, zXiao),
    new THREE.Vector3(0, 0, 12),
    new THREE.Vector3(-16, 8, 10),
  );

  addPart(
    "BAT+ / BAT− leads",
    makeBatLeads(),
    new THREE.Vector3(0, yXiao, zXiao),
    new THREE.Vector3(-6, -4, -4),
    new THREE.Vector3(16, 4, 6),
  );

  addPart(
    "Underside jumpers",
    makeSpiLeads(),
    new THREE.Vector3(0, yIsland, zIsland),
    new THREE.Vector3(10, 0, -6),
    new THREE.Vector3(18, 20, -4),
  );

  addPart(
    "Button on strip",
    makeButton(),
    new THREE.Vector3(xBtn, yBtn, zBtn),
    new THREE.Vector3(0, 12, 10),
    new THREE.Vector3(14, 46, 10),
  ).userData.kind = "button";

  addPart(
    "Front lid",
    makeFrontLid(),
    new THREE.Vector3(0, 0, 0),
    new THREE.Vector3(0, 0, 26),
    new THREE.Vector3(-18, 44, 12),
  ).userData.kind = "case";
}

function applyExplode() {
  for (const p of parts) {
    const { rest, explodeDir, label, kind } = p.userData;
    p.position.copy(rest).addScaledVector(explodeDir, explode);
    if (label) label.visible = showLabels;
    const isCase = kind === "case";
    p.traverse((ch) => {
      if (!ch.isMesh || !ch.material) return;
      if (isCase) {
        const hide = caseMode === "off";
        ch.visible = !hide;
        ch.material.transparent = caseMode === "ghost";
        ch.material.opacity = caseMode === "ghost" ? 0.28 : 1;
        ch.material.depthWrite = caseMode !== "ghost";
      }
    });
  }
}

function fitCamera() {
  camera.position.set(56, 36, 64);
  if (controls?.target) controls.target.set(0, 26, 0);
  camera.lookAt(0, 26, 0);
}

function showError(msg) {
  const hint = document.querySelector("#pick-hint");
  if (hint) hint.textContent = msg;
  console.error(msg);
}

function attachOrbit(camera, canvas) {
  const target = new THREE.Vector3(0, 26, 0);
  let spherical = new THREE.Spherical().setFromVector3(
    camera.position.clone().sub(target),
  );
  let dragging = false;
  let lastX = 0;
  let lastY = 0;
  canvas.addEventListener("pointerdown", (e) => {
    dragging = true;
    lastX = e.clientX;
    lastY = e.clientY;
    canvas.setPointerCapture(e.pointerId);
  });
  canvas.addEventListener("pointerup", () => {
    dragging = false;
  });
  canvas.addEventListener("pointermove", (e) => {
    if (!dragging) return;
    const dx = e.clientX - lastX;
    const dy = e.clientY - lastY;
    lastX = e.clientX;
    lastY = e.clientY;
    spherical.theta -= dx * 0.008;
    spherical.phi = Math.min(Math.max(0.12, spherical.phi - dy * 0.008), Math.PI - 0.12);
    camera.position.setFromSpherical(spherical).add(target);
    camera.lookAt(target);
  });
  canvas.addEventListener(
    "wheel",
    (e) => {
      e.preventDefault();
      spherical.radius = Math.min(140, Math.max(28, spherical.radius * (e.deltaY > 0 ? 1.08 : 0.92)));
      camera.position.setFromSpherical(spherical).add(target);
      camera.lookAt(target);
    },
    { passive: false },
  );
  camera.lookAt(target);
  return {
    target,
    update() {},
  };
}

function init() {
  const canvas = document.querySelector("#cad");
  const wrap = document.querySelector("#viewer-stage");
  if (!canvas || !wrap) return;
  if (typeof THREE === "undefined") {
    showError("Three.js did not load. Keep vendor/three.min.js next to this page.");
    return;
  }
  try {
  scene = new THREE.Scene();
  scene.background = new THREE.Color(0x141210);
  camera = new THREE.PerspectiveCamera(42, 1, 0.1, 400);
  renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: false });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.setClearColor(0x141210, 1);
  if ("outputColorSpace" in renderer && THREE.SRGBColorSpace) {
    renderer.outputColorSpace = THREE.SRGBColorSpace;
  }

  function resize() {
    const w = Math.max(wrap.clientWidth, 320);
    const h = Math.max(wrap.clientHeight, 280);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
    renderer.setSize(w, h, false);
  }
  resize();

  controls = attachOrbit(camera, canvas);

  scene.add(new THREE.AmbientLight(0xffffff, 0.85));
  const sun = new THREE.DirectionalLight(0xffe6d4, 1.2);
  sun.position.set(30, 50, 40);
  scene.add(sun);
  const fill = new THREE.DirectionalLight(0x88aacc, 0.35);
  fill.position.set(-40, 10, -20);
  scene.add(fill);

  const grid = new THREE.GridHelper(80, 16, 0x3a342c, 0x241f1b);
  grid.position.y = -2;
  scene.add(grid);

  buildAssembly();
  applyExplode();
  fitCamera();
  resize();

  const ro = new ResizeObserver(() => resize());
  ro.observe(wrap);
  window.addEventListener("resize", resize);

  const exp = document.querySelector("#explode");
  exp.value = String(explode);
  exp.addEventListener("input", () => {
    explode = Number(exp.value);
    applyExplode();
  });
  document.querySelectorAll("[data-preset]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const p = btn.dataset.preset;
      if (p === "closed") {
        explode = 0;
        caseMode = "solid";
      } else if (p === "solder") {
        explode = 0.72;
        caseMode = "ghost";
      } else if (p === "case") {
        explode = 0.55;
        caseMode = "solid";
      }
      exp.value = String(explode);
      document.querySelector("#case-mode").value = caseMode;
      applyExplode();
    });
  });
  document.querySelector("#case-mode").addEventListener("change", (e) => {
    caseMode = e.target.value;
    applyExplode();
  });
  document.querySelector("#labels").addEventListener("change", (e) => {
    showLabels = e.target.checked;
    applyExplode();
  });

  const hint = document.querySelector("#pick-hint");
  const ray = new THREE.Raycaster();
  const ptr = new THREE.Vector2();
  canvas.addEventListener("pointerdown", (ev) => {
    const r = canvas.getBoundingClientRect();
    ptr.x = ((ev.clientX - r.left) / r.width) * 2 - 1;
    ptr.y = -((ev.clientY - r.top) / r.height) * 2 + 1;
    ray.setFromCamera(ptr, camera);
    const hits = ray.intersectObjects(parts, true);
    if (!hits.length) return;
    let obj = hits[0].object;
    while (obj && !obj.userData?.name) obj = obj.parent;
    if (obj?.userData?.name) hint.textContent = obj.userData.name;
  });

  function tick() {
    controls.update();
    renderer.render(scene, camera);
    requestAnimationFrame(tick);
  }
  tick();
  } catch (err) {
    showError(String(err && err.message ? err.message : err));
  }
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", init);
} else {
  init();
}
