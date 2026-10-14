// 건물: 흰 벽 #F8FAFC + 네이비 띠 #1E3A5F. 증권사는 높은 사무동, 거래소 · 결제원은 지붕 없는 상자(안이 보인다), 집은 몸통 + 회색 지붕 InstancedMesh.
import * as THREE from 'three';
import { CSS2DRenderer, CSS2DObject } from 'three/addons/renderers/CSS2DRenderer.js';
import { mat, boxGeo } from '../c3d/models.js';
import { BUILDINGS, OPEN_WALL, NAVY, WALL, HOUSES, HOUSE, NEIGHBOR, BOARD } from './layout.js';

const wall = mat(WALL, .9), band = mat(NAVY, .7);

function add(g, w, h, d, x, y, z, m) {
  const mesh = new THREE.Mesh(boxGeo(w, h, d), m);
  mesh.position.set(x, y, z);
  mesh.castShadow = mesh.receiveShadow = true;
  g.add(mesh);
}

// c3d/buildings.js 의 openShell 에서 복사: 바닥 위에 벽 네 면만 세우고 윗단에 띠를 두른다. 거래소는 서쪽 벽에 출입구(gap)를 낸다.
function openShell(g, b) {
  const t = .2, h = OPEN_WALL, r = .16, y = h + r / 2;
  add(g, b.w, h, t, 0, h / 2, -b.d / 2 + t / 2, wall); // 북
  add(g, b.w, h, t, 0, h / 2, b.d / 2 - t / 2, wall);  // 남
  add(g, b.w + .06, r, t + .06, 0, y, -b.d / 2 + t / 2, band);
  add(g, b.w + .06, r, t + .06, 0, y, b.d / 2 - t / 2, band);
  const inner = b.d - 2 * t, z0 = -inner / 2, z1 = inner / 2, c = b.y + b.d / 2;
  const spans = b.gap ? [[z0, b.gap.z0 - c], [b.gap.z1 - c, z1]] : [[z0, z1]];
  for (const sx of [-1, 1]) {
    const spanList = sx < 0 ? spans : [[z0, z1]];
    for (const [a, e] of spanList) {
      add(g, t, h, e - a, sx * (b.w / 2 - t / 2), h / 2, (a + e) / 2, wall);
      add(g, t + .06, r, e - a, sx * (b.w / 2 - t / 2), y, (a + e) / 2, band);
    }
  }
  add(g, b.w - .4, .04, b.d - .4, 0, .06, 0, mat(0xD9DEE4, .95)); // 바닥
}

function building(b) {
  const g = new THREE.Group();
  g.name = b.id;
  g.position.set(b.x + b.w / 2, 0, b.y + b.d / 2);
  g.userData = { id: b.id, name: b.name, kind: 'building', open: !!b.open };
  if (b.open) { openShell(g, b); return g; }
  add(g, b.w, b.h, b.d, 0, b.h / 2, 0, wall);
  const bh = Math.min(.5, b.h * .14);
  add(g, b.w + .06, bh, b.d + .06, 0, b.h * .62, 0, band);   // 벽 중간 높이를 한 바퀴
  add(g, b.w + .12, .12, b.d + .12, 0, b.h + .06, 0, mat(new THREE.Color(b.top).getHex(), .9)); // 옥상 가장자리
  return g;
}

// 집 40채: 몸통 · 지붕 · 띠 각각 InstancedMesh 하나(집마다 메시를 따로 만들지 않는다)
function houses() {
  const n = HOUSES.length, { w, d, h } = HOUSE;
  const body = new THREE.InstancedMesh(boxGeo(w, h, d), wall, n);
  const roofGeo = new THREE.ConeGeometry(.98, .55, 4).rotateY(Math.PI / 4);
  const roof = new THREE.InstancedMesh(roofGeo, mat(0x9CA3AF, .9), n);
  const stripe = new THREE.InstancedMesh(boxGeo(w + .04, .1, d + .04), band, n);
  const o = new THREE.Object3D();
  HOUSES.forEach((hs, i) => {
    o.position.set(hs.x, .06 + h / 2, hs.z); o.updateMatrix(); body.setMatrixAt(i, o.matrix);
    o.position.set(hs.x, .06 + h * .55, hs.z); o.updateMatrix(); stripe.setMatrixAt(i, o.matrix);
    o.position.set(hs.x, .06 + h + .27, hs.z); o.updateMatrix(); roof.setMatrixAt(i, o.matrix);
  });
  for (const m of [body, roof, stripe]) { m.castShadow = m.receiveShadow = true; m.name = 'houses'; }
  return [body, stripe, roof];
}

export function createBuildings() {
  const group = new THREE.Group();
  group.name = 'buildings';
  BUILDINGS.forEach(b => group.add(building(b)));
  houses().forEach(m => group.add(m));
  return group;
}

// 이름표(CSS2D 12px): 증권사 · 거래소 · 결제원 · 투자자 동네 · 숫자 판. 캔버스 위 · #ui 아래.
export function createLabels(scene) {
  const root = new CSS2DRenderer();
  Object.assign(root.domElement.style, { position: 'fixed', inset: '0', pointerEvents: 'none', overflow: 'hidden' });
  root.domElement.id = 's3d-labels';
  document.body.insertBefore(root.domElement, document.getElementById('ui'));
  const spots = [
    ...BUILDINGS.map(b => [b.name, b.x + b.w / 2, (b.h || 2.4) + .9, b.y + b.d / 2]),
    ['투자자 동네', NEIGHBOR.cx, 2.2, NEIGHBOR.y + 1],
    ['숫자 판', BOARD.x, BOARD.y0 + BOARD.h + .8, BOARD.z],
  ];
  spots.forEach(([text, x, y, z]) => {
    const el = document.createElement('div');
    el.className = 's3d-label';
    el.textContent = text;
    const o = new CSS2DObject(el);
    o.position.set(x, y, z);
    scene.add(o);
  });
  return { render: (s, cam) => root.render(s, cam), resize: () => root.setSize(window.innerWidth, window.innerHeight) };
}
