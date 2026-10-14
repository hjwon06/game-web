// 건물: 흰 벽 #F8FAFC + 네이비 띠 #1E3A5F. 증권사는 높은 사무동, 거래소 · 결제원은 지붕 없는 상자(안이 보인다), 집은 몸통 + 회청색 지붕 + 문 띠 InstancedMesh, 빈 자리에는 나무.
import * as THREE from 'three';
import { CSS2DRenderer, CSS2DObject } from 'three/addons/renderers/CSS2DRenderer.js';
import { mat, boxGeo } from '../c3d/models.js';
import { BUILDINGS, OPEN_WALL, NAVY, WALL, HOUSES, HOUSE, LOTS, NEIGHBOR, BOARD } from './layout.js';

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

// 집 40채: 몸통 #F3F4F6 · 지붕 #8A96A3 · 남쪽 면 문 자리(어두운 띠) 각각 InstancedMesh 하나(집마다 메시를 따로 만들지 않는다)
function houses() {
  const n = HOUSES.length, { w, d, h } = HOUSE;
  const body = new THREE.InstancedMesh(boxGeo(w, h, d), mat(0xF3F4F6, .9), n);
  const roofGeo = new THREE.ConeGeometry(.8, .5, 4).rotateY(Math.PI / 4);
  const roof = new THREE.InstancedMesh(roofGeo, mat(0x8A96A3, .9), n);
  const door = new THREE.InstancedMesh(boxGeo(.34, .5, .05), mat(0x3B4252, .8), n);
  const o = new THREE.Object3D();
  HOUSES.forEach((hs, i) => {
    o.position.set(hs.x, .06 + h / 2, hs.z); o.updateMatrix(); body.setMatrixAt(i, o.matrix);
    o.position.set(hs.x, .06 + .25, hs.z + d / 2 + .02); o.updateMatrix(); door.setMatrixAt(i, o.matrix);
    o.position.set(hs.x, .06 + h + .25, hs.z); o.updateMatrix(); roof.setMatrixAt(i, o.matrix);
  });
  for (const m of [body, roof, door]) { m.castShadow = m.receiveShadow = true; m.name = 'houses'; }
  return [body, door, roof];
}

// 빈 qc · util 자리의 나무: 줄기 · 잎 각각 낮은 분할 InstancedMesh 하나. 크기는 인덱스로만 달라진다(결정적).
function trees() {
  const pts = [];
  LOTS.forEach(l => { for (let j = 0; j < l.nz; j++) for (let i = 0; i < l.nx; i++) pts.push([l.x + i * l.dx, l.z + j * l.dz]); });
  const trunk = new THREE.InstancedMesh(new THREE.CylinderGeometry(.07, .09, .6, 5), mat(0x8B6F47, .9), pts.length);
  const crown = new THREE.InstancedMesh(new THREE.ConeGeometry(.42, 1.1, 6), mat(0x4E8F5F, .9), pts.length);
  const o = new THREE.Object3D();
  pts.forEach(([x, z], i) => {
    const s = .8 + ((i * 7) % 5) * .08;
    o.scale.setScalar(s);
    o.position.set(x, .06 + .3 * s, z); o.updateMatrix(); trunk.setMatrixAt(i, o.matrix);
    o.position.set(x, .06 + (.6 + .5) * s, z); o.updateMatrix(); crown.setMatrixAt(i, o.matrix);
  });
  for (const m of [trunk, crown]) { m.castShadow = true; m.name = 'trees'; }
  return [trunk, crown];
}

export function createBuildings() {
  const group = new THREE.Group();
  group.name = 'buildings';
  BUILDINGS.forEach(b => group.add(building(b)));
  houses().forEach(m => group.add(m));
  trees().forEach(m => group.add(m));
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
