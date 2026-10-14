// 거래소 안 종목 칸 상자 더미. 칸마다 상자 = ceil(open_orders / 5), 최대 40(2 × 5 × 4층). 종목 색.
// board 가 바뀔 때(S.ver)만 다시 채운다.
import * as THREE from 'three';
import { boxGeo, mat } from '../c3d/models.js';
import { S } from './data.js';
import { STOCKS, EX, BOX } from './layout.js';

export const boxesFor = open => Math.min(BOX.max, Math.ceil(Math.max(0, open || 0) / 5));

export function createPiles(parent) {
  const white = new THREE.MeshStandardMaterial({ color: 0xFFFFFF, roughness: .8 });
  const mesh = new THREE.InstancedMesh(boxGeo(BOX.w, BOX.h, BOX.w), white, STOCKS.length * BOX.max);
  mesh.name = 'piles'; mesh.count = 0; mesh.castShadow = mesh.receiveShadow = true; mesh.frustumCulled = false;
  mesh.setColorAt(0, new THREE.Color(0xFFFFFF));
  parent.add(mesh);
  // 칸 바닥(종목 색을 옅게 깐 판)
  STOCKS.forEach((s, i) => {
    const pad = new THREE.Mesh(boxGeo(1.1, .03, 2.7), mat(new THREE.Color(s.color).lerp(new THREE.Color(0xFFFFFF), .7).getHex(), .95));
    pad.position.set(EX.slotX[i], .09, EX.pileZ0 + 4 * BOX.pitchZ / 2);
    pad.receiveShadow = true;
    parent.add(pad);
  });
  const o = new THREE.Object3D(), col = STOCKS.map(s => new THREE.Color(s.color));
  let ver = -1, counts = Object.fromEntries(STOCKS.map(s => [s.code, 0]));

  function refill() {
    let n = 0;
    counts = {};
    STOCKS.forEach((s, i) => {
      const row = S.board.find(r => r.code === s.code), k = boxesFor(row && row.open_orders);
      counts[s.code] = k;
      for (let j = 0; j < k; j++) {
        const layer = Math.floor(j / BOX.perLayer), m = j % BOX.perLayer;
        o.position.set(EX.slotX[i] + (m % 2 ? .5 : -.5) * BOX.pitchX, .11 + BOX.h / 2 + layer * BOX.h,
          EX.pileZ0 + Math.floor(m / 2) * BOX.pitchZ);
        o.updateMatrix();
        mesh.setMatrixAt(n, o.matrix);
        mesh.setColorAt(n, col[i]);
        n++;
      }
    });
    mesh.count = n;
    mesh.instanceMatrix.needsUpdate = true;
    if (mesh.instanceColor) mesh.instanceColor.needsUpdate = true;
  }

  return {
    tick() { if (ver !== S.ver) { ver = S.ver; refill(); } },
    state: () => ({ ...counts }),
  };
}
