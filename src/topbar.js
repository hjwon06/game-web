// 상단 바. 공장 이름은 index.html 에 고정이고, 여기서는 연결 칩과 마지막 성공 시각을 채운다.
// 실패하면 state 는 마지막 성공 값 그대로 오므로 updated_at 이 곧 마지막 성공 시각이다.
import { formatTime } from './format.js';

export function renderTopbar(root, state, error) {
  const chip = root.querySelector('#topbar-link');
  const slot = root.querySelector('#topbar-updated');
  if (chip) {
    chip.textContent = error ? '연결 끊김' : '실시간';
    chip.classList.toggle('chip-live', !error);
    chip.classList.toggle('chip-off', Boolean(error));
  }
  if (slot) slot.textContent = state ? `갱신 ${formatTime(state.updated_at)}` : '';
}
