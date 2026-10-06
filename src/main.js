// 부팅: sprites.json 을 읽고, 패널과 씬을 만들고, state.js 구독으로 연결한다.
// Phaser.Game 은 factory.json 을 처음 받은 뒤(grid 를 안 뒤)에 만든다.
import * as store from './state.js';
import { FactoryScene } from './scene_factory.js';
import { createPanel } from './panel.js';

async function boot() {
  const sprites = await (await fetch('data/sprites.json', { cache: 'no-store' })).json();
  const panel = createPanel(document.getElementById('panel'));
  const scene = new FactoryScene({ sprites, onSelect: (id) => panel.select(id) });
  panel.onDeselect(() => scene.select(null));

  let game = null;
  const startGame = (grid) => {
    const cell = sprites.sheet.tile * sprites.scale;
    game = new Phaser.Game({
      type: Phaser.AUTO,
      parent: 'game',
      width: grid.w * cell,
      height: grid.h * cell,
      backgroundColor: '#F2F3F5',
      pixelArt: true,
      scale: { mode: Phaser.Scale.FIT, autoCenter: Phaser.Scale.CENTER_BOTH },
      scene,
    });
  };

  store.subscribe(({ state, error }) => {
    if (state && !game) startGame(state.grid);
    if (state) scene.applyState(state);
    panel.update(state, error);
  });
  store.start();
}

boot();
