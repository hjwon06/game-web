import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { createScene, fitCampus, VIEW } from './scene.js';
import { createGround } from './ground.js';
import { createBuildings } from './buildings.js';
import { createCampus, addKenneyParts, binSlots, dockSpots, machines } from './campus.js';
import { CENTER } from './layout.js';
import { initData, startPolling } from './data.js';
import { createHaul } from './haul.js';
import { createStock } from './stock.js';
import { createUi, OPS } from './ui.js';
import { createNav } from './nav.js';

const capture = new URLSearchParams(location.search).get('capture') === '1';
const canvas = document.getElementById('c3d');
const { renderer, scene, camera, resize } = createScene(canvas, { capture });

const campus = createCampus();
scene.add(createGround(), createBuildings(), campus);

const controls = new OrbitControls(camera, canvas);
controls.target.set(CENTER.x, 0, CENTER.z);
controls.enableDamping = !capture; // 캡처에서는 step 마다 결과가 같아야 한다
controls.minPolarAngle = THREE.MathUtils.degToRad(35);
controls.maxPolarAngle = THREE.MathUtils.degToRad(65);
controls.minDistance = 6; // 지게차·칸 앞까지 다가갈 수 있게(3D-⑥)
controls.maxDistance = 220;

// 첫 화면 구도. 사용자가 카메라를 만지기 전까지는 창 크기가 바뀔 때마다 다시 맞춘다.
let touched = false;
controls.addEventListener('start', () => { touched = true; });
function fit() {
  fitCampus(camera, controls.target);
  controls.update();
}

// 줌 버튼: 대상(target)을 향한 거리를 비율로 줄이고 늘린다(controls 의 min/maxDistance 로 자른다). 처음 위치는 첫 구도로 되돌리고 자동 맞춤을 다시 켠다.
export function zoomBy(factor) {
  const off = camera.position.clone().sub(controls.target);
  const d = THREE.MathUtils.clamp(off.length() * factor, controls.minDistance, controls.maxDistance);
  camera.position.copy(controls.target).addScaledVector(off.normalize(), d);
  controls.update();
}
export const zoomIn = () => zoomBy(1 / 1.25);
export const zoomOut = () => zoomBy(1.25);
export function resetView() {
  touched = false;
  controls.target.set(CENTER.x, 0, CENTER.z);
  fit();
}

// 시계 추상화: 기본은 performance.now(), ?capture=1 이면 step(ms) 로만 움직인다
const clock = capture
  ? (() => { let t = 0; return { now: () => t, advance: ms => { t += ms; } }; })()
  : { now: () => performance.now(), advance() {} };

// 다음 단계(애니메이션)가 매 프레임 불리는 곳에 붙는다: tick(now, dt)
const tickers = [];
let nav = null; // createNav 가 아래에서 채운다(frame/onResize 가 먼저 불려도 안전)
let last = clock.now();
function frame(dt) {
  const now = clock.now();
  tickers.forEach(fn => fn(now, dt));
  controls.update();
  renderer.render(scene, camera);
  if (nav) nav.render(); // 이름표(CSS2D)
  last = now;
}

function onResize() { resize(); if (nav) nav.resize(); if (!touched) fit(); frame(0); }
addEventListener('resize', onResize); // orientationchange 는 회전 전 값을 봐서 쓰지 않는다
resize();
fit();

// 삼각형 수: 장면 전체(InstancedMesh 는 인스턴스 수만큼) 합계를 한 번만 찍는다
function countTriangles() {
  let n = 0;
  scene.traverse(o => {
    if (!o.isMesh || !o.visible) return;
    const g = o.geometry, t = (g.index ? g.index.count : g.attributes.position.count) / 3;
    n += t * (o.isInstancedMesh ? o.count : 1);
  });
  return Math.round(n);
}

// 3D-③ 실시간 연결: 데이터(폴링·서버 시계) → 지게차·트럭·작업자(haul) · 칸/라인사이드 팔레트·기계 램프(stock)
initData(clock.now);
const ready = addKenneyParts(campus).then(() => {
  const tri = countTriangles();
  console.info(`[c3d] triangles ${tri} (budget 60000)`);
  if (capture) window.__c3d.triangles = tri;
  frame(0);
}, e => console.error('[c3d] kenney load failed', e));

const haul = createHaul(campus, { kenneyReady: ready, opsTrucks: () => (OPS.data && OPS.data.trucks) || [] });
const stock = createStock(campus);
// 3D-⑥ 조작: 키 비행 · 클릭 선택 · 추적 · 이름표 · 투어. 위치가 정해진 뒤(haul.tick 다음)에 돌아야 한다
nav = createNav({ scene, camera, controls, canvas, haul, now: clock.now, setTouched: v => { touched = v; } });
nav.resize();
tickers.push(haul.tick, stock.tick, nav.tick);
startPolling();
createUi({ zoomIn, zoomOut, home: nav.home }); // 3D-⑤ 관제 UI(별도 2초 폴링)
// 루미 검증용: {forks:[{code,task,pos}], trucks:[{code,state}], carriers:n} (+ 팔레트 수 등 보조 값)
const state = () => ({ ...haul.state(), stock: stock.state() });

if (capture) {
  window.__c3d = {
    step(ms = 16) { clock.advance(ms); frame(ms); return clock.now(); },
    now: () => clock.now(),
    scene, camera, ready, binSlots, dockSpots, machines, view: VIEW, state,
    camera: nav.camera, tour: nav.tour,
  };
  frame(0);
} else {
  window.__c3d = { now: () => clock.now(), state, camera: nav.camera, tour: nav.tour };
  (function loop() {
    requestAnimationFrame(loop);
    const dt = clock.now() - last;
    frame(dt);
  })();
}

export { tickers };
