/* global THREE */
/** Millimetres. Same axes as pendant_viewer.js: Y up the pendant, X across, +Z toward you. */

const TODAY = { x: -30 };
const NEXT = { x: 30 };

const COL = {
  xiao: 0x1a1a1a,
  board: 0xc4a574,
  sd: 0x161616,
  lipo: 0xc5c8cc,
  usb: 0xb7b7b7,
  gold: 0xc6a15b,
  mic: 0x5fbf82,
  led: 0xff4d00,
  btn: 0x222222,
  cap: 0xd8c7a2,
  coin: 0xb08d3e,
  slot: 0x0a0a0a,
};

const parts = [];
let explode = 0.35;
let showLabels = true;
let scene, camera, renderer, controls, root;
let todayGroup, nextGroup, coinGroup;

function mat(color, extra) {
  return new THREE.MeshStandardMaterial({
    color,
    metalness: 0.15,
    roughness: 0.55,
    ...extra,
  });
}

function box(w, h, t, color, extra) {
  const mesh = new THREE.Mesh(new THREE.BoxGeometry(w, h, t), mat(color, extra));
  mesh.castShadow = true;
  mesh.receiveShadow = true;
  return mesh;
}

function labelSprite(text) {
  const c = document.createElement("canvas");
  c.width = 512;
  c.height = 128;
  const g = c.getContext("2d");
  g.clearRect(0, 0, c.width, c.height);
  g.fillStyle = "rgba(12,11,10,0.88)";
  g.fillRect(8, 28, 496, 72);
  g.strokeStyle = "#ff4d00";
  g.lineWidth = 3;
  g.strokeRect(8, 28, 496, 72);
  g.fillStyle = "#f4eee6";
  g.font = "600 36px ui-sans-serif, system-ui, sans-serif";
  g.textAlign = "center";
  g.textBaseline = "middle";
  g.fillText(text, 256, 64);
  const tex = new THREE.CanvasTexture(c);
  if (THREE.SRGBColorSpace) tex.colorSpace = THREE.SRGBColorSpace;
  const sprite = new THREE.Sprite(
    new THREE.SpriteMaterial({ map: tex, depthTest: false, transparent: true }),
  );
  sprite.scale.set(11, 2.8, 1);
  sprite.renderOrder = 10;
  return sprite;
}

function addPart(parent, name, object, x, y, z, explodeDir, labelAt, short) {
  const wrap = new THREE.Group();
  wrap.position.set(x, y, z);
  wrap.add(object);
  wrap.userData = {
    name,
    home: new THREE.Vector3(x, y, z),
    explodeDir: explodeDir.clone(),
  };
  const lab = labelSprite(short || name);
  lab.position.copy(labelAt);
  wrap.add(lab);
  wrap.userData.label = lab;
  parent.add(wrap);
  parts.push(wrap);
  return wrap;
}

function xiaoBody(parent, cx, cy, zFace) {
  const g = new THREE.Group();
  const body = box(17.5, 21, 3.5, COL.xiao);
  g.add(body);
  const usb = box(9.2, 3.4, 2.6, COL.usb, { metalness: 0.7, roughness: 0.3 });
  usb.position.set(0, -10.2, 0.2);
  g.add(usb);
  const mic = new THREE.Mesh(
    new THREE.CylinderGeometry(0.7, 0.7, 0.25, 16),
    mat(COL.mic),
  );
  mic.rotation.x = Math.PI / 2;
  mic.position.set(0, 6.2, 1.85);
  g.add(mic);
  const led = new THREE.Mesh(
    new THREE.BoxGeometry(1.6, 0.7, 0.2),
    mat(COL.led, { emissive: 0xff4d00, emissiveIntensity: 0.4 }),
  );
  led.position.set(4.2, -6.4, 1.8);
  g.add(led);
  for (const side of [-1, 1]) {
    for (let i = 0; i < 7; i += 1) {
      const pad = box(0.7, 1.3, 0.35, COL.gold, { metalness: 0.8, roughness: 0.25 });
      pad.position.set(side * 8.5, -8 + i * 2.5, -1.5);
      g.add(pad);
    }
  }
  addPart(
    parent,
    "XIAO nRF52840 Sense  17.5 × 21 × 3.5 mm",
    g,
    cx,
    cy,
    zFace + 1.75,
    new THREE.Vector3(0, 0, 1),
    new THREE.Vector3(0, 12, 4),
    "XIAO",
  );
}

