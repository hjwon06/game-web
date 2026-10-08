import * as THREE from 'three';
import { GW, GH, HALL, PLAZA, ROADS, ROAD_DASHES, OUTER_ROADS, OUTER_DASH, GATE, HYDRANT, TREES, DOCKS, PX } from './layout.js';

const mat = (c, o = {}) => new THREE.MeshStandardMaterial({ color: c, roughness: .95, metalness: 0, ...o });

// 2D 사각형 (x, y, w, d) 을 높이 y 의 수평 판으로
function slab(group, x, z, w, d, color, y, t = .02, cast = false) {
  const m = new THREE.Mesh(new THREE.BoxGeometry(w, t, d), mat(color));
  m.position.set(x + w / 2, y - t / 2, z + d / 2);
  m.receiveShadow = true; m.castShadow = cast;
  group.add(m);
  return m;
}

function dashLine(group, [x1, z1], [x2, z2], y) {
  const len = Math.hypot(x2 - x1, z2 - z1), ang = Math.atan2(z2 - z1, x2 - x1);
  const step = 1.2, dash = .7, n = Math.floor(len / step);
  const geo = new THREE.BoxGeometry(dash, .01, .1);
  const im = new THREE.InstancedMesh(geo, mat(0xFFFFFF), n);
  const o = new THREE.Object3D();
  for (let i = 0; i < n; i++) {
    const t = (i * step + dash / 2) / len;
    o.position.set(x1 + (x2 - x1) * t, y, z1 + (z2 - z1) * t);
    o.rotation.set(0, -ang, 0);
    o.updateMatrix();
    im.setMatrixAt(i, o.matrix);
  }
  im.receiveShadow = true;
  group.add(im);
}

function box(group, x, z, w, d, h, color, y0 = 0) {
  const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), mat(color));
  m.position.set(x + w / 2, y0 + h / 2, z + d / 2);
  m.castShadow = true; m.receiveShadow = true;
  group.add(m);
  return m;
}

function field(group) {
  const FY = -.4; // 단지 판 아래의 들판
  const big = new THREE.Mesh(new THREE.PlaneGeometry(200, 200), mat(0xDCE4D8));
  big.rotation.x = -Math.PI / 2; big.position.set(GW / 2, FY - .02, GH / 2); big.receiveShadow = true;
  group.add(big);
  // 어두운 쪽 타일(체스판 2톤)
  const spots = [];
  for (let i = -22; i < GW + 22; i += 4) for (let j = -22; j < GH + 22; j += 4) {
    if (i > -5 && i < GW + 4 && j > -5 && j < GH + 4) continue;
    if (((i + j) / 4) % 2) spots.push([i, j]);
  }
  const im = new THREE.InstancedMesh(new THREE.BoxGeometry(3.8, .02, 3.8), mat(0xD6E0D3), spots.length);
  const o = new THREE.Object3D();
  spots.forEach(([i, j], k) => { o.position.set(i + 1.9, FY - .01, j + 1.9); o.updateMatrix(); im.setMatrixAt(k, o.matrix); });
  im.receiveShadow = true;
  group.add(im);
  OUTER_ROADS.forEach(([x, z, w, d], k) => slab(group, x, z, w, d, k === 4 ? 0xBFC5CD : 0xC5CBD2, FY + .01));
  dashLine(group, OUTER_DASH[0], OUTER_DASH[1], FY + .03);
}

function fence(group) {
  const h = 10 * PX, c = 0xB5BDB4;
  const rail = (x1, z1, x2, z2) => {
    const len = Math.hypot(x2 - x1, z2 - z1);
    for (const y of [h * .45, h]) {
      const m = new THREE.Mesh(new THREE.BoxGeometry(len, .06, .06), mat(c));
      m.position.set((x1 + x2) / 2, y, (z1 + z2) / 2);
      if (z1 !== z2) m.rotation.y = Math.PI / 2;
      m.castShadow = true;
      group.add(m);
    }
    // 기둥(4칸마다)
    const n = Math.max(1, Math.round(len / 4));
    const posts = new THREE.InstancedMesh(new THREE.BoxGeometry(.1, h, .1), mat(c), n + 1);
    const o = new THREE.Object3D();
    for (let i = 0; i <= n; i++) { o.position.set(x1 + (x2 - x1) * i / n, h / 2, z1 + (z2 - z1) * i / n); o.updateMatrix(); posts.setMatrixAt(i, o.matrix); }
    posts.castShadow = true;
    group.add(posts);
  };
  const a = .4, bx = GW - .4, bz = GH - .4;
  rail(a, a, bx, a);
  rail(bx, a, bx, GATE.openY0);
  rail(bx, GATE.openY1, bx, bz);
  rail(bx, bz, a, bz);
  rail(a, bz, a, a);
}

