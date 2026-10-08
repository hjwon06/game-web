// 3D 모델 생성기. 전부 기본 도형 + 로우폴리, 그림자 on. 1 단위 = 2D 그리드 1칸(대략 2m).
// 모든 생성기는 THREE.Group 을 돌려주고, 움직이는 부분은 이름으로 찾는다:
//   forklift: 'forks'(y 0~1.2), 'load'(포크 위 앵커)   dockDoor: 'shutter'(setShutter)
//   machine: 'lamp'(setLamp)   rack: userData.slots
// 원점은 바닥 중앙, 앞쪽은 +z.
import * as THREE from 'three';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';
import { PX } from './layout.js';

const BLUE = 0x2563EB;

// ── 공유 재질·지오메트리(같은 값이면 한 개만 만든다) ──
const matCache = new Map();
export function mat(color, rough = .8) {
  const k = `${color}|${rough}`;
  if (!matCache.has(k)) matCache.set(k, new THREE.MeshStandardMaterial({ color, roughness: rough, metalness: 0 }));
  return matCache.get(k);
}
const boxCache = new Map();
export function boxGeo(w, h, d) {
  const k = `${w}|${h}|${d}`;
  if (!boxCache.has(k)) boxCache.set(k, new THREE.BoxGeometry(w, h, d));
  return boxCache.get(k);
}
const cylCache = new Map();
function cylGeo(r, h, seg) {
  const k = `${r}|${h}|${seg}`;
  if (!cylCache.has(k)) cylCache.set(k, new THREE.CylinderGeometry(r, r, h, seg));
  return cylCache.get(k);
}

function shadow(m) { m.castShadow = true; m.receiveShadow = true; return m; }
// parent 에 w×h×d 상자를 (x, y 중심, z) 에 붙인다
export function part(parent, w, h, d, color, x, y, z, rough) {
  const m = shadow(new THREE.Mesh(boxGeo(w, h, d), mat(color, rough)));
  m.position.set(x, y, z);
  parent.add(m);
  return m;
}

// ── 팔레트 ──
export const WOOD = 0xC9A27A;
// 품목색(상자). 3D-③ 에서 품목 → 색 매핑에 쓴다
export const ITEM_COLORS = [0xC98A4B, 0x7FA3C7, 0x9DB58B, 0xD4B35A, 0xB58CA8, 0x8FB5B0];
export const PALLET = { w: .6, h: .6, deckH: .08 };

const deckGeo = mergeGeometries([
  boxGeo(.6, .03, .6).clone().translate(0, .065, 0),
  boxGeo(.1, .05, .6).clone().translate(-.25, .025, 0),
  boxGeo(.1, .05, .6).clone().translate(.25, .025, 0),
]);
const stackGeo = (() => {
  const s = .26, parts = [];
  for (const y of [0, 1]) for (const x of [-1, 1]) for (const z of [-1, 1]) {
    parts.push(boxGeo(s, s, s).clone().translate(x * .14, PALLET.deckH + s / 2 + y * s, z * .14));
  }
  return mergeGeometries(parts);
})();
export const palletGeo = { deck: deckGeo, stack: stackGeo };

export function pallet(color = ITEM_COLORS[0]) {
  const g = new THREE.Group();
  g.name = 'pallet';
  g.add(shadow(new THREE.Mesh(deckGeo, mat(WOOD, .9))));
  const stack = shadow(new THREE.Mesh(stackGeo, mat(color, .85)));
  stack.name = 'boxes';
  g.add(stack);
  g.userData.height = PALLET.h;
  return g;
}

// ── 지게차 ──
export function forklift() {
  const g = new THREE.Group();
  g.name = 'forklift';
  const Y = 0xE0B43A, DK = 0x3A3F47;
  part(g, .8, .38, 1.2, Y, 0, .43, -.1);                 // 차체
  part(g, .8, .3, .5, DK, 0, .4, -.55);                  // 카운터웨이트
  part(g, .5, .08, .5, DK, 0, .66, -.15);                // 좌석
  for (const sx of [-1, 1]) for (const sz of [-1, 1]) {   // 운전석 지붕 기둥
    part(g, .05, .85, .05, DK, sx * .36, 1.1, -.12 + sz * .3);
  }
  part(g, .85, .05, .75, Y, 0, 1.55, -.12);              // 지붕
  for (const sx of [-1, 1]) part(g, .07, 1.6, .07, DK, sx * .22, .8, .62); // 마스트
  part(g, .5, .06, .07, DK, 0, 1.55, .62);
  const forks = new THREE.Group();
  forks.name = 'forks';
  forks.position.set(0, 0, .72);
  part(forks, .6, .3, .05, DK, 0, .2, 0);                 // 캐리지
  for (const sx of [-1, 1]) part(forks, .1, .04, .95, 0x9AA3AE, sx * .2, .06, .45);
  const load = new THREE.Object3D();                      // 포크 위 팔레트 앵커(바닥 중심)
  load.name = 'load';
  load.position.set(0, .08, .5);
  forks.add(load);
  g.add(forks);
  for (const [x, z, r] of [[-.4, .45, .22], [.4, .45, .22], [-.4, -.5, .2], [.4, -.5, .2]]) { // 바퀴
    const w = shadow(new THREE.Mesh(cylGeo(r, .16, 8), mat(0x2A2D33, .9)));
    w.rotation.z = Math.PI / 2;
    w.position.set(x, r, z);
    g.add(w);
  }
  return g;
}
export function setForks(fk, v) { fk.getObjectByName('forks').position.y = 1.2 * Math.min(1, Math.max(0, v)); }

