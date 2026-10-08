// 3D-② 단지 조립: 랙·도크 문·생산동 기계·지게차·소품·장식 트럭. 모양과 배치만(데이터 연결은 3D-③).
import * as THREE from 'three';
import { BUILDINGS, DOCKS, HALL, MACHINES, ROWY, GW, GATE } from './layout.js';
import {
  forklift, pallet, rack, dockDoor, setShutter, machine, cone, barrier, mat, boxGeo, part,
  palletGeo, WOOD, ITEM_COLORS, MACHINE,
} from './models.js';
import { loadTrucks, truck, addDecor, TRUCK_LEN } from './kenney.js';

// 칸 코드("RAW-A-01-01") → 칸 안 팔레트 자리 4곳의 월드 좌표(팔레트 바닥 중심). 칸 번호: bay 1~3 × level 1~2 순서
export const binSlots = {};
// 도크 코드 → { position: 트럭 중심, rotationY, door }  (트럭 뒤쪽이 문에 닿는다)
export const dockSpots = {};
export const machines = {}; // 'M1' → machine Group

const pick = i => ITEM_COLORS[i % ITEM_COLORS.length];

// 랙 칸에 팔레트를 InstancedMesh 로 쌓는다(일부 칸은 비워 둔다)
function stock(group, spots) {
  const deck = new THREE.InstancedMesh(palletGeo.deck, mat(WOOD, .9), spots.length);
  const boxes = new THREE.InstancedMesh(palletGeo.stack, mat(0xFFFFFF, .85), spots.length);
  const o = new THREE.Object3D(), c = new THREE.Color();
  spots.forEach((p, i) => {
    o.position.copy(p); o.updateMatrix();
    deck.setMatrixAt(i, o.matrix); boxes.setMatrixAt(i, o.matrix);
    boxes.setColorAt(i, c.setHex(pick(i)));
  });
  for (const m of [deck, boxes]) { m.castShadow = m.receiveShadow = true; group.add(m); }
}

// 건물 안에 랙 4개(세로 방향)를 세운다. prefix = 'RAW-A' | 'FG-A'
function rackRow(group, prefix, x0, z0, pitch) {
  const spots = [];
  for (let i = 0; i < 4; i++) {
    const r = rack(3, 2);
    r.rotation.y = Math.PI / 2; // 랙의 가로(x)가 월드 -z 로 눕는다
    r.position.set(x0 + i * pitch, 0, z0 + r.userData.size.w / 2);
    r.name = `${prefix}-0${i + 1}`;
    group.add(r);
    r.updateMatrixWorld(true);
    r.userData.slots.forEach((s, si) => {
      const world = s.spots.map(v => r.localToWorld(v.clone()));
      binSlots[`${prefix}-0${i + 1}-${s.code}`] = world;
      world.forEach((p, k) => { if ((i * 5 + si * 3 + k * 7) % 10 < 4) spots.push(p); });
    });
  }
  stock(group, spots);
}

function floor(group, b) {
  const m = new THREE.Mesh(boxGeo(b.w - .4, .04, b.d - .4), mat(0xD9DEE4, .95));
  m.position.set(b.x + b.w / 2, .06, b.y + b.d / 2);
  m.receiveShadow = true;
  group.add(m);
}

function docks(group) {
  DOCKS.forEach(d => {
    const b = BUILDINGS.find(x => x.id === d.building), zEdge = b.y + b.d;
    d.slots.forEach(s => {
      const door = dockDoor(s.code);
      door.position.set(s.x + s.w / 2, 0, zEdge);
      group.add(door);
      setShutter(door, 0);
      dockSpots[s.code] = { position: new THREE.Vector3(s.x + s.w / 2, 0, zEdge + .3 + TRUCK_LEN / 2), rotationY: 0, door };
      for (const sx of [-1, 1]) { // 트럭 자리 양옆 라바콘
        const c = cone();
        c.position.set(s.x + s.w / 2 + sx * 1.0, 0, zEdge + 1.0);
        group.add(c);
      }
    });
  });
}