function buildToday(parent) {
  const boardT = 1.6;
  const boardH = 45.7;
  const boardW = 20.3;
  addPart(
    parent,
    "Perfboard  20 × 46 × 1.6 mm",
    box(boardW, boardH, boardT, COL.board),
    0,
    boardH / 2,
    0,
    new THREE.Vector3(0, 0, 0),
    new THREE.Vector3(-14, 6, 4),
    "Strip",
  );
  xiaoBody(parent, 0, 10.5, boardT / 2);
  const sd = new THREE.Group();
  sd.add(box(18, 20, 3, COL.sd));
  const mouth = box(14, 1.2, 0.6, COL.slot);
  mouth.position.set(0, 9.2, 0.8);
  sd.add(mouth);
  addPart(
    parent,
    "SD breakout  18 × 20 × 3 mm",
    sd,
    0,
    21 + 11,
    boardT / 2 + 1.5,
    new THREE.Vector3(0, 0, 1),
    new THREE.Vector3(-14, 0, 4),
    "SD module",
  );
  const btn = new THREE.Group();
  const cap = new THREE.Mesh(new THREE.CylinderGeometry(3, 3, 5, 20), mat(COL.btn));
  cap.rotation.x = Math.PI / 2;
  btn.add(cap);
  const plunger = new THREE.Mesh(new THREE.CylinderGeometry(1.5, 1.5, 1.8, 16), mat(0x444444));
  plunger.rotation.x = Math.PI / 2;
  plunger.position.z = 3.2;
  btn.add(plunger);
  addPart(
    parent,
    "Button  Ø6 × 5 mm",
    btn,
    0,
    42.5,
    boardT / 2 + 2.5,
    new THREE.Vector3(0, 0, 1),
    new THREE.Vector3(0, 6, 4),
    "Button",
  );
  addPart(
    parent,
    "Cell  30 × 20 × 6 mm",
    box(20, 30, 6, COL.lipo, { metalness: 0.35, roughness: 0.4 }),
    0,
    16,
    -(boardT / 2 + 3),
    new THREE.Vector3(0, 0, -1),
    new THREE.Vector3(-16, 4, -2),
    "Cell",
  );
}

function buildCarrier(parent) {
  const boardT = 1.6;
  const boardH = 38;
  const boardW = 23;
  addPart(
    parent,
    "Carrier PCB  23 × 38 × 1.6 mm",
    box(boardW, boardH, boardT, COL.board),
    0,
    boardH / 2,
    0,
    new THREE.Vector3(0, 0, 0),
    new THREE.Vector3(16, -6, 4),
    "Carrier",
  );
  xiaoBody(parent, 0, 10.5, boardT / 2);

  const socket = new THREE.Group();
  socket.add(box(13.2, 14.2, 1.42, COL.sd, { metalness: 0.25, roughness: 0.45 }));
  const mouth = box(11.4, 0.8, 0.45, COL.slot);
  mouth.position.set(0, 6.6, 0.35);
  socket.add(mouth);
  const card = box(11, 4, 0.7, 0x2a2a2a);
  card.position.set(0, 8.6, 0);
  socket.add(card);
  addPart(
    parent,
    "microSD socket  13 × 14 × 1.4 mm",
    socket,
    -3.7,
    31.4,
    boardT / 2 + 0.71,
    new THREE.Vector3(0, 0, 1),
    new THREE.Vector3(0, 10, 5),
    "SD socket",
  );

  const btn = new THREE.Group();
  btn.add(box(4.0, 3.0, 1.6, COL.btn));
  const nub = new THREE.Mesh(new THREE.CylinderGeometry(1.1, 1.1, 0.6, 16), mat(0x3a3a3a));
  nub.rotation.x = Math.PI / 2;
  nub.position.z = 1.0;
  btn.add(nub);
  addPart(
    parent,
    "Button  4 × 3 × 2 mm",
    btn,
    7.7,
    30.2,
    boardT / 2 + 0.8,
    new THREE.Vector3(0, 0, 1),
    new THREE.Vector3(8, 3, 3),
    "Button",
  );

  addPart(
    parent,
    "22 µF  3.2 × 1.6 mm",
    box(1.6, 3.2, 1.2, COL.cap),
    -2.5,
    22.9,
    boardT / 2 + 0.6,
    new THREE.Vector3(0, 0, 1),
    new THREE.Vector3(8, 0, 3),
    "22 µF",
  );

  const cell = new THREE.Group();
  cell.add(box(20, 30, 6, COL.lipo, { metalness: 0.35, roughness: 0.4 }));
  const seam = box(16, 0.4, 0.15, 0x8d9094);
  seam.position.set(0, 12, 3.05);
  cell.add(seam);
  addPart(
    parent,
    "Cell  30 × 20 × 6 mm",
    cell,
    0,
    16,
    -(boardT / 2 + 3),
    new THREE.Vector3(0, 0, -1),
    new THREE.Vector3(16, 0, -2),
    "Cell",
  );
}

function buildCoin(parent) {
  const coin = new THREE.Mesh(
    new THREE.CylinderGeometry(11.5, 11.5, 1.6, 48),
    mat(COL.coin, { metalness: 0.65, roughness: 0.35 }),
  );
  coin.rotation.x = Math.PI / 2;
  const g = new THREE.Group();
  g.add(coin);
  addPart(
    parent,
    "₹5 coin  23 mm across",
    g,
    0,
    11.5,
    0,
    new THREE.Vector3(0, 0, 0),
    new THREE.Vector3(0, 14, 3),
    "₹5 coin",
  );
}

function applyExplode() {
  const travel = explode * 10;
  for (const wrap of parts) {
    const { home, explodeDir, label } = wrap.userData;
    wrap.position.copy(home).addScaledVector(explodeDir, travel);
    if (label) label.visible = showLabels;
  }
}

