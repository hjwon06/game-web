// 화면 카드 조립: main.js 가 만들고 frame 마다 tick(P) 을 부른다. 3D 장면은 건드리지 않는다.
import { buildDom } from './ui_dom.js';
import { model, summary } from './ui.js';

export function createUi(root) {
  const dom = buildDom(root);
  return {
    tick(P) { dom.render(model(P, Date.now())); },
    state(P) { return summary(model(P, Date.now())); }, // window.__s3d.ui()
  };
}
