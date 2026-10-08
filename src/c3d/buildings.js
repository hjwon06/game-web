import * as THREE from 'three';
import { BUILDINGS, OPEN_WALL } from './layout.js';

export const BLUE = 0x2563EB;

const wall = new THREE.MeshStandardMaterial({ color: 0xF8FAFC, roughness: .9 });
const band = new THREE.MeshStandardMaterial({ color: BLUE, roughness: .7 });

function add(g, w, h, d, x, y, z, m) {
  const mesh = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), m);
  mesh.position.set(x, y, z);
  mesh.castShadow = mesh.receiveShadow = true;
  g.add(mesh);
}

// 지붕 없는 건물: 바닥 위에 벽 네 면만 세우고 윗단에 블루 띠를 두른다(내부가 보인다)
function openShell(g, b) {
  const t = .2, h = OPEN_WALL;
  add(g, b.w, h, t, 0, h / 2, -b.d / 2 + t / 2, wall); // 북
  add(g, b.w, h, t, 0, h / 2, b.d / 2 - t / 2, wall);  // 남(도크 문이 붙는다)
  add(g, t, h, b.d - 2 * t, -b.w / 2 + t / 2, h / 2, 0, wall);
  add(g, t, h, b.d - 2 * t, b.w / 2 - t / 2, h / 2, 0, wall);
  // 윗단 블루 띠(테두리 네 줄 — 가운데는 비워 둔다)
  const r = .16, y = h + r / 2;
  add(g, b.w + .06, r, t + .06, 0, y, -b.d / 2 + t / 2, band);
  add(g, b.w + .06, r, t + .06, 0, y, b.d / 2 - t / 2, band);
  add(g, t + .06, r, b.d - 2 * t, -b.w / 2 + t / 2, y, 0, band);
  add(g, t + .06, r, b.d - 2 * t, b.w / 2 - t / 2, y, 0, band);
}

export function createBuildings() {
  const group = new THREE.Group();
  group.name = 'buildings';

  BUILDINGS.forEach(b => {
    const g = new THREE.Group();
    g.name = b.id;
    g.position.set(b.x + b.w / 2, 0, b.y + b.d / 2);
    g.userData = { id: b.id, name: b.name, real: b.real, api: b.api || null, kind: 'building', open: !!b.open };

    if (b.open) { openShell(g, b); group.add(g); return; }

    const body = new THREE.Mesh(new THREE.BoxGeometry(b.w, b.h, b.d), wall);
    body.position.y = b.h / 2;
    body.castShadow = body.receiveShadow = true;
    g.add(body);

    // 블루 띠: 벽 중간 높이를 한 바퀴 두른다
    const bh = Math.min(.5, b.h * .14);
    const stripe = new THREE.Mesh(new THREE.BoxGeometry(b.w + .06, bh, b.d + .06), band);
    stripe.position.y = b.h * .62;
    stripe.castShadow = stripe.receiveShadow = true;
    g.add(stripe);

    // 옥상 가장자리
    const roof = new THREE.Mesh(new THREE.BoxGeometry(b.w + .12, .12, b.d + .12), new THREE.MeshStandardMaterial({ color: new THREE.Color(b.top), roughness: .9 }));
    roof.position.y = b.h + .06;
    roof.castShadow = roof.receiveShadow = true;
    g.add(roof);

    group.add(g);
  });

  return group;
}