// ── 랙 ──
// 칸 순서: 01=bay1·level1, 02=bay1·level2, 03=bay2·level1 … (bay 1~3 × level 1~2)
export const RACK = { cellW: 1.4, depth: 1.4, levelH: 1.15, base: .15 };
export function rack(bays = 3, levels = 2) {
  const { cellW, depth, levelH, base } = RACK;
  const g = new THREE.Group();
  g.name = 'rack';
  const W = bays * cellW, H = base + levels * levelH, GRAY = 0x9AA3AE;
  for (let i = 0; i <= bays; i++) for (const sz of [-1, 1]) part(g, .08, H, .08, GRAY, -W / 2 + i * cellW, H / 2, sz * depth / 2);
  for (let l = 0; l <= levels; l++) {
    const y = base + l * levelH;
    for (const sz of [-1, 1]) part(g, W, .09, .06, BLUE, 0, y - .03, sz * depth / 2);
    if (l < levels) part(g, W, .03, depth - .06, 0xB8C0CA, 0, base - .015 + l * levelH + .015, 0, .9);
  }
  const slots = [];
  for (let b = 0; b < bays; b++) for (let l = 0; l < levels; l++) {
    const cx = -W / 2 + (b + .5) * cellW, top = base + l * levelH + .03;
    const spots = [];
    for (const dz of [-1, 1]) for (const dx of [-1, 1]) spots.push(new THREE.Vector3(cx + dx * .35, top, dz * .35));
    slots.push({ code: String(slots.length + 1).padStart(2, '0'), bay: b + 1, level: l + 1, center: new THREE.Vector3(cx, top + PALLET.h / 2, 0), spots });
  }
  g.userData.slots = slots;
  g.userData.size = { w: W, h: H, d: depth };
  return g;
}

// ── 도크 문 ──
export const DOCK = { w: 1.2, h: 1.5 };
const plateCache = new Map();
function plateMat(label) {
  if (!plateCache.has(label)) {
    const c = document.createElement('canvas');
    c.width = 256; c.height = 96;
    const x = c.getContext('2d');
    x.fillStyle = '#FFFFFF'; x.fillRect(0, 0, 256, 96);
    x.fillStyle = '#2563EB'; x.fillRect(0, 0, 256, 8);
    x.fillStyle = '#1A1A2E'; x.font = '700 32px Pretendard, sans-serif';
    x.textAlign = 'center'; x.textBaseline = 'middle';
    x.fillText(label, 128, 54);
    const t = new THREE.CanvasTexture(c);
    t.colorSpace = THREE.SRGBColorSpace;
    plateCache.set(label, new THREE.MeshBasicMaterial({ map: t }));
  }
  return plateCache.get(label);
}
// 셔터는 문틀 위로 올라가면 잘리도록(말려 올라간 모양) 월드 y=h 평면으로 자른다. 문은 항상 지면(y=0)에 서므로 월드 평면이 맞다.
const shutterClip = [new THREE.Plane(new THREE.Vector3(0, -1, 0), DOCK.h)];
const shutterMat = new THREE.MeshStandardMaterial({ color: 0xE5E7EB, roughness: .7, clippingPlanes: shutterClip, clipShadows: true });
const slatMat = new THREE.MeshStandardMaterial({ color: 0xB8C0CA, roughness: .7, clippingPlanes: shutterClip, clipShadows: true });
const SHUTTER_H = DOCK.h - .06;

export function dockDoor(label = '') {
  const { w, h } = DOCK;
  const g = new THREE.Group();
  g.name = 'dockDoor';
  const back = new THREE.Mesh(new THREE.PlaneGeometry(w, h), mat(0x1A1A2E, .6));
  back.position.set(0, h / 2, .01);
  g.add(back);
  for (const sx of [-1, 1]) part(g, .1, h, .14, BLUE, sx * (w / 2 + .05), h / 2, .07);
  part(g, w + .3, .18, .18, BLUE, 0, h + .09, .09);
  const shutter = new THREE.Group();
  shutter.name = 'shutter';
  const panel = new THREE.Mesh(boxGeo(w, SHUTTER_H, .04), shutterMat);
  panel.castShadow = true;
  panel.position.set(0, SHUTTER_H / 2, 0);
  shutter.add(panel);
  for (const k of [.25, .5, .75]) {
    const s = new THREE.Mesh(boxGeo(w, .025, .05), slatMat);
    s.position.set(0, SHUTTER_H * k, 0);
    shutter.add(s);
  }
  shutter.userData.base = .03;
  shutter.userData.travel = h - .1;
  shutter.position.set(0, .03, .04);
  g.add(shutter);
  if (label) {
    const plate = new THREE.Mesh(new THREE.PlaneGeometry(.7, .26), plateMat(label));
    plate.position.set(0, h + .18 + .17, .1);
    g.add(plate);
  }
  g.userData.label = label;
  return g;
}
// v: 0=닫힘 1=열림
export function setShutter(door, v) {
  const s = door.getObjectByName('shutter');
  s.position.y = s.userData.base + s.userData.travel * Math.min(1, Math.max(0, v));
}

