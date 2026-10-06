// 부팅: sprites.json 을 읽고, Phaser 씬과 패널을 만들고, state.js 구독으로 둘을 연결한다.
// state.js 가 listener(factory, status) 로 부른다고 가정한다 (status.error 가 참이면 읽기 실패).
import * as store from './state.js';
import { FactoryScene } from './scene_factory.js';
import { createPanel } from './panel.js';

async function boot() {
  const sprites = await (await fetch('data/sprites.json', { cache: 'no-store' })).json();
  const panel = createPanel(document.getElementById('panel'));
  const scene = new FactoryScene({ sprites, onSelect: (id) => panel.select(id) });
  panel.onDeselect(() => scene.select(null));

  new Phaser.Game({
    type: Phaser.AUTO,
    parent: 'game',
    width: 14 * 48,
    height: 9 * 48,
    backgroundColor: '#F2F3F5',
    pixelArt: true,
    scale: { mode: Phaser.Scale.FIT, autoCenter: Phaser.Scale.CENTER_BOTH },
    scene,
  });

  const listener = (factory, status) => {
    const failed = Boolean(status && status.error);
    if (factory) scene.applyState(factory);
    panel.update(factory, failed);
  };
  const subscribe = store.subscribe ?? store.default?.subscribe;
  subscribe(listener);
  if (typeof store.start === 'function') store.start();
}

boot();
