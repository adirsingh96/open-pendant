/* global THREE */
/**
 * Millimetres. Y runs up the pendant, X across, +Z toward you.
 * These are wear shapes: a rounded case, then a small way to hold the cord.
 * The card still leaves through the top, behind the cord.
 */

const COL = {
  shell: 0xe3dbd0,
  card: 0x1a1a1a,
  cord: 0xd4b06a,
  usb: 0x3a3834,
  slot: 0x141210,
};

const designs = [];
let scene, camera, renderer, controls;

function mat(color, extra) {
  return new THREE.MeshStandardMaterial({
    color,
    metalness: 0.04,
    roughness: 0.62,
    ...extra,
  });
}

const shellMat = mat(COL.shell);
const cordMat = mat(COL.cord, { metalness: 0.74, roughness: 0.24 });

function roundedRect(w, h, r) {
  const s = new THREE.Shape();
  const x = -w / 2;
  const y = -h / 2;
  s.moveTo(x + r, y);
  s.lineTo(x + w - r, y);
  s.absarc(x + w - r, y + r, r, -Math.PI / 2, 0, false);
  s.lineTo(x + w, y + h - r);
  s.absarc(x + w - r, y + h - r, r, 0, Math.PI / 2, false);
  s.lineTo(x + r, y + h);
  s.absarc(x + r, y + h - r, r, Math.PI / 2, Math.PI, false);
  s.lineTo(x, y + r);
  s.absarc(x + r, y + r, r, Math.PI, Math.PI * 1.5, false);
  return s;
}

function labelSprite(text) {
  const c = document.createElement("canvas");
  c.width = 640;
  c.height = 128;
  const g = c.getContext("2d");
  g.fillStyle = "rgba(12,11,10,0.92)";
  g.fillRect(8, 28, 624, 72);
  g.strokeStyle = "#ff4d00";
  g.lineWidth = 4;
  g.strokeRect(8, 28, 624, 72);
  g.fillStyle = "#f4eee6";
  g.font = "600 40px ui-sans-serif, system-ui, sans-serif";
  g.textAlign = "center";
  g.textBaseline = "middle";
  g.fillText(text, 320, 64);
  const tex = new THREE.CanvasTexture(c);
  if (THREE.SRGBColorSpace) tex.colorSpace = THREE.SRGBColorSpace;
  const sprite = new THREE.Sprite(
    new THREE.SpriteMaterial({ map: tex, depthTest: false, transparent: true }),
  );
  sprite.scale.set(18, 3.6, 1);
  sprite.position.set(0, 64, 4);
  sprite.renderOrder = 10;
  return sprite;
}

function cord(points) {
  const curve = new THREE.CatmullRomCurve3(points);
  return new THREE.Mesh(new THREE.TubeGeometry(curve, 56, 0.7, 8, false), cordMat);
}

function shell() {
  const geo = new THREE.ExtrudeGeometry(roundedRect(24, 42, 10), {
    depth: 7,
    bevelEnabled: true,
    bevelThickness: 2.4,
    bevelSize: 2.3,
    bevelSegments: 5,
    curveSegments: 14,
  });
  geo.center();
  const body = new THREE.Mesh(geo, shellMat);
  body.position.set(0, 24, 0);

  const g = new THREE.Group();
  g.add(body);

  const nub = new THREE.Mesh(new THREE.SphereGeometry(2.15, 24, 16), mat(0xf3efe8, { roughness: 0.45 }));
  nub.scale.set(1, 1, 0.55);
  nub.position.set(6.2, 30, 7.1);
  g.add(nub);

  const usb = new THREE.Mesh(new THREE.BoxGeometry(9, 1.5, 2.6), mat(COL.usb, { roughness: 0.4, metalness: 0.2 }));
  usb.position.set(0, 2.2, 3.2);
  g.add(usb);

  const mouth = new THREE.Mesh(new THREE.BoxGeometry(12.2, 1.5, 1.7), mat(COL.slot, { roughness: 0.85 }));
  mouth.position.set(0, 45.6, 0.2);
  g.add(mouth);

  const shade = new THREE.Mesh(
    new THREE.CircleGeometry(16, 40),
    new THREE.MeshBasicMaterial({ color: 0x000000, transparent: true, opacity: 0.28, depthWrite: false }),
  );
  shade.rotation.x = -Math.PI / 2;
  shade.position.y = 0.04;
  g.add(shade);
  return g;
}

