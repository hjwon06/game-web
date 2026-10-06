// 부팅: sprites.json 을 읽고, 상단 바·패널·씬을 만들고, state.js 구독으로 잇는다.
// 선택은 한 방향씩만 전달한다: 캔버스 클릭 → panel.select, 목록 클릭 → scene.select.
// 두 select() 는 바깥으로 되알리지 않으므로 호출 고리가 생기지 않는다.
import * as store from './state.js';
import { FactoryScene } from './scene_factory.js';
import { createPanel } from './panel.js';
import { exposeTiles } from './panel_detail.js';
import { renderTopbar } from './topbar.js';

async function boot() {
  const sprites = await (await fetch('data/sprites.json', { cache: 'no-store' })).json();
  exposeTiles(sprites);
  const topbar = document.getElementById('topbar');
  let scene = null;
  const panel = createPanel(document.getElementById('panel'), { onSelect: (id) => scene.select(id) });
  scene = new FactoryScene({ sprites, onSelect: (id) => panel.select(id) });

  let game = null;
  const startGame = (grid) => {
    const cell = sprites.sheet.tile * sprites.scale;
    game = new Phaser.Game({
      type: Phaser.AUTO,
      parent: 'game',
      width: grid.w * cell,
      height: grid.h * cell,
      transparent: true,
      pixelArt: true,
      scale: { mode: Phaser.Scale.NONE }, // FIT 금지: 정수 배율(타일 16px x 3) 고정
      scene,
    });
    fitCanvas(game);
  };

  // 내부 해상도는 그대로 두고 CSS 표시 크기만 줄인다. NONE 모드의 Phaser 는 표시 크기를
  // 스스로 다시 재지 않으므로, 크기가 바뀔 때마다 refresh() 로 입력 좌표 보정값(displayScale)을 갱신한다.
  function fitCanvas(g) {
    const host = document.getElementById('game');
    host.style.width = 'min(768px, 100%)';
    host.style.height = 'auto';
    host.style.aspectRatio = '768 / 480';
    const cv = g.canvas;
    cv.style.width = '100%';
    cv.style.height = '100%';
    cv.style.imageRendering = 'pixelated';
    const refresh = () => g.scale.refresh();
    window.addEventListener('resize', refresh);
    new ResizeObserver(refresh).observe(host);
    refresh();
  }

  store.subscribe(({ state, error }) => {
    if (state && !game) startGame(state.grid);
    if (state) {
      renderTopbar(topbar, state);
      scene.applyState(state);
    }
    panel.update(state, error);
  });
  store.start();
}

boot();