// ── 기계 ──  2D campus_data.js 의 KIND(h px, 윗면색)
export const KIND = {
  cut: { h: 34, top: '#5C7FA8' }, asm: { h: 42, top: '#4E6E95' }, chk: { h: 30, top: '#3F8F98' },
  mill: { h: 50, top: '#2F5D86' }, paint: { h: 38, top: '#2F7F6A' }, pack: { h: 30, top: '#7A8C62' },
};
export const MACHINE = { w: 1.6, d: 1.8 };
export const STATE_COLOR = { running: 0x2F6B4F, stopped: 0x6B7280, broken: 0xC0392B };
const lampGeo = new THREE.IcosahedronGeometry(.1, 0);

export function machine(kind) {
  const k = KIND[kind] || KIND.cut;
  const H = k.h * PX, top = new THREE.Color(k.top).getHex();
  const { w, d } = MACHINE;
  const g = new THREE.Group();
  g.name = 'machine';
  g.userData.kind = kind;
  const bodyH = H * .6;
  part(g, w, bodyH, d, 0xDDE3EA, 0, bodyH / 2, 0);                     // 하부 본체
  part(g, w + .06, .1, d + .06, top, 0, bodyH + .05, 0);               // 띠(종류색)
  const headH = H - bodyH - .1;
  if (kind === 'mill') part(g, w * .5, headH, d * .5, top, 0, bodyH + .1 + headH / 2, -d * .2); // 가공: 높은 주축대
  else if (kind === 'paint') part(g, w * .8, headH, d * .8, 0xCFE3DB, 0, bodyH + .1 + headH / 2, 0); // 도장: 부스
  else if (kind === 'pack') part(g, w * .9, headH, d * .45, top, 0, bodyH + .1 + headH / 2, d * .25); // 포장: 낮은 호퍼
  else if (kind === 'chk') part(g, w * .7, headH, d * .7, top, 0, bodyH + .1 + headH / 2, 0);        // 검사: 후드
  else {
    part(g, w * .35, headH, d * .8, top, -w * .27, bodyH + .1 + headH / 2, 0);                         // 절단·조립: 문형 프레임
    part(g, w * .35, headH, d * .8, top, w * .27, bodyH + .1 + headH / 2, 0);
    part(g, w, .14, d * .8, top, 0, H - .07, 0);
  }
  const lamp = new THREE.Mesh(lampGeo, new THREE.MeshStandardMaterial({ color: STATE_COLOR.stopped, emissive: STATE_COLOR.stopped, emissiveIntensity: .5, roughness: .5 }));
  lamp.name = 'lamp';
  lamp.position.set(w / 2 - .15, H + .12, d / 2 - .15);
  g.add(lamp);
  return g;
}
export function setLamp(m, status) {
  const l = m.getObjectByName('lamp'), c = STATE_COLOR[status] ?? STATE_COLOR.stopped;
  l.material.color.setHex(c); l.material.emissive.setHex(c);
}

// ── 소품 ──
export function cone() {
  const g = new THREE.Group();
  g.name = 'cone';
  part(g, .3, .03, .3, 0x2A2D33, 0, .015, 0);
  const c = shadow(new THREE.Mesh(coneGeo, mat(0xE8742A)));
  c.position.y = .03 + .22;
  g.add(c);
  part(g, .17, .06, .17, 0xFFFFFF, 0, .24, 0, .6);
  return g;
}
const coneGeo = new THREE.ConeGeometry(.12, .44, 6);

export function barrier(len = 1.6) {
  const g = new THREE.Group();
  g.name = 'barrier';
  for (const sx of [-1, 1]) part(g, .08, .75, .08, 0x3A3F47, sx * (len / 2 - .04), .375, 0);
  const n = 6, seg = len / n;
  for (let i = 0; i < n; i++) part(g, seg, .14, .06, i % 2 ? 0x2A2D33 : 0xE0B43A, -len / 2 + seg * (i + .5), .65, 0);
  for (let i = 0; i < n; i++) part(g, seg, .14, .06, i % 2 ? 0xE0B43A : 0x2A2D33, -len / 2 + seg * (i + .5), .42, 0);
  return g;
}
