// 패널의 선택 상세(상태·작업지시·진행 막대·조작 버튼)와 Kenney 아이콘 자르기.
// 서버·JSON 문자열은 전부 textContent 로만 넣는다. 숫자는 서버가 준 값만 보여준다.
import { sendCommand } from './commands.js';

export const STATE_LABEL = { running: '가동', stopped: '정지', broken: '고장' };

export const stateLabel = (s) => STATE_LABEL[s] ?? String(s);
export const fmt = (n) => Number(n).toLocaleString('ko-KR');

// 상태별로 보이는 버튼. 첫 번째가 주 버튼(액센트), 나머지는 보조(테두리만).
const ACTIONS = {
  running: [['stop', '정지'], ['break', '고장']],
  stopped: [['start', '가동'], ['break', '고장']],
  broken: [['repair', '수리']],
};
const RESULT_TEXT = {
  409: '다른 곳에서 먼저 바뀌었습니다. 최신 상태로 맞췄습니다',
  422: '지금 상태에서는 할 수 없는 조작입니다',
  0: '서버에 닿지 않습니다. 잠시 뒤 다시 눌러 주세요',
};
const RESULT_MS = 5000;

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

// 3초마다 상세가 다시 그려져도 "처리 중"과 결과 문구가 남도록 모듈이 들고 있는다.
const busy = new Set(); // 명령 진행 중인 기계 id
let notice = null; // { id, text, timer }
let view = null; // { section, machine } 마지막으로 그린 대상
let built = ''; // 마지막 구조 키. 같으면 값만 갱신한다(눌리는 중인 버튼을 지우지 않는다)

function workOrderText(wo) {
  return wo ? `${wo.code} · ${wo.product}` : '배정된 작업 없음';
}

function producedOf(m) {
  return m.work_order ? m.work_order.produced_qty : m.processed;
}

function buildTable(m) {
  const rows = [
    ['상태', 'state', stateLabel(m.state), `state-${m.state}`],
    ['작업지시', 'work_order', workOrderText(m.work_order), ''],
    ['생산 수량', 'produced', fmt(producedOf(m)), 'num'],
    ['최근 1분 생산', 'last_minute', fmt(m.last_minute_good ?? 0), 'num'],
    ['위치', 'pos', `x ${m.x}, y ${m.y}`, 'num'],
  ];
  const table = el('div', 'detail-table');
  rows.forEach(([k, field, v, cls]) => {
    const row = el('div', 'detail-row');
    const val = el('span', `detail-value ${cls}`.trim(), v);
    val.dataset.field = field;
    row.append(el('span', 'detail-label', k), val);
    table.append(row);
  });
  return table;
}

function buildProgress(m) {
  const wrap = el('div', 'progress');
  const bar = el('div', 'progress-bar');
  bar.setAttribute('role', 'progressbar');
  const fill = el('i', 'progress-fill');
  bar.append(fill);
  const label = el('span', 'progress-label num');
  label.dataset.field = 'progress';
  wrap.append(bar, label);
  paintProgress(wrap, m);
  return wrap;
}

function paintProgress(wrap, m) {
  const wo = m.work_order;
  const pct = wo && wo.target_qty > 0 ? Math.min(100, Math.round((wo.produced_qty / wo.target_qty) * 100)) : 0;
  wrap.querySelector('.progress-fill').style.width = `${pct}%`;
  wrap.querySelector('.progress-bar').setAttribute('aria-valuenow', String(pct));
  wrap.querySelector('.progress-label').textContent = wo ? `${fmt(wo.produced_qty)} / ${fmt(wo.target_qty)}` : '—';
}

function buildActions(m) {
  const box = el('div', 'cmd-actions');
  const working = busy.has(m.id);
  (ACTIONS[m.state] || []).forEach(([kind, label], i) => {
    const btn = el('button', `cmd-btn ${i === 0 ? 'cmd-primary' : 'cmd-secondary'}`, working ? '처리 중' : label);
    btn.type = 'button';
    btn.dataset.kind = kind;
    btn.disabled = working;
    btn.addEventListener('click', () => run(m.id, kind));
    box.append(btn);
  });
  return box;
}

function setNotice(id, text) {
  if (notice) clearTimeout(notice.timer);
  notice = text ? { id, text, timer: setTimeout(() => setNotice(null, ''), RESULT_MS) } : null;
  if (view) renderDetail(view.section, view.machine);
}

async function run(id, kind) {
  const m = view && view.machine && view.machine.id === id ? view.machine : null;
  if (!m || busy.has(id)) return;
  busy.add(id);
  setNotice(null, '');
  try {
    const res = await sendCommand(m, kind);
    const status = res && Number.isFinite(res.status) ? res.status : 0;
    busy.delete(id);
    setNotice(id, status === 200 ? '' : RESULT_TEXT[status] ?? RESULT_TEXT[422]);
  } catch {
    busy.delete(id);
    setNotice(id, RESULT_TEXT[0]);
  }
}

export function renderDetail(section, machine) {
  view = { section, machine };
  if (!machine) {
    built = '';
    section.className = 'panel-section';
    section.replaceChildren(el('p', 'detail-empty', '기계를 누르면 상세가 여기에 나옵니다'));
    return;
  }
  const msg = notice && notice.id === machine.id ? notice.text : '';
  const key = [machine.id, machine.state, busy.has(machine.id), msg].join('|');
  if (key === built && section.classList.contains('machine-detail')) {
    // 구조는 그대로, 값만 바꾼다.
    section.querySelector('[data-field="work_order"]').textContent = workOrderText(machine.work_order);
    section.querySelector('[data-field="produced"]').textContent = fmt(producedOf(machine));
    section.querySelector('[data-field="last_minute"]').textContent = fmt(machine.last_minute_good ?? 0);
    section.querySelector('[data-field="pos"]').textContent = `x ${machine.x}, y ${machine.y}`;
    paintProgress(section.querySelector('.progress'), machine);
    return;
  }
  built = key;
  section.className = 'panel-section machine-detail';
  const icon = el('i', 'tile-icon');
  icon.setAttribute('aria-hidden', 'true');
  icon.style.setProperty('--tc', `var(--tc-${machine.color})`);
  icon.style.setProperty('--tr', `var(--tr-${machine.color})`);
  const head = el('div', 'detail-head');
  head.append(icon, el('h3', 'detail-name', machine.name));
  const result = el('p', 'cmd-result', msg);
  result.setAttribute('role', 'status');
  section.replaceChildren(head, buildTable(machine), buildProgress(machine), buildActions(machine), result);
}
