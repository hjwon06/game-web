// 3D-③ 재고·기계 연결: 칸 팔레트(서버 bins) · 기계 램프(/api/hud) · 라인사이드 팔레트.
// 칸에 보이는 값은 S.shown 이다 — 그 칸으로 가는 지게차가 닿은 순간에만 바뀐다(data.js).
import * as THREE from 'three';
import { S, MS, dataReady, itemColor } from './data.js';
import { palletGeo, mat, WOOD, setLamp } from './models.js';
import { binSlots, machines, linesideSpots } from './campus.js';

const PER_PALLET = 500, MAX_PALLETS = 4, BLINK_MS = 450, PAL_Y = .095;

// 팔레트 InstancedMesh 한 벌(바닥 deck + 품목색 상자). 개수가 바뀌어도 같은 메시를 재사용한다
function palletSet(parent, capacity) {
  const deck = new THREE.InstancedMesh(palletGeo.deck, mat(WOOD, .9), capacity);
  const boxes = new THREE.InstancedMesh(palletGeo.stack, mat(0xFFFFFF, .85), capacity);
  const o = new THREE.Object3D(), c = new THREE.Color();
  for (const m of [deck, boxes]) { m.castShadow = m.receiveShadow = true; m.frustumCulled = false; m.count = 0; parent.add(m); } // 개수가 바뀌므로 경계구가 낡는다
  return {
    fill(items) { // items: [[Vector3|{x,y,z}, 색 문자열]]
      items.slice(0, capacity).forEach(([p, color], n) => {
        o.position.set(p.x, p.y, p.z); o.updateMatrix();
        deck.setMatrixAt(n, o.matrix); boxes.setMatrixAt(n, o.matrix); boxes.setColorAt(n, c.set(color));
      });
      deck.count = boxes.count = Math.min(items.length, capacity);
      deck.instanceMatrix.needsUpdate = boxes.instanceMatrix.needsUpdate = true;
      if (boxes.instanceColor) boxes.instanceColor.needsUpdate = true;
    },
    get count() { return deck.count; },
  };
}

export function createStock(parent) {
  const codes = Object.keys(binSlots), bins = palletSet(parent, codes.length * MAX_PALLETS);
  const lcodes = Object.keys(linesideSpots), line = palletSet(parent, lcodes.length * MAX_PALLETS);
  let binVer = -1, lineSig = '';
  const lampSt = {};

  function tick(t) {
    if (!dataReady()) return;
    // L4 칸 팔레트: 수량/500 올림, 최대 4개
    if (binVer !== S.ver) {
      binVer = S.ver;
      const items = [];
      codes.forEach(code => {
        const sh = S.shown.get(code); if (!sh) return;
        const n = Math.min(MAX_PALLETS, Math.ceil(sh.qty / PER_PALLET));
        for (let j = 0; j < n; j++) items.push([binSlots[code][j], sh.color]);
      });
      bins.fill(items);
    }
    // L5 기계 램프: 상태색, 자재 대기(material_short)면 깜빡임
    MS.forEach((m, code) => {
      const obj = machines[code]; if (!obj) return;
      if (lampSt[code] !== m.st) { lampSt[code] = m.st; setLamp(obj, m.st); }
      obj.getObjectByName('lamp').visible = m.short == null || Math.floor(t / BLINK_MS) % 2 === 0;
    });
    // L5 라인사이드 팔레트 0~4: API 에 라인사이드 수량이 없어 작업지시 잔량 비율로 보인다(자재 대기면 0)
    const ns = lcodes.map(code => {
      const m = MS.get(code), wo = m && m.wo;
      if (!wo || m.short != null) return 0;
      const tg = Number(wo[3]) || 0, left = tg > 0 ? (tg - (Number(wo[2]) || 0)) / tg : 1;
      return Math.max(1, Math.min(MAX_PALLETS, Math.ceil(left * MAX_PALLETS)));
    });
    const sig = ns.join() + '|' + lcodes.map(c => (MS.get(c).wo || [])[1]).join();
    if (sig !== lineSig) {
      lineSig = sig;
      const items = [];
      lcodes.forEach((code, i) => {
        const sp = linesideSpots[code], color = itemColor((MS.get(code).wo || [])[1]);
        for (let k = 0; k < ns[i]; k++) items.push([{ x: sp.x + (k % 2 ? .35 : -.35), y: PAL_Y, z: sp.z + (k < 2 ? 0 : .65) * sp.sign }, color]);
      });
      line.fill(items);
    }
  }
  return { tick, state: () => ({ binPallets: bins.count, linePallets: line.count }) };
}
