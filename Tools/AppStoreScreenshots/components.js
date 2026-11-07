// Builds the pieces the frames use: the caption, a realistic iPhone, a full-bleed Mac window,
// and the Cover Flow tiles that carry the app's crate on past the phone. Each page describes
// its frames as data and calls these, so every frame is measured the same way.

function el(tag, style = {}, attrs = {}, className = "") {
  const node = document.createElement(tag);
  Object.assign(node.style, style);
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
  if (className) node.className = className;
  return node;
}

const px = (n) => `${n}px`;

// ---------- Caption ----------

// Two lines in the accent colour, the idea in Semibold and the specifics in Regular, at one
// size, like Apple's own App Store captions. `inline` sets both on one line (the Mac band).
function caption({ left, width, top, idea, detail, size, inline = false }) {
  const block = el("div", { left: px(left), width: px(width), top: px(top), fontSize: px(size) }, {}, "caption");
  const a = el("span", {}, {}, "idea");
  a.textContent = idea;
  const b = el("span", {}, {}, "detail");
  b.textContent = detail;
  block.append(a, inline ? document.createTextNode(" ") : el("br"), b);
  return block;
}

// ---------- Covers ----------

// The app's own placeholder cover (GeneratedCover in ArtworkView.swift), redrawn as SVG so it
// stays sharp at any size: a two-tone gradient and one soft shape, from a hash of the name.
function hashSeed(seed) {
  let value = 0xcbf29ce484222325n;
  for (const byte of new TextEncoder().encode(seed)) {
    value ^= BigInt(byte);
    value = (value * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return Number(value & 0x7fffffffn);
}

function hsb(h, s, b) {
  const f = (n) => {
    const k = (n + h * 6) % 6;
    return b - b * s * Math.max(0, Math.min(k, 4 - k, 1));
  };
  return `rgb(${Math.round(f(5) * 255)}, ${Math.round(f(3) * 255)}, ${Math.round(f(1) * 255)})`;
}

let coverCount = 0;
function coverSVG(seed) {
  const hash = hashSeed(seed);
  const hue = (hash % 360) / 360;
  const shift = 0.06 + ((hash >> 9) % 18) / 100;
  const motif = (hash >> 17) % 4;
  const id = `c${coverCount++}`;
  const light = 'fill="#fff" fill-opacity="0.22"';
  let art = "";
  if (motif === 0) {
    art = `<circle cx="78" cy="72" r="40" ${light}/>`;
  } else if (motif === 1) {
    for (let i = 0; i < 4; i++) {
      art += `<circle cx="78" cy="78" r="${50 - 100 * (0.18 + i * 0.14)}" fill="none" stroke="#fff" stroke-opacity="0.22" stroke-width="3.5"/>`;
    }
  } else if (motif === 2) {
    for (let i = -1; i <= 2.0001; i += 0.22) {
      art += `<line x1="${100 * i}" y1="100" x2="${100 * (i + 1)}" y2="0" stroke="#fff" stroke-opacity="0.14" stroke-width="6"/>`;
    }
  } else {
    art = `<path d="M0 62 C35 35 60 85 100 50 L100 100 L0 100 Z" ${light}/>`;
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" preserveAspectRatio="none">
    <defs><linearGradient id="${id}" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="${hsb(hue, 0.55, 0.95)}"/>
      <stop offset="1" stop-color="${hsb((hue + shift) % 1, 0.75, 0.55)}"/>
    </linearGradient></defs>
    <rect width="100" height="100" fill="url(#${id})"/>${art}
  </svg>`;
}

// A mix's artwork, as the crate draws it: four covers in a square, turned a little on its
// vertical axis so its outer edge stands slightly taller, the way the app's side tiles do.
function mixTile({ seeds, size, left, top, turn, perspective }) {
  const node = el("div", {
    left: px(left), top: px(top), width: px(size), height: px(size),
    transform: `perspective(${perspective}px) rotateY(${turn}deg)`,
  }, {}, "tile");
  node.innerHTML = seeds.map(coverSVG).join("");
  return node;
}

// ---------- iPhone ----------

// An iPhone with a 402 x 874 pt screen, like the captures, at `s` pixels per point.
const PHONE = { screen: [402, 874], band: 3.2, bezel: 4.6, radius: 55, island: [124, 37, 11.5] };
const phoneSize = (s) => {
  const edge = PHONE.band + PHONE.bezel;
  return { w: (PHONE.screen[0] + edge * 2) * s, h: (PHONE.screen[1] + edge * 2) * s, edge: edge * s };
};

function iphone({ src, left, top, s }) {
  const { w, h } = phoneSize(s);
  const b = PHONE.band * s, z = PHONE.bezel * s, r = PHONE.radius * s;
  const phone = el("div", { left: px(left), top: px(top), width: px(w), height: px(h) }, {}, "iphone");
  const buttons = [
    { side: "left", top: 172, height: 28 },
    { side: "left", top: 232, height: 60 },
    { side: "left", top: 306, height: 60 },
    { side: "right", top: 262, height: 96 },
    { side: "right", top: 560, height: 66 },
  ];
  for (const btn of buttons) {
    phone.append(el("div", {
      top: px(btn.top * s), height: px(btn.height * s), width: px(3 * s),
      borderRadius: px(1.5 * s), [btn.side]: px(-2.2 * s),
    }, {}, "button"));
  }
  phone.append(el("div", { borderRadius: px(r + z + b) }, {}, "band"));
  phone.append(el("div", { inset: px(b), borderRadius: px(r + z) }, {}, "bezel"));
  const screen = el("div", { left: px(b + z), top: px(b + z), width: px(PHONE.screen[0] * s), height: px(PHONE.screen[1] * s), borderRadius: px(r) }, {}, "screen");
  screen.append(el("img", {}, { src }));
  const [iw, ih, it] = PHONE.island;
  screen.append(el("div", {
    width: px(iw * s), height: px(ih * s), top: px(it * s), left: px(((PHONE.screen[0] - iw) / 2) * s), borderRadius: px((ih / 2) * s),
  }, {}, "island"));
  phone.append(screen);
  return phone;
}

// Where a pixel of a 1206 x 2622 capture lands on a phone drawn by iphone().
function onPhone({ left, top, s }, x, y) {
  const k = (PHONE.screen[0] * s) / 1206;
  const e = phoneSize(s).edge;
  return { x: left + e + x * k, y: top + e + y * k, k };
}

// ---------- Mac ----------

// A window capture shown full bleed: `crop` (in the capture's pixels) is scaled to fill the
// box exactly, so nothing is stretched.
function macShot({ src, crop, left, top, width, height }) {
  const [x, y, w] = crop;
  const k = width / w;
  const box = el("div", { left: px(left), top: px(top), width: px(width), height: px(height) }, {}, "mac-window");
  box.append(el("img", { left: px(-x * k), top: px(-y * k), width: px(crop[4] * k), height: px(crop[5] * k) }, { src }));
  return box;
}

// ---------- Frames ----------

function frame(index, width, height) {
  const node = el("section", { left: px(index * width), width: px(width), height: px(height) }, {}, "frame");
  node.dataset.index = index;
  return node;
}

function ready() {
  const images = [...document.images].map((img) => img.decode().catch(() => {}));
  Promise.all([document.fonts.ready, ...images]).then(() => { document.body.dataset.ready = "1"; });
}