function hall(group) {
  const { x, y, w, d } = HALL;
  const H = .9, t = .15, WALL = 0xF1F3F6;
  // 낮은 벽: 북쪽 출입 틈(x 12~14.4)·동쪽 틈(y 19.6~22)
  const wallBox = (x1, z1, x2, z2) => part(group, x2 - x1, H, z2 - z1, WALL, (x1 + x2) / 2, H / 2, (z1 + z2) / 2, .9);
  wallBox(x, y, x + 7, y + t); wallBox(x + 9.4, y, x + w, y + t);
  wallBox(x, y + d - t, x + w, y + d);
  wallBox(x, y, x + t, y + d);
  wallBox(x + w - t, y, x + w, y + 4.6); wallBox(x + w - t, y + 7, x + w, y + d);
  part(group, w, .06, .12, 0x2563EB, x + w / 2, H + .03, y + d - .06); // 남쪽 벽 윗단 띠
  part(group, w, .06, .12, 0x2563EB, x + w / 2, H + .03, y + .06);

  const lineside = [];
  MACHINES.forEach(m => {
    const g = machine(m.kind);
    const cx = x + m.x + MACHINE.w / 2, cz = y + ROWY[m.row] + MACHINE.d / 2;
    g.position.set(cx, .06, cz);
    if (m.row === 1) g.rotation.y = Math.PI; // 아래줄은 통로 쪽(-z)을 본다
    g.name = m.code;
    g.userData.code = m.code;
    group.add(g);
    machines[m.code] = g;
    lineside.push([cx, cz + (m.row === 0 ? MACHINE.d / 2 + .55 : -MACHINE.d / 2 - .55), m]);
  });

  // 라인사이드 적치 구역: 기계 앞 바닥의 노란 판
  const zone = new THREE.InstancedMesh(boxGeo(1.4, .02, .8), mat(0xF3E3A0, .95), lineside.length);
  const o = new THREE.Object3D();
  lineside.forEach(([cx, cz], i) => { o.position.set(cx, .085, cz); o.updateMatrix(); zone.setMatrixAt(i, o.matrix); });
  zone.receiveShadow = true;
  group.add(zone);
  // 몇 곳은 팔레트가 놓여 있다
  const stays = lineside.filter((_, i) => i % 3 === 0).flatMap(([cx, cz], i) => [new THREE.Vector3(cx - .3, .095, cz), new THREE.Vector3(cx + .3, .095, cz)]);
  stock(group, stays);

  const fk = forklift();
  fk.position.set(x + 6.5, .06, y + 6.1);
  fk.rotation.y = Math.PI / 2;
  group.add(fk);
  group.add(Object.assign(barrier(1.8), { position: new THREE.Vector3(x + 8.2, 0, y + .5) }));
}

function matYard(group) {
  const fk = forklift();
  fk.position.set(19.2, .06, 8.6);
  fk.rotation.y = -Math.PI / 2 + .3;
  fk.getObjectByName('forks').position.y = .5;
  const p = pallet(ITEM_COLORS[1]);
  fk.getObjectByName('load').add(p);
  group.add(fk);
  [[16.6, 8.9, 0], [17.4, 8.9, 2]].forEach(([px, pz, ci]) => { const p2 = pallet(pick(ci)); p2.position.set(px, .06, pz); group.add(p2); });
}

export function createCampus() {
  const group = new THREE.Group();
  group.name = 'campus';

  const mat1 = BUILDINGS.find(b => b.id === 'mat'), ship = BUILDINGS.find(b => b.id === 'ship');
  floor(group, mat1); floor(group, ship);
  // 자재창고: 안쪽 폭 15.2~22.8, 북쪽 벽 안쪽에서 시작. 랙 가로 4.2 + 남쪽 통로
  rackRow(group, 'RAW-A', 15.9, mat1.y + .35, 1.85);
  // 출하장: 안쪽 깊이가 5 라서 랙이 거의 꽉 찬다(남쪽 통로 0.7)
  rackRow(group, 'FG-A', 35.9, ship.y + .3, 1.85);
  docks(group);
  hall(group);
  matYard(group);

  // 정문 차단기 옆 배리어
  const br = barrier(1.4);
  br.position.set(GW - 1.6, 0, GATE.openY0 - .7);
  br.rotation.y = Math.PI / 2;
  group.add(br);
  return group;
}

// Kenney 자산이 필요한 것(트럭·장식). 로드 후 group 에 붙인다. 정지 상태 — 3D-③ 이 대체한다
export async function addKenneyParts(group) {
  await loadTrucks();
  const decor = await addDecor(group);
  // 출하장 앞 1대(OUT-01 도크, 문 열림)
  const t1 = truck('truck', 0xE5E7EB);
  const s1 = dockSpots['DOCK-OUT-01'];
  t1.position.copy(s1.position);
  t1.rotation.y = s1.rotationY;
  t1.name = 'truck-dock';
  group.add(t1);
  setShutter(s1.door, 1);
  // 정문 밖 도로 1대: 단지 쪽(-x)을 향해 서 있다
  const t2 = truck('flat', 0x2563EB);
  t2.position.set(GW + 6, 0, 16.9);
  t2.rotation.y = -Math.PI / 2;
  t2.name = 'truck-road';
  group.add(t2);
  return { decor, trucks: [t1, t2] };
}
