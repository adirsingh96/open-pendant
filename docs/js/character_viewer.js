/* global THREE */
/**
 * The flared-lug case, drawn as a character.
 * The ears are the cord lugs. The face sits on the front of the same case.
 * Millimetres. Y up, X across, +Z toward you.
 */

const SHELL = 0xf1e6d8;
const INK = 0x2c241f;

let scene, camera, renderer, controls;
let character;
let card;
const faces = {};

function mat(color, extra) {
  return new THREE.MeshStandardMaterial({
    color,
    metalness: 0.04,
    roughness: 0.58,
    ...extra,
  });
}

const shellMat = mat(SHELL, { roughness: 0.62 });
const inkMat = mat(INK, { roughness: 0.4 });
const cordMat = mat(0xd4b06a, { metalness: 0.74, roughness: 0.24 });

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

function cord(points) {
  const curve = new THREE.CatmullRomCurve3(points);
  return new THREE.Mesh(new THREE.TubeGeometry(curve, 48, 0.7, 8, false), cordMat);
}

function arc(span, drop, radius) {
  const pts = [];
  for (let i = 0; i <= 18; i += 1) {
    const t = i / 18 - 0.5;
    pts.push(new THREE.Vector3(Math.sin(t * span) * 3.4, -Math.cos(t * span) * drop, 0));
  }
  return new THREE.Mesh(new THREE.TubeGeometry(new THREE.CatmullRomCurve3(pts), 20, radius, 6, false), inkMat);
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

  for (const x of [-6.2, 6.2]) {
    const cheek = new THREE.Mesh(new THREE.SphereGeometry(2.05, 24, 16), mat(0xf7f1ea, { roughness: 0.42 }));
    cheek.scale.set(1, 1, 0.55);
    cheek.position.set(x, 29.2, 7.1);
    g.add(cheek);
  }

  const usb = new THREE.Mesh(new THREE.BoxGeometry(9, 1.5, 2.6), mat(0x3a3834, { roughness: 0.45, metalness: 0.15 }));
  usb.position.set(0, 2.2, 3.2);
  g.add(usb);

  const slot = new THREE.Mesh(new THREE.BoxGeometry(12.2, 1.5, 1.7), mat(0x141210, { roughness: 0.85 }));
  slot.position.set(0, 45.6, 0.2);
  g.add(slot);
  return g;
}

function ears(parent) {
  for (const side of [-1, 1]) {
    const lug = new THREE.Mesh(new THREE.CapsuleGeometry(1.35, 9, 8, 16), shellMat);
    lug.position.set(side * 5.2, 45.6, 2.6);
    lug.rotation.z = side * -0.34;
    parent.add(lug);
    const inner = new THREE.Mesh(new THREE.SphereGeometry(1.15, 16, 12), mat(0xf0b2a6, { roughness: 0.55 }));
    inner.scale.set(0.72, 1.15, 0.42);
    inner.position.set(side * 6.15, 48.6, 4.3);
    inner.rotation.z = side * -0.34;
    parent.add(inner);
  }
  parent.add(
    cord([
      new THREE.Vector3(-3.4, 63, 2.6),
      new THREE.Vector3(-7.6, 51.2, 2.6),
      new THREE.Vector3(-3, 51.2, 2.6),
      new THREE.Vector3(0, 51.2, 2.6),
      new THREE.Vector3(3, 51.2, 2.6),
      new THREE.Vector3(7.6, 51.2, 2.6),
      new THREE.Vector3(3.4, 63, 2.6),
    ]),
  );
}

function openEye(x, y, scale) {
  const g = new THREE.Group();
  g.position.set(x, y, 6.7);
  const white = new THREE.Mesh(new THREE.SphereGeometry(1.85 * scale, 24, 16), mat(0xfffaf6, { roughness: 0.28 }));
  white.scale.z = 0.62;
  g.add(white);
  const pupil = new THREE.Mesh(new THREE.SphereGeometry(0.78 * scale, 16, 12), inkMat);
  pupil.position.set(0.15, -0.08, 0.85);
  g.add(pupil);
  const shine = new THREE.Mesh(new THREE.SphereGeometry(0.32 * scale, 12, 8), mat(0xffffff, { roughness: 0.15 }));
  shine.position.set(-0.45, 0.5, 1.05);
  g.add(shine);
  return g;
}

function closedEye(x, y) {
  const lid = arc(1.15, 0.55, 0.26);
  lid.scale.set(0.55, 0.7, 1);
  lid.position.set(x, y + 0.4, 7.15);
  lid.rotation.z = Math.PI;
  return lid;
}

