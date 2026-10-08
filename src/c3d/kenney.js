// Kenney CC0 GLB(트럭·단지 장식) 로드·캐시. 로드는 비동기, 로드 후 truck() 은 동기로 clone 한다.
import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { boxGeo } from './models.js';

const ROOT = '/assets/3d/kenney/';
const loader = new GLTFLoader();
const cache = new Map(); // path → Promise<THREE.Group>

function load(path) {
  if (!cache.has(path)) cache.set(path, loader.loadAsync(ROOT + path + '.glb').then(g => g.scene));
  return cache.get(path);
}
const loaded = path => cache.get(path + '#done');

const TRUCKS = { truck: 'car/truck', delivery: 'car/delivery', flat: 'car/truck-flat' };
export const TRUCK_LEN = 2.95; // 원본 모델 길이(원본 bbox 1.5 × 2.95 × 1.15)
// 모델의 앞쪽이 +z 라고 가정한다. 반대로 나오면 이 값을 -1 로.
const FRONT = 1;

export async function loadTrucks() {
  await Promise.all(Object.values(TRUCKS).map(async p => { cache.set(p + '#done', await load(p)); }));
}

function castAll(o) { o.traverse(c => { if (c.isMesh) { c.castShadow = true; c.receiveShadow = true; } }); }

// kind: 'truck' | 'delivery' | 'flat'. trailerColor: 짐칸 덮개 색(없으면 만들지 않는다)
// 원본은 팔레트 텍스처 한 장짜리 단일 메시라 짐칸만 따로 칠할 수 없다 → 뒤쪽 절반에 자기 재질의 짐칸 상자를 얹는다.
export function truck(kind = 'truck', trailerColor = 0xE5E7EB) {
  const src = loaded(TRUCKS[kind] || TRUCKS.truck);
  if (!src) throw new Error('loadTrucks() 가 먼저 끝나야 한다');
  const g = new THREE.Group();
  g.name = 'truck';
  const body = src.clone(true);
  castAll(body);
  g.add(body);
  const flat = kind === 'flat';
  const h = flat ? .3 : kind === 'delivery' ? .8 : .95;
  const trailer = new THREE.Mesh(boxGeo(1.4, h, 1.55), new THREE.MeshStandardMaterial({ color: trailerColor, roughness: .8 }));
  trailer.name = 'trailer';
  trailer.castShadow = trailer.receiveShadow = true;
  trailer.position.set(0, (flat ? .4 : .35) + h / 2, -FRONT * .65);
  g.add(trailer);
  g.userData.trailer = trailer;
  g.userData.kind = kind;
  return g;
}
export function setTrailerColor(t, color) { t.userData.trailer.material.color.set(color); }

// 단지 장식: [파일, 목표 높이(최대 치수 기준 아님), x, z, 회전y]
const DECOR = [
  ['industrial/detail-tank', 2.4, 34.9, 4.6, 0],
  ['industrial/detail-tank-large', 3.2, 43.6, 4.2, 0],
  ['industrial/water-tower', 4.6, 35.2, 9.6, 0],
  ['industrial/shipping-container-a', 1.0, 29.6, 9.7, 0],
  ['industrial/shipping-container-b', 1.0, 32.0, 9.7, 0],
  ['industrial/shipping-container-c', 1.0, 39.6, 9.2, Math.PI / 2],
];

// 장식 모델을 group 에 붙인다. 목표 높이에 맞춰 스케일하고 바닥(y=0)에 붙인다.
export async function addDecor(group) {
  const items = await Promise.all(DECOR.map(async ([p, hgt, x, z, ry]) => {
    const m = (await load(p)).clone(true);
    castAll(m);
    const bb = new THREE.Box3().setFromObject(m), s = hgt / (bb.max.y - bb.min.y);
    m.scale.setScalar(s);
    const b2 = new THREE.Box3().setFromObject(m), c = b2.getCenter(new THREE.Vector3());
    m.position.set(-c.x, -b2.min.y, -c.z);
    const wrap = new THREE.Group();
    wrap.name = 'decor';
    wrap.rotation.y = ry;
    wrap.position.set(x, 0, z);
    wrap.add(m);
    return wrap;
  }));
  items.forEach(w => group.add(w));
  return items;
}