function gate(group) {
  const g = GATE;
  box(group, g.x, g.y, g.w, g.d, g.h, 0xF4F5F7); // 경비실
  const win = new THREE.Mesh(new THREE.PlaneGeometry(1.0, 2 * PX * 1.2), new THREE.MeshStandardMaterial({ color: 0x1A1A2E, roughness: .4 }));
  win.rotation.y = Math.PI / 2; win.position.set(g.x + g.w + .01, g.h * .75, g.y + g.d / 2);
  group.add(win);
  // 차단기 막대
  box(group, GW - .6, g.openY0, .12, g.openY1 - g.openY0, .08, 0xC0392B, 1.1);
}

function trees(group) {
  const n = TREES.length;
  const trunk = new THREE.InstancedMesh(new THREE.CylinderGeometry(.08, .1, .8, 6), mat(0x8B5E3C), n);
  const cone = new THREE.InstancedMesh(new THREE.ConeGeometry(.75, 1.5, 8), mat(0x7FA48A), n);
  const ball = new THREE.InstancedMesh(new THREE.SphereGeometry(.45, 10, 8), mat(0x93B59C), n);
  const o = new THREE.Object3D();
  TREES.forEach(([x, z], i) => {
    const s = .85 + ((i * 37) % 10) / 33; // 나무마다 크기를 조금 달리한다
    const y0 = x > -4 && x < GW + 4 && z > -4 && z < GH + 4 ? 0 : -.4; // 단지 밖은 들판 높이
    o.rotation.set(0, 0, 0); o.scale.setScalar(s);
    o.position.set(x, y0 + .4 * s, z); o.updateMatrix(); trunk.setMatrixAt(i, o.matrix);
    o.position.set(x, y0 + 1.5 * s, z); o.updateMatrix(); cone.setMatrixAt(i, o.matrix);
    o.position.set(x - .05, y0 + 2.2 * s, z - .05); o.updateMatrix(); ball.setMatrixAt(i, o.matrix);
  });
  for (const m of [trunk, cone, ball]) { m.castShadow = true; m.receiveShadow = true; group.add(m); }
}

export function createGround() {
  const group = new THREE.Group();
  group.name = 'ground';
  field(group);
  // 단지 판(2D 의 두꺼운 바닥) — 윗면이 y=0
  const base = new THREE.Mesh(new THREE.BoxGeometry(GW + 1, .4, GH + 1), mat(0xE6EAE5));
  base.position.set(GW / 2, -.2, GH / 2); base.receiveShadow = true;
  group.add(base);
  slab(group, 0, 0, GW, GH, 0xE1E6E0, .01);
  slab(group, PLAZA.x, PLAZA.y, PLAZA.w, PLAZA.d, 0xE9ECEF, .02); // 포장 마당
  ROADS.forEach(([x, z, w, d]) => slab(group, x, z, w, d, 0xCDD2D9, .03));
  ROAD_DASHES.forEach(([a, b]) => dashLine(group, a, b, .05));
  // 생산동 자리: 바닥 판만(생산동 모델은 이후 단계)
  slab(group, HALL.x, HALL.y, HALL.w, HALL.d, 0xD5DAE1, .06, .03);
  // 도크 칸
  DOCKS.forEach(d => d.slots.forEach(s => slab(group, s.x, s.y, s.w, s.d, 0xC3C9D1, .04)));
  box(group, HYDRANT.x, HYDRANT.y, .25, .25, .85, 0xC0392B); // 소화전
  fence(group);
  gate(group);
  trees(group);
  return group;
}
