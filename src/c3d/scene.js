import * as THREE from 'three';
import { CENTER, GW, GH } from './layout.js';

export const BG = 0xEEF1F4;

export function createScene(canvas, { capture = false } = {}) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, preserveDrawingBuffer: capture });
  renderer.setPixelRatio(Math.min(2, window.devicePixelRatio || 1));
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;

  const scene = new THREE.Scene();
  scene.background = new THREE.Color(BG);

  renderer.localClippingEnabled = true; // 도크 셔터가 문틀 위에서 잘린다

  const camera = new THREE.PerspectiveCamera(35, 1, 1, 600);

  scene.add(new THREE.HemisphereLight(0xFFFFFF, 0xC9D2C8, 1.1));

  const sun = new THREE.DirectionalLight(0xFFFFFF, 1.6);
  sun.position.set(CENTER.x - 25, 60, CENTER.z - 15);
  sun.target.position.set(CENTER.x, 0, CENTER.z);
  sun.castShadow = true;
  sun.shadow.mapSize.set(4096, 4096);
  const sc = sun.shadow.camera; // 단지 전체(46x34, 대각 약 57)를 덮는다
  sc.left = -36; sc.right = 36; sc.top = 36; sc.bottom = -36; sc.near = 5; sc.far = 160;
  sun.shadow.bias = -0.0004;
  sun.shadow.normalBias = 0.05;
  scene.add(sun, sun.target);

  function resize() {
    const w = window.innerWidth, h = window.innerHeight;
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
  }

  return { renderer, scene, camera, sun, resize };
}

// 첫 화면 구도: 남쪽에서 살짝 비스듬히(방위 15°), 극각 55°. 단지(바닥 판 + 건물 높이)가 화면 폭의 ~86% 를 채우는 거리를 찾는다.
// 세로로 넘치면(가로가 넓은 화면의 반대: 좁고 긴 화면) 높이 96% 에서 멈춘다.
export const VIEW = { azimuth: 15, polar: 55, fillW: .86, fillH: .96 };
export function fitCampus(camera, target) {
  const az = THREE.MathUtils.degToRad(VIEW.azimuth), po = THREE.MathUtils.degToRad(VIEW.polar);
  const dir = new THREE.Vector3(Math.sin(po) * Math.sin(az), Math.cos(po), Math.sin(po) * Math.cos(az));
  const corners = [];
  for (const x of [-.5, GW + .5]) for (const z of [-.5, GH + .5]) for (const y of [-.4, 8]) corners.push(new THREE.Vector3(x, y, z));
  const extent = d => {
    camera.position.copy(target).addScaledVector(dir, d);
    camera.lookAt(target);
    camera.updateMatrixWorld(true);
    let x0 = 9, x1 = -9, y0 = 9, y1 = -9;
    for (const c of corners) {
      const p = c.clone().project(camera);
      x0 = Math.min(x0, p.x); x1 = Math.max(x1, p.x); y0 = Math.min(y0, p.y); y1 = Math.max(y1, p.y);
    }
    return { w: (x1 - x0) / 2, h: (y1 - y0) / 2 };
  };
  let lo = 15, hi = 300; // 거리가 멀수록 작아진다: 폭 ≤ fillW 이고 높이 ≤ fillH 를 만족하는 가장 가까운 거리
  for (let i = 0; i < 30; i++) {
    const mid = (lo + hi) / 2, e = extent(mid);
    if (e.w > VIEW.fillW || e.h > VIEW.fillH) lo = mid; else hi = mid;
  }
  extent(hi);
  return hi;
}
