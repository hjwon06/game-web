import * as THREE from 'three';
import { BUILDINGS, DOCKS } from './layout.js';

export const BLUE = 0x2563EB;

const wall = new THREE.MeshStandardMaterial({ color: 0xF8FAFC, roughness: .9 });
const band = new THREE.MeshStandardMaterial({ color: BLUE, roughness: .7 });
const door = new THREE.MeshStandardMaterial({ color: 0x1A1A2E, roughness: .6 });

export function createBuildings() {
  const group = new THREE.Group();
  group.name = 'buildings';

  BUILDINGS.forEach(b => {
    const g = new THREE.Group();
    g.name = b.id;
    g.position.set(b.x + b.w / 2, 0, b.y + b.d / 2);
    g.userData = { id: b.id, name: b.name, real: b.real, api: b.api || null, kind: 'building' };

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

  // 도크 문 자리 표시(문 모델은 3D-②): 남쪽 면에 어두운 판
  DOCKS.forEach(d => {
    const b = BUILDINGS.find(x => x.id === d.building);
    const host = group.getObjectByName(d.building);
    d.slots.forEach(s => {
      const m = new THREE.Mesh(new THREE.PlaneGeometry(s.w, Math.min(2.4, b.h * .6)), door);
      const h = Math.min(2.4, b.h * .6);
      m.position.set(s.x + s.w / 2 - host.position.x, h / 2, b.d / 2 + .08);
      m.name = 'dock-door';
      host.add(m);
    });
  });

  return group;
}
