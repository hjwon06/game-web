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
  };

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