function cardMesh() {
  const g = new THREE.Group();
  g.add(new THREE.Mesh(new THREE.BoxGeometry(11, 15, 0.85), mat(COL.card, { metalness: 0.18, roughness: 0.4 })));
  const stripe = new THREE.Mesh(
    new THREE.BoxGeometry(11, 2.2, 0.05),
    mat(COL.cord, { metalness: 0.8, roughness: 0.22 }),
  );
  stripe.position.set(0, -5.5, 0.45);
  g.add(stripe);
  g.userData.homeY = 37.4;
  return g;
}

function lugPost(x, y, z, radius, length) {
  const lug = new THREE.Mesh(new THREE.CapsuleGeometry(radius, length, 8, 16), shellMat);
  lug.position.set(x, y, z);
  return lug;
}

function barCord(x0, x1, y, z) {
  return cord([
    new THREE.Vector3(x0 * 0.45, 63, z),
    new THREE.Vector3(x0, y, z),
    new THREE.Vector3(x0 * 0.45, y, z),
    new THREE.Vector3(0, y, z),
    new THREE.Vector3(x1 * 0.45, y, z),
    new THREE.Vector3(x1, y, z),
    new THREE.Vector3(x1 * 0.45, 63, z),
  ]);
}

function buildStraight(g) {
  for (const x of [-6.2, 6.2]) g.add(lugPost(x, 45.6, 2.4, 1.45, 8));
  g.add(barCord(-6.2, 6.2, 50.2, 2.4));
}

function buildFlared(g) {
  for (const side of [-1, 1]) {
    const lug = lugPost(side * 5.2, 45.6, 2.6, 1.35, 9);
    lug.rotation.z = side * -0.34;
    g.add(lug);
  }
  g.add(barCord(-7.6, 7.6, 51.2, 2.6));
}

function buildPin(g) {
  for (const x of [-5.4, 5.4]) g.add(lugPost(x, 44.8, 3.4, 1.55, 3.6));
  const pin = new THREE.Mesh(new THREE.CylinderGeometry(0.9, 0.9, 8.4, 18), cordMat);
  pin.rotation.z = Math.PI / 2;
  pin.position.set(0, 47.6, 3.4);
  g.add(pin);
  g.add(
    cord([
      new THREE.Vector3(-3.5, 64, 3.4),
      new THREE.Vector3(0, 48.6, 3.4),
      new THREE.Vector3(3.5, 64, 3.4),
    ]),
  );
}

function buildWide(g) {
  for (const x of [-10.6, 10.6]) g.add(lugPost(x, 45.2, 2.2, 1.3, 6.5));
  g.add(barCord(-10.6, 10.6, 49.2, 2.2));
}

function makeDesign(id, title, x, buildTop) {
  const g = new THREE.Group();
  g.position.x = x;
  g.add(shell());
  const card = cardMesh();
  card.position.set(0, card.userData.homeY, 0.3);
  g.add(card);
  buildTop(g);
  g.add(labelSprite(title));
  g.userData = { id, card };
  return g;
}

function setSlide(t) {
  for (const g of designs) {
    const card = g.userData.card;
    card.position.y = card.userData.homeY + t * 12;
  }
}

function focus(id) {
  for (const g of designs) g.visible = id === "all" || g.userData.id === id;
  const shown = designs.filter((g) => g.visible);
  const targetX = shown.reduce((sum, g) => sum + g.position.x, 0) / shown.length;
  controls.target.set(targetX, 28, 2);
  controls.spherical.radius = id === "all" ? 210 : 72;
  controls.spherical.theta = 0.62;
  controls.spherical.phi = 1.12;
  controls.look();
}

