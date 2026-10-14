// 증권 거리 3D 장면. 공장 main.js 와 같은 조립(createScene · createGround · OrbitControls · fitCampus)에 거리 요소를 얹는다.
// ?capture=1 이면 시계가 window.__s3d.step(ms) 로만 움직이고, 모든 위치는 시계의 함수라 step 크기와 무관하게 같은 state 가 나온다.
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { createScene, fitCampus } from '../c3d/scene.js';
import { createGround } from '../c3d/ground.js';
import { CENTER } from './layout.js';
import { createBuildings, createLabels } from './buildings.js';
import { initData, startPolling, apply, advance, playTime, isFrozen, S } from './data.js';
import { createFlow } from './flow.js';
import { createPiles } from './piles.js';
import { createTrucks } from './trucks.js';
import { createBoard } from './board.js';
import { createUi } from './ui_index.js';

const capture = new URLSearchParams(location.search).get('capture') === '1';
const canvas = document.getElementById('s3d');
const { renderer, scene, camera, resize } = createScene(canvas, { capture });

const street = new THREE.Group();
street.name = 'street';
scene.add(createGround(), createBuildings(), street);

const controls = new OrbitControls(camera, canvas);
controls.target.set(CENTER.x, 0, CENTER.z);
controls.enableDamping = !capture; // 캡처에서는 step 마다 결과가 같아야 한다
controls.minPolarAngle = THREE.MathUtils.degToRad(35);
controls.maxPolarAngle = THREE.MathUtils.degToRad(65);
controls.minDistance = 6;
controls.maxDistance = 220;

// 첫 구도: 사용자가 카메라를 만지기 전까지는 창 크기가 바뀔 때마다 다시 맞춘다.
let touched = false;
controls.addEventListener('start', () => { touched = true; });
function fit() { fitCampus(camera, controls.target); controls.update(); }

// 시계 추상화: 기본은 performance.now(), ?capture=1 이면 step(ms) 로만 움직인다
const clock = capture
  ? (() => { let t = 0; return { now: () => t, advance: ms => { t += ms; } }; })()
  : { now: () => performance.now(), advance() {} };
initData(clock.now);

const labels = createLabels(scene);
const flow = createFlow(street), piles = createPiles(street), trucks = createTrucks(street), board = createBoard(street);
const ui = createUi(document.getElementById('ui'));

function frame() {
  const P = playTime(clock.now());
  advance(P); // 쌓아 둔 board · settlements 중 재생 시각이 지난 것을 먼저 적용한다
  flow.tick(P); piles.tick(); trucks.tick(P); board.tick();
  ui.tick(P);
  controls.update();
  renderer.render(scene, camera);
  labels.render(scene, camera);
}

function onResize() { resize(); labels.resize(); if (!touched) fit(); frame(); }
addEventListener('resize', onResize); // orientationchange 는 회전 전 값을 봐서 쓰지 않는다
resize(); labels.resize(); fit();

// 삼각형 수: 장면 전체(InstancedMesh 는 보이는 인스턴스 수만큼) 합계
function countTriangles() {
  let n = 0;
  scene.traverse(o => {
    if (!o.isMesh || !o.visible) return;
    const g = o.geometry, t = (g.index ? g.index.count : g.attributes.position.count) / 3;
    n += t * (o.isInstancedMesh ? o.count : 1);
  });
  return Math.round(n);
}

const iso = ms => (ms == null ? null : new Date(ms).toISOString());
// 루미 검증용: {playback(ISO), frozen, running, board_time(ISO), phase, tokens:{order,reject,exec}, piles:{종목 코드: 상자 수}, trucks, triangles}
const state = () => {
  const P = playTime(clock.now());
  return {
    playback: iso(P), frozen: isFrozen(), running: P != null && !isFrozen(),
    board_time: iso(S.boardTime),
    phase: S.clock ? S.clock.phase : null,
    tokens: flow.state(), piles: piles.state(), trucks: trucks.state(), triangles: countTriangles(),
  };
};

if (capture) { // 실시간 폴링 없음: 기록한 응답을 feed 로 그 순간의 화면 시계에 넣는다
  window.__s3d = {
    step(ms = 16) { clock.advance(ms); frame(); return clock.now(); },
    feed(body) { apply(body, clock.now()); frame(); },
    now: () => clock.now(), scene, camera, state, ui: () => ui.state(playTime(clock.now())),
  };
  frame();
} else {
  startPolling();
  window.__s3d = { now: () => clock.now(), state, ui: () => ui.state(playTime(clock.now())) };
  (function loop() {
    requestAnimationFrame(loop);
    frame();
  })();
}
