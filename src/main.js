// 부팅: sprites.json 을 읽고, 풀블리드 캔버스·오버레이(HUD·Inspect·말풍선·명판)·씬을 만들고, state.js 구독으로 잇는다.
// 선택의 원본은 여기 selectedId 하나다. 캔버스 클릭 → onSelect, 고장 칩 → scene.select 로 한 방향씩만 알린다.
// 월드(캔버스 px) → 화면(px) 변환은 toScreen 한 곳이다. 캔버스는 뷰포트 한가운데에 놓이고 카메라는 고정·줌 없음.
import * as store from './state.js';
import { FactoryScene } from './scene_factory.js';
import { machineRect } from './scene_draw.js';
import { createHud, createLabels } from './hud.js';
import { createInspect } from './inspect.js';
import { createBubble } from './bubble.js';
import { stressNext } from './fx.js';

const STRESS_MS = 3000;
const $ = (id) => document.getElementById(id);

async function boot() {
  const sprites = await (await fetch('data/sprites.json', { cache: 'no-store' })).json();
  const host = $('game');
  const tile = sprites.sheet.tile;
  const view = { zoom: 0, cell: 0, ox: 0, oy: 0 };
  let state = null;
  let selectedId = null;
  let game = null;

  const scene = new FactoryScene({ sprites, onSelect: (id) => setSelected(id, true) });
  const toScreen = (wx, wy) => ({ x: view.ox + wx, y: view.oy + wy });
  const machineOf = (id) => state && state.machines.find((m) => m.id === id);
  const anchorOf = (id) => {
    const m = machineOf(id);
    if (!m) return null;
    const r = machineRect(scene, m); // 월드 px. 칸 × 셀 크기에서 나온다
    return { ...toScreen(r.x, r.y), w: r.w, h: r.h };
  };

  const hud = createHud({ onPickBroken: (id) => setSelected(id, false) });
  const labels = createLabels($('labels'));
  const inspect = createInspect($('inspect'), $('inspect-hint'));
  const bubble = createBubble($('bubble'), { anchorOf });

  // 화면에 들어가는 최대 정수배. 배율이 바뀌면 씬이 칸 크기부터 다시 그린다.
  function measure() {
    const { grid } = state;
    const w = host.clientWidth;
    const h = host.clientHeight;
    const zoom = Math.max(1, Math.floor(Math.min(w / (grid.w * tile), h / (grid.h * tile))));
    const cell = tile * zoom;
    return { zoom, cell, ox: Math.max(0, Math.floor((w - grid.w * cell) / 2)), oy: Math.max(0, Math.floor((h - grid.h * cell) / 2)) };
  }

  // 리사이즈 때 재계산하는 유일한 곳: 배율·원점 → CSS 변수 → 캔버스 → 오버레이 위치
  function layout() {
    if (!state) return;
    const next = measure();
    const rezoom = next.zoom !== view.zoom;
    Object.assign(view, next);
    const root = document.documentElement.style;
    root.setProperty('--cell', `${view.cell}px`);
    root.setProperty('--ox', `${view.ox}px`);
    root.setProperty('--oy', `${view.oy}px`);
    sprites.scale = scene.zoom = view.zoom;
    scene.cell = view.cell;
    if (game) {
      if (rezoom) {
        scene.signature = ''; // 구조 서명을 비워 씬이 새 칸 크기로 다시 그리게 한다
        scene.applyState(scene.pending);
      }
      const cv = game.canvas;
      cv.style.width = `${state.grid.w * view.cell}px`;
      cv.style.height = `${state.grid.h * view.cell}px`;
      game.scale.refresh(); // NONE 모드는 표시 크기·위치를 스스로 다시 재지 않는다 → 입력 좌표 보정
    }
    placeOverlays();
  }

  function placeOverlays() {
    if (!state) return;
    labels.place({ cell: view.cell, toScreen, anchorOf });
    bubble.place();
  }

  function startGame(s) {
    state = s;
    layout(); // 첫 배율을 씬에 먼저 알린다
    game = new Phaser.Game({
      type: Phaser.AUTO,
      parent: 'game',
      width: s.grid.w * view.cell,
      height: s.grid.h * view.cell,
      transparent: true,
      pixelArt: true, // 보간 끔
      scale: { mode: Phaser.Scale.NONE }, // FIT 금지: 정수 배율 고정
      scene,
    });
    layout();
  }

  // 선택 바꾸기. fromCanvas: 씬이 이미 알고 있는 선택이면 true, 아니면 씬에도 알린다.
  function setSelected(id, fromCanvas) {
    selectedId = id;
    if (!fromCanvas) scene.select(id);
    renderOverlays();
  }

  function renderOverlays() {
    if (!state) return;
    if (selectedId && !machineOf(selectedId)) selectedId = null; // 새 상태에서 사라진 기계
    const m = selectedId ? machineOf(selectedId) : null;
    labels.update(state, selectedId);
    inspect.update(m || null, state);
    bubble.update(m || null);
    placeOverlays();
  }

  // 캔버스 밖(바닥·HUD 빈 곳)을 누르면 닫는다. 캔버스 안은 씬이, 말풍선·Inspect·칩은 자기가 처리한다.
  document.addEventListener('pointerdown', (e) => {
    if (selectedId && !e.target.closest('canvas, .bubble, .inspect, .alert-chip, .hud-user')) setSelected(null, false);
  });
  let queued = 0;
  window.addEventListener('resize', () => { // orientationchange 는 회전 전 값을 보므로 쓰지 않는다
    cancelAnimationFrame(queued);
    queued = requestAnimationFrame(layout);
  });

  const render = ({ state: s, error }) => {
    if (s && !game) startGame(s);
    else if (s) state = s;
    hud.update(s, error);
    if (!s) return;
    scene.applyState(s);
    renderOverlays();
  };

  // ?stress=1: 서버 응답은 첫 번째(배치·기계 목록)만 쓰고, 이후 3초마다 화면 안에서 만든 상태로 바꾼다. API 호출 없음.
  if (new URLSearchParams(location.search).get('stress') === '1') {
    let current = null;
    store.subscribe((ev) => {
      if (current || !ev.state) return;
      current = ev.state;
      store.stop(); // 첫 응답만 받고 폴링을 멈춘다
      render(ev);
      setInterval(() => {
        current = stressNext(current);
        render({ state: current, error: false });
      }, STRESS_MS);
    });
    store.start();
  } else {
    store.subscribe(render);
    store.start();
  }
}

boot();
