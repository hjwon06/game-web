// 상단 바. 공장 이름과 "샘플 데이터" 칩은 index.html 에 고정이고, 여기서는 갱신 시각만 채운다.
import { formatTime } from './format.js';

export function renderTopbar(root, state) {
  const slot = root.querySelector('#topbar-updated');
  if (!slot || !state) return;
  slot.textContent = `갱신 ${formatTime(state.updated_at)}`;
}