function buildFaces(parent) {
  const happy = new THREE.Group();
  happy.add(openEye(-4.8, 36.8, 1));
  happy.add(openEye(4.4, 36.8, 1));
  const grin = arc(1.35, 1.35, 0.32);
  grin.position.set(0, 23.6, 7.15);
  happy.add(grin);
  const sleepy = new THREE.Group();
  sleepy.add(closedEye(-4.8, 36.6));
  sleepy.add(closedEye(4.4, 36.6));
  const soft = arc(1.05, 0.7, 0.26);
  soft.position.set(0, 24.2, 7.15);
  sleepy.add(soft);
  const surprised = new THREE.Group();
  surprised.add(openEye(-4.8, 37.2, 1.15));
  surprised.add(openEye(4.4, 37.2, 1.15));
  const oh = new THREE.Mesh(new THREE.SphereGeometry(1.35, 20, 16), mat(0xfffaf6, { roughness: 0.35 }));
  oh.scale.set(0.85, 1.05, 0.45);
  oh.position.set(0, 23.2, 7.05);
  surprised.add(oh);
  const hole = new THREE.Mesh(new THREE.SphereGeometry(0.72, 16, 12), inkMat);
  hole.scale.set(0.8, 1.05, 0.4);
  hole.position.set(0, 23.1, 7.45);
  surprised.add(hole);
  faces.happy = happy;
  faces.sleepy = sleepy;
  faces.surprised = surprised;
  happy.visible = true;
  sleepy.visible = false;
  surprised.visible = false;
  parent.add(happy, sleepy, surprised);
}

function build() {
  const g = new THREE.Group();
  g.add(shell());
  ears(g);
  buildFaces(g);
  card = new THREE.Group();
  card.add(new THREE.Mesh(new THREE.BoxGeometry(11, 15, 0.85), mat(0x1a1a1a, { metalness: 0.18, roughness: 0.4 })));
  const stripe = new THREE.Mesh(new THREE.BoxGeometry(11, 2.2, 0.05), cordMat);
  stripe.position.set(0, -5.5, 0.45);
  card.add(stripe);
  card.userData.homeY = 37.4;
  card.position.set(0, 37.4, 0.3);
  g.add(card);

  const shade = new THREE.Mesh(
    new THREE.CircleGeometry(18, 40),
    new THREE.MeshBasicMaterial({ color: 0x000000, transparent: true, opacity: 0.28, depthWrite: false }),
  );
  shade.rotation.x = -Math.PI / 2;
  shade.position.y = 0.04;
  g.add(shade);
  return g;
}

function setFace(name) {
  for (const key of Object.keys(faces)) faces[key].visible = key === name;
}

function setSlide(t) {
  card.position.y = card.userData.homeY + t * 12;
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
      spherical.radius = Math.min(180, Math.max(32, spherical.radius * (e.deltaY > 0 ? 1.08 : 0.92)));
      cam.position.setFromSpherical(spherical).add(target);
      cam.lookAt(target);
    },
    { passive: false },
  );
  cam.lookAt(target);
  return { target, spherical };
}

function init() {
  const canvas = document.querySelector("#cad");
  const wrap = document.querySelector("#viewer-stage");
  if (!canvas || !wrap || typeof THREE === "undefined") return;

  scene = new THREE.Scene();
  scene.background = new THREE.Color(0x141210);
  camera = new THREE.PerspectiveCamera(38, 1, 0.1, 500);
  camera.position.set(22, 40, 78);
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

  scene.add(new THREE.AmbientLight(0xfff6ee, 0.6));
  scene.add(new THREE.HemisphereLight(0xfff3e6, 0x2a2420, 0.4));
  const sun = new THREE.DirectionalLight(0xfff1e4, 1.2);
  sun.position.set(24, 60, 40);
  scene.add(sun);
  const rim = new THREE.DirectionalLight(0xc5d4e2, 0.55);
  rim.position.set(-36, 20, -24);
  scene.add(rim);

  const grid = new THREE.GridHelper(160, 16, 0x3a342c, 0x241f1b);
  scene.add(grid);

  character = build();
  scene.add(character);
  controls = attachOrbit(camera, canvas);

  const slide = document.querySelector("#slide");
  setSlide(slide ? Number(slide.value) : 0);
  if (slide) slide.addEventListener("input", () => setSlide(Number(slide.value)));

  document.querySelectorAll("[data-face]").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelectorAll("[data-face]").forEach((el) => el.classList.remove("on"));
      btn.classList.add("on");
      setFace(btn.dataset.face);
    });
  });

  new ResizeObserver(() => resize()).observe(wrap);
  window.addEventListener("resize", resize);

  const clock = new THREE.Clock();
  function tick() {
    const t = clock.getElapsedTime();
    character.position.y = Math.sin(t * 1.4) * 0.35;
    renderer.render(scene, camera);
    requestAnimationFrame(tick);
  }
  tick();
}

init();
