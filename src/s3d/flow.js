// 토큰 흐름. 위치는 전부 "재생 시각 P 의 함수"(프레임 누적 없음) → capture 에서 step 크기와 무관하게 같다.
//   주문(상자, 종목 색)  집 → 동네 북쪽 출입 틈 → 증권사 → 거래소 종목 칸
//   거절(회색 상자)      집 → 증권사 → 집
//   체결(납작한 원판)    거래소 → 증권사 → 집(house = 체결 id % 40)
// 출발 시각 = 가상 접수 · 체결 시각, 비행 시간 = 실시간 4초(받을 때의 배속으로 시장 시간 dur 에 못박았다).
import * as THREE from 'three';
import { boxGeo } from '../c3d/models.js';
import { S } from './data.js';
import { HOUSES, HOUSE_N, DOOR_GAP, AISLE_X, EX, STOCKS, STOCK_IDX, REJECT_COLOR, nodes, mk, at } from './layout.js';

const CAP = 240;           // InstancedMesh 마다 최대 토큰 수. 넘치면 오래된 것부터 뺀다
const FLOOR = .06;

// 집 → 북쪽 출입 틈 → 도로(j3) → 증권사(y 좌표 = 길 위의 높이는 tick 에서 준다)
function toBroker(house) {
  const h = HOUSES[((house % HOUSE_N) + HOUSE_N) % HOUSE_N], gz = h.z - DOOR_GAP;
  return [[h.x, h.z - .75], [h.x, gz], [AISLE_X, gz], [AISLE_X, 15], [AISLE_X, 12.5], ...nodes('j3', 'office')];
}
// 증권사 → 거래소 출입구 → 종목 칸 앞
function toExchange(stock) {
  return [...nodes('office', 'mat').slice(1), [EX.door[0], EX.door[1]], [EX.slotX[stock], EX.door[1]], [EX.slotX[stock], EX.front]];
}
const rev = pts => pts.slice().reverse();
const cache = new Map();
function pathOf(kind, house, stock) {
  const key = `${kind}|${house % HOUSE_N}|${kind === 'reject' ? 0 : stock}`;
  if (!cache.has(key)) {
    const a = toBroker(house);
    let pts;
    if (kind === 'reject') pts = [...a, ...rev(a).slice(1)];
    else if (kind === 'order') pts = [...a, ...toExchange(stock)];
    else pts = rev([...a, ...toExchange(stock)]);
    cache.set(key, mk(pts));
  }
  return cache.get(key);
}

const colorOf = new Map(STOCKS.map(s => [s.code, new THREE.Color(s.color)]));
const rejectColor = new THREE.Color(REJECT_COLOR);

export function createFlow(parent) {
  const white = new THREE.MeshStandardMaterial({ color: 0xFFFFFF, roughness: .75 });
  const boxes = new THREE.InstancedMesh(boxGeo(.3, .3, .3), white, CAP);
  const discs = new THREE.InstancedMesh(new THREE.CylinderGeometry(.24, .24, .07, 10), white, CAP);
  for (const m of [boxes, discs]) {
    m.name = m === boxes ? 'tokens-box' : 'tokens-disc';
    m.count = 0; m.castShadow = true; m.frustumCulled = false;
    m.setColorAt(0, rejectColor); // instanceColor 버퍼를 미리 만든다
    parent.add(m);
  }
  let boxList = [], discList = [];
  let shown = { order: 0, reject: 0, exec: 0 };
  const o = new THREE.Object3D();

  function ingest() {
    S.orders.splice(0).forEach(r => {
      const s = STOCK_IDX[r.asset];
      if (s == null) return;
      const kind = r.status === 'rejected' ? 'reject' : 'order';
      boxList.push({ kind, t0: r.t0, dur: r.dur, path: pathOf(kind, r.house, s), color: kind === 'reject' ? rejectColor : colorOf.get(r.asset) });
    });
    S.execs.splice(0).forEach(r => {
      const s = STOCK_IDX[r.asset];
      if (s == null) return;
      discList.push({ kind: 'exec', t0: r.t0, dur: r.dur, path: pathOf('exec', r.id, s), color: colorOf.get(r.asset) });
    });
    if (boxList.length > CAP) boxList = boxList.slice(boxList.length - CAP);
    if (discList.length > CAP) discList = discList.slice(discList.length - CAP);
  }

  function place(mesh, list, P, y0, hop) {
    let n = 0;
    const counts = { order: 0, reject: 0, exec: 0 };
    for (const k of list) {
      const u = (P - k.t0) / k.dur;
      if (!(u >= 0 && u <= 1)) continue;
      const p = at(k.path, u * k.path.len);
      o.position.set(p[0], FLOOR + y0 + Math.sin(u * Math.PI) * hop, p[1]);
      o.updateMatrix();
      mesh.setMatrixAt(n, o.matrix);
      mesh.setColorAt(n, k.color);
      counts[k.kind]++; n++;
    }
    mesh.count = n;
    mesh.instanceMatrix.needsUpdate = true;
    if (mesh.instanceColor) mesh.instanceColor.needsUpdate = true;
    return counts;
  }

  // P: 재생 시각(시장 ms) 또는 null
  function tick(P) {
    ingest();
    if (P == null) { boxes.count = discs.count = 0; shown = { order: 0, reject: 0, exec: 0 }; return; }
    boxList = boxList.filter(k => (P - k.t0) / k.dur < 1.5);   // 다 난 토큰은 치운다
    discList = discList.filter(k => (P - k.t0) / k.dur < 1.5);
    const a = place(boxes, boxList, P, .2, .25), b = place(discs, discList, P, .12, .15);
    shown = { order: a.order, reject: a.reject, exec: b.exec };
  }

  return { tick, state: () => ({ ...shown }) };
}
