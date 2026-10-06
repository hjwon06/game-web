// 패널의 선택 상세와 Kenney 아이콘 자르기. 서버·JSON 문자열은 전부 textContent 로만 넣는다.
import { incomingBelts } from './format.js';

export const STATE_LABEL = { running: '가동', stopped: '정지', defect: '불량' };

export const stateLabel = (s) => STATE_LABEL[s] ?? String(s);
export const fmt = (n) => Number(n).toLocaleString('ko-KR');

export function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

// 시트 규격과 타일 칸 위치를 CSS 변수로 내보낸다. 타일 번호는 sprites.json 에서만 온다.
export function exposeTiles(sprites) {
  const { file, cols, rows } = sprites.sheet;
  const root = document.documentElement.style;
  root.setProperty('--sheet-url', `url("${file}")`);
  root.setProperty('--sheet-cols', String(cols));
  root.setProperty('--sheet-rows', String(rows));
  const put = (name, frame) => {
    root.setProperty(`--tc-${name}`, String(frame % cols));
    root.setProperty(`--tr-${name}`, String(Math.floor(frame / cols)));
  };
  Object.entries(sprites.tiles.machine).forEach(([color, frame]) => put(color, frame));
  put('box', sprites.tiles.box);
}

export function renderDetail(section, state, machine) {
  if (!machine) {
    section.className = 'panel-section';
    section.replaceChildren(el('p', 'detail-empty', '기계를 누르면 상세가 여기에 나옵니다'));
    return;
  }
  section.className = 'panel-section machine-detail';
  const icon = el('i', 'tile-icon');
  icon.setAttribute('aria-hidden', 'true');
  icon.style.setProperty('--tc', `var(--tc-${machine.color})`);
  icon.style.setProperty('--tr', `var(--tr-${machine.color})`);
  const head = el('div', 'detail-head');
  head.append(icon, el('h3', 'detail-name', machine.name));

  const table = el('div', 'detail-table');
  const rows = [
    ['상태', stateLabel(machine.state), `state-${machine.state}`],
    ['처리 수량', fmt(machine.processed), 'num'],
    ['위치', `x ${machine.x}, y ${machine.y}`, 'num'],
    ['들어오는 벨트 수', String(incomingBelts(state, machine.id)), 'num'],
  ];
  rows.forEach(([k, v, cls]) => {
    const row = el('div', 'detail-row');
    row.append(el('span', 'detail-label', k), el('span', `detail-value ${cls}`, v));
    table.append(row);
  });
  section.replaceChildren(head, table);
}