function attachOrbit(cam, canvas) {
  const target = new THREE.Vector3(0, 28, 2);
  const spherical = new THREE.Spherical().setFromVector3(cam.position.clone().sub(target));
  let dragging = false;
  let lastX = 0;
  let lastY = 0;
  canvas.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    dragging = true;
    lastX = e.clientX;
    lastY = e.clientY;
    canvas.setPointerCapture(e.pointerId);
  });
  canvas.addEventListener("pointerup", () => {
    dragging = false;
  });
  canvas.addEventListener("pointercancel", () => {
    dragging = false;
  });
  canvas.addEventListener("pointermove", (e) => {
    if (!dragging) return;
    spherical.theta -= (e.clientX - lastX) * 0.007;
    spherical.phi = Math.min(Math.max(0.25, spherical.phi - (e.clientY - lastY) * 0.007), Math.PI - 0.2);
    lastX = e.clientX;
    lastY = e.clientY;
    cam.position.setFromSpherical(spherical).add(target);
    cam.lookAt(target);
  });
  canvas.addEventListener(
    "wheel",
    (e) => {
      e.preventDefault();
      spherical.radius = Math.min(280, Math.max(36, spherical.radius * (e.deltaY > 0 ? 1.08 : 0.92)));
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

function init() {
  const canvas = document.querySelector("#cad");
  const wrap = document.querySelector("#viewer-stage");
  if (!canvas || !wrap || typeof THREE === "undefined") return;

  scene = new THREE.Scene();
  scene.background = new THREE.Color(0x141210);
  camera = new THREE.PerspectiveCamera(42, 1, 0.1, 900);
  camera.position.set(32, 48, 200);
  renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  if ("outputColorSpace" in renderer && THREE.SRGBColorSpace) {
    renderer.outputColorSpace = THREE.SRGBColorSpace;
  }

  function resize() {
    const w = Math.max(wrap.clientWidth, 320);
    const h = Math.max(wrap.clientHeight, 420);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
    renderer.setSize(w, h, false);
  }
  resize();

  scene.add(new THREE.AmbientLight(0xfff6ee, 0.55));
  scene.add(new THREE.HemisphereLight(0xfff3e6, 0x2a2420, 0.45));
  const sun = new THREE.DirectionalLight(0xfff1e4, 1.25);
  sun.position.set(28, 70, 46);
  scene.add(sun);
  const rim = new THREE.DirectionalLight(0xc5d4e2, 0.7);
  rim.position.set(-40, 24, -30);
  scene.add(rim);

  const grid = new THREE.GridHelper(280, 28, 0x3a342c, 0x241f1b);
  scene.add(grid);

  const specs = [
    ["straight", "Straight", -54, buildStraight],
    ["flared", "Flared", -18, buildFlared],
    ["pin", "Low pin", 18, buildPin],
    ["wide", "Wide", 54, buildWide],
  ];
  for (const [id, title, x, buildTop] of specs) {
    const g = makeDesign(id, title, x, buildTop);
    scene.add(g);
    designs.push(g);
  }

  controls = attachOrbit(camera, canvas);
  const slide = document.querySelector("#slide");
  setSlide(slide ? Number(slide.value) : 0.35);

  new ResizeObserver(() => resize()).observe(wrap);
  window.addEventListener("resize", resize);

  document.querySelectorAll("[data-view]").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelectorAll("[data-view]").forEach((el) => el.classList.remove("on"));
      btn.classList.add("on");
      focus(btn.dataset.view);
      const note = document.querySelector("#note");
      if (note && btn.dataset.note) note.textContent = btn.dataset.note;
    });
  });
  if (slide) slide.addEventListener("input", () => setSlide(Number(slide.value)));

  function tick() {
    renderer.render(scene, camera);
    requestAnimationFrame(tick);
  }
  tick();
}

init();
