import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { createScene } from './scene.js';
import { createGround } from './ground.js';
import { createBuildings } from './buildings.js';
import { CENTER } from './layout.js';

const capture = new URLSearchParams(location.search).get('capture') === '1';
const canvas = document.getElementById('c3d');
const { renderer, scene, camera, resize } = createScene(canvas, { capture });

scene.add(createGround(), createBuildings());

const controls = new OrbitControls(camera, canvas);
controls.target.set(CENTER.x, 0, CENTER.z);
controls.enableDamping = !capture; // 캡처에서는 step 마다 결과가 같아야 한다
controls.minPolarAngle = THREE.MathUtils.degToRad(25);
controls.maxPolarAngle = THREE.MathUtils.degToRad(70);
controls.minDistance = 25;
controls.maxDistance = 150;
controls.update();

// 시계 추상화: 기본은 performance.now(), ?capture=1 이면 step(ms) 로만 움직인다
const clock = capture
  ? (() => { let t = 0; return { now: () => t, advance: ms => { t += ms; } }; })()
  : { now: () => performance.now(), advance() {} };

// 다음 단계(애니메이션)가 매 프레임 불리는 곳에 붙는다: tick(now, dt)
const tickers = [];
let last = clock.now();
function frame(dt) {
  const now = clock.now();
  tickers.forEach(fn => fn(now, dt));
  controls.update();
  renderer.render(scene, camera);
  last = now;
}

function onResize() { resize(); frame(0); }
addEventListener('resize', onResize); // orientationchange 는 회전 전 값을 봐서 쓰지 않는다
resize();

if (capture) {
  window.__c3d = {
    step(ms = 16) { clock.advance(ms); frame(ms); return clock.now(); },
    now: () => clock.now(),
    scene, camera,
  };
  frame(0);
} else {
  (function loop() {
    requestAnimationFrame(loop);
    const dt = clock.now() - last;
    frame(dt);
  })();
}

export { tickers };
