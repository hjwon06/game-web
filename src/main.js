// 부팅: sprites.json 을 읽고, 상단 바·패널·씬을 만들고, state.js 구독으로 잇는다.
// 선택은 한 방향씩만 전달한다: 캔버스 클릭 → panel.select, 목록 클릭 → scene.select.
// 두 select() 는 바깥으로 되알리지 않으므로 호출 고리가 생기지 않는다.
import * as store from './state.js';
import { FactoryScene } from './scene_factory.js';
import { createPanel } from './panel.js';
import { exposeTiles } from './panel_detail.js';
import { renderTopbar } from './topbar.js';
import { stressNext } from './fx.js';

const STRESS_MS = 3000;

async function boot() {
  const sprites = await (await fetch('data/sprites.json', { cache: 'no-store' })).json();
  exposeTiles(sprites);
  const topbar = document.getElementById('topbar');
  let scene = null;
  const panel = createPanel(document.getElementById('panel'), { onSelect: (id) => scene.select(id) });
  scene = new FactoryScene({ sprites, onSelect: (id) => panel.select(id) });

  let game = null;
  const startGame = (state) => {
    const cell = sprites.sheet.tile * sprites.scale;
    const { grid } = state;
    game = new Phaser.Game({
      type: Phaser.AUTO,
      parent: 'game',
      width: grid.w * cell,
      height: grid.h * cell,
      transparent: true,
      pixelArt: true, // 보간 끔
      scale: { mode: Phaser.Scale.NONE }, // FIT 금지: 정수 배율(타일 32px x 2) 고정
      scene,
    });
    fitCanvas(game);
    addZoneLabels(document.getElementById('game'), state);
  };

  // 구역 이름표는 캔버스 글자 대신 DOM 으로 얹는다(표시 배율이 바뀌어도 글자가 뭉개지지 않는다). 위치는 layout.json 의 칸 좌표.
  function addZoneLabels(host, state) {
    state.zones.forEach((z, i) => {
      const tag = document.createElement('span');
      tag.className = 'zone-label';
      const no = document.createElement('b');
      no.className = 'zone-no num';
      no.textContent = String(i + 1).padStart(2, '0');
      tag.append(no, z.name);
      tag.style.left = `${(z.label.x / state.grid.w) * 100}%`;
      tag.style.top = `${(z.label.y / state.grid.h) * 100}%`;
      host.appendChild(tag);
    });
  }

  // 내부 해상도는 그대로 두고 CSS 표시 크기만 바꾼다. 폭 상한은 없다: .stage-col 이 왼쪽 열 폭과
  // 남은 높이로 폭을 정하고, 여기서는 그 폭을 꽉 채워 grid 비율을 유지한다(확대 시 pixelated).
  // NONE 모드의 Phaser 는 표시 크기를 스스로 다시 재지 않으므로, 크기가 바뀔 때마다 refresh() 로 입력 좌표 보정값(displayScale)을 갱신한다.
  function fitCanvas(g) {
    const host = document.getElementById('game');
    const w = g.config.width; // grid.w × cell (17×64 = 1088)
    const h = g.config.height; // grid.h × cell (8×64 = 512)
    host.style.width = '100%';
    host.style.height = 'auto';
    host.style.aspectRatio = `${w} / ${h}`;
    const cv = g.canvas;
    cv.style.width = '100%';
    cv.style.height = '100%';
    cv.style.imageRendering = 'pixelated';
    const refresh = () => g.scale.refresh();
    window.addEventListener('resize', refresh);
    new ResizeObserver(refresh).observe(host);
    refresh();
  }

  const render = ({ state, error }) => {
    if (state && !game) startGame(state);
    renderTopbar(topbar, state, error);
    if (state) scene.applyState(state);
    panel.update(state, error);
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
