// 오른쪽 패널: 요약 → 기계 목록 → 선택 상세. 받은 상태를 보여주기만 한다.
// onSelect 는 목록 행을 눌렀을 때만 부른다. select() 는 바깥(캔버스)에서 온 선택이라 되부르지 않는다.
import { summarize } from './format.js';
import { el, fmt, stateLabel, renderDetail } from './panel_detail.js';

export function createPanel(root, { onSelect }) {
  const summaryEl = root.querySelector('#panel-summary');
  const rowsEl = root.querySelector('#panel-rows');
  const detailEl = root.querySelector('#panel-detail');
  const errorEl = root.querySelector('#panel-error');
  let state = null;
  let selectedId = null;
  let rowKey = '';
  const rows = new Map(); // id -> { btn, dot, st, count }
  rowsEl.replaceChildren(el('p', 'muted', '상태를 불러오는 중입니다'));

  function renderSummary() {
    const s = summarize(state);
    const main = el('div', 'summary-main');
    main.append(el('span', 'summary-number', String(s.running)), el('span', 'summary-caption', `${s.total}대 중 가동`));
    const line = el('p', 'summary-line', `정지 ${s.stopped} · 불량 ${s.defect} · 처리 합계 ${fmt(s.processedSum)}개`);
    summaryEl.replaceChildren(main, line);
  }

  function pick(id) {
    selectedId = selectedId === id ? null : id; // 선택된 행을 다시 누르면 해제
    markSelected();
    renderSelected();
    onSelect(selectedId);
  }

  function buildRows() {
    const list = el('ul', 'machine-list');
    rows.clear();
    state.machines.forEach((m) => {
      const btn = el('button', 'machine-row');
      btn.type = 'button';
      btn.dataset.id = m.id;
      btn.addEventListener('click', () => pick(m.id));
      const dot = el('i', 'dot');
      dot.setAttribute('aria-hidden', 'true');
      const name = el('span', 'machine-name', m.name);
      const st = el('span', 'machine-state');
      const count = el('span', 'machine-count');
      btn.append(dot, name, st, count);
      const li = el('li');
      li.append(btn);
      list.append(li);
      rows.set(m.id, { btn, dot, st, count });
    });
    rowsEl.replaceChildren(list);
  }

  // 구조(id 목록)가 같으면 행을 새로 만들지 않고 값만 바꾼다. 포커스가 유지된다.
  function renderRows() {
    const key = state.machines.map((m) => m.id).join('|');
    if (key !== rowKey) {
      rowKey = key;
      buildRows();
    }
    state.machines.forEach((m) => {
      const r = rows.get(m.id);
      r.dot.className = `dot dot-${m.state}`;
      r.st.className = `machine-state state-${m.state}`;
      r.st.textContent = stateLabel(m.state);
      r.count.textContent = fmt(m.processed);
    });
  }

  function markSelected() {
    rows.forEach((r, id) => {
      const on = id === selectedId;
      r.btn.classList.toggle('is-selected', on);
      r.btn.setAttribute('aria-pressed', String(on));
    });
  }

  function renderSelected() {
    const m = state && selectedId && state.machines.find((x) => x.id === selectedId);
    if (selectedId && state && !m) selectedId = null; // 새 상태에서 사라진 기계
    renderDetail(detailEl, state, m || null);
  }

  return {
    update(next, failed) {
      errorEl.hidden = !failed;
      if (!next) return;
      state = next;
      renderSummary();
      renderRows();
      markSelected();
      renderSelected();
    },
    select(id) {
      selectedId = id;
      if (!state) return;
      markSelected();
      renderSelected();
    },
  };
}
