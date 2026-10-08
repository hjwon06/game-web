import * as THREE from 'three';
import { CENTER } from './layout.js';

export const BG = 0xEEF1F4;

export function createScene(canvas, { capture = false } = {}) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, preserveDrawingBuffer: capture });
  renderer.setPixelRatio(Math.min(2, window.devicePixelRatio || 1));
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;

  const scene = new THREE.Scene();
  scene.background = new THREE.Color(BG);

  // 단지 대각선(+x, +z 모서리 쪽) 위에서 내려다본다
  const camera = new THREE.PerspectiveCamera(35, 1, 1, 600);
  camera.position.set(CENTER.x + 55, 55, CENTER.z + 55);
  camera.lookAt(CENTER.x, 0, CENTER.z);

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