function attachOrbit(cam, canvas) {
  const target = new THREE.Vector3(0, 20, 0);
  const spherical = new THREE.Spherical().setFromVector3(cam.position.clone().sub(target));
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
    spherical.phi = Math.min(Math.max(0.15, spherical.phi - dy * 0.008), Math.PI - 0.15);
    cam.position.setFromSpherical(spherical).add(target);
    cam.lookAt(target);
  });
  canvas.addEventListener(
    "wheel",
    (e) => {
      e.preventDefault();
      spherical.radius = Math.min(180, Math.max(24, spherical.radius * (e.deltaY > 0 ? 1.08 : 0.92)));
      cam.position.setFromSpherical(spherical).add(target);
      cam.lookAt(target);
    },
    { passive: false },
  );
  cam.lookAt(target);
  return {
    target,
    spherical,
    look() {
      cam.position.setFromSpherical(spherical).add(target);
      cam.lookAt(target);
    },
  };
}

function focus(which) {
  todayGroup.visible = which !== "next";
  nextGroup.visible = which !== "today";
  coinGroup.visible = which !== "today";
  if (which === "today") controls.target.set(TODAY.x, 22, 0);
  else if (which === "next") controls.target.set(NEXT.x, 18, 0);
  else controls.target.set(0, 20, 0);
  controls.spherical.setFromVector3(camera.position.clone().sub(controls.target));
  controls.look();
}

function init() {
  const canvas = document.querySelector("#cad");
  const wrap = document.querySelector("#viewer-stage");
  const hint = document.querySelector("#pick-hint");
  if (!canvas || !wrap) return;
  if (typeof THREE === "undefined") {
    if (hint) hint.textContent = "Three.js did not load. Open this file from the docs folder.";
    return;
  }

  scene = new THREE.Scene();
  scene.background = new THREE.Color(0x141210);
  camera = new THREE.PerspectiveCamera(38, 1, 0.1, 500);
  camera.position.set(62, 34, 78);
  renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.setClearColor(0x141210, 1);
  if ("outputColorSpace" in renderer && THREE.SRGBColorSpace) {
    renderer.outputColorSpace = THREE.SRGBColorSpace;
  }

  function resize() {
    const w = Math.max(wrap.clientWidth, 320);
    const h = Math.max(wrap.clientHeight, 320);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
    renderer.setSize(w, h, false);
  }
  resize();

  scene.add(new THREE.AmbientLight(0xffffff, 0.9));
  const sun = new THREE.DirectionalLight(0xffe6d4, 1.15);
  sun.position.set(40, 70, 50);
  scene.add(sun);
  const fill = new THREE.DirectionalLight(0x9eb4c8, 0.35);
  fill.position.set(-50, 20, -30);
  scene.add(fill);

  const grid = new THREE.GridHelper(160, 32, 0x3a342c, 0x241f1b);
  grid.position.y = 0;
  scene.add(grid);

  const scale = box(10, 0.4, 0.4, 0xffb08a);
  scale.position.set(-70, 0.3, 0);
  scene.add(scale);
  const scaleLabel = labelSprite("10 mm");
  scaleLabel.position.set(-70, 3.2, 0);
  scene.add(scaleLabel);

  root = new THREE.Group();
  scene.add(root);

  todayGroup = new THREE.Group();
  todayGroup.position.x = TODAY.x;
  buildToday(todayGroup);
  root.add(todayGroup);

  nextGroup = new THREE.Group();
  nextGroup.position.x = NEXT.x;
  buildCarrier(nextGroup);
  root.add(nextGroup);

  coinGroup = new THREE.Group();
  coinGroup.position.set(0, 0, 0);
  buildCoin(coinGroup);
  root.add(coinGroup);

  controls = attachOrbit(camera, canvas);
  applyExplode();

  new ResizeObserver(() => resize()).observe(wrap);
  window.addEventListener("resize", resize);

  const exp = document.querySelector("#explode");
  exp.addEventListener("input", () => {
    explode = Number(exp.value);
    applyExplode();
  });
  document.querySelectorAll("[data-view]").forEach((btn) => {
    btn.addEventListener("click", () => focus(btn.dataset.view));
  });
  document.querySelector("#labels").addEventListener("change", (e) => {
    showLabels = e.target.checked;
    applyExplode();
  });

  const ray = new THREE.Raycaster();
  const ptr = new THREE.Vector2();
  canvas.addEventListener("pointerdown", (ev) => {
    const r = canvas.getBoundingClientRect();
    ptr.x = ((ev.clientX - r.left) / r.width) * 2 - 1;
    ptr.y = -((ev.clientY - r.top) / r.height) * 2 + 1;
    ray.setFromCamera(ptr, camera);
    const hits = ray.intersectObjects(parts, true);
    if (!hits.length || !hint) return;
    let obj = hits[0].object;
    while (obj && !obj.userData?.name) obj = obj.parent;
    if (obj?.userData?.name) hint.textContent = obj.userData.name;
  });

  function tick() {
    renderer.render(scene, camera);
    requestAnimationFrame(tick);
  }
  tick();
}

init();
