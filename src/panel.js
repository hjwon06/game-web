// 오른쪽 패널: 요약 → 기계 목록, 선택 상세는 왼쪽 열 캔버스 아래 카드. 받은 상태를 보여주기만 한다.
// onSelect 는 목록 행을 눌렀을 때만 부른다. select() 는 바깥(캔버스)에서 온 선택이라 되부르지 않는다.
import { el, fmt, stateLabel, renderDetail } from './panel_detail.js';

const DEFECT_WARN = 0.05; // 불량률 5% 이상이면 고장 색 글자

export function createPanel(root, { onSelect }) {
  const summaryEl = root.querySelector('#panel-summary');
  const rowsEl = root.querySelector('#panel-rows');
  const detailEl = document.getElementById('panel-detail'); // 레이아웃상 패널 밖(왼쪽 열 아래)에 있다
  const errorEl = root.querySelector('#panel-error');
  let state = null;
  let selectedId = null;
  let autoDone = false;
  let rowKey = '';
  const rows = new Map(); // id -> { btn, dot, st, count }
  rowsEl.replaceChildren(el('p', 'muted', '상태를 불러오는 중입니다'));

  function renderSummary() {
    const ms = state.machines;
    const count = (s) => ms.filter((m) => m.state === s).length;
    const ratio = state.hud && state.hud.defect_ratio_10m;
    const ratioText = typeof ratio === 'number' ? `${(ratio * 100).toFixed(1)}%` : '—';
    const main = el('div', 'summary-main');
    main.append(el('span', 'summary-number', String(count('running'))), el('span', 'summary-caption', `/ ${ms.length} 가동`));
    const chips = el('div', 'summary-chips');
    chips.append(
      chip('stopped', '정지', String(count('stopped'))),
      chip('broken', '고장', String(count('broken'))),
      chip(null, '불량률(10분)', ratioText, typeof ratio === 'number' && ratio >= DEFECT_WARN ? 'state-broken' : ''),
    );
    summaryEl.replaceChildren(main, chips);
  }

  // kind 가 null 이면 점 없이 글자만. valueClass 로 값 글자 색을 바꾼다.
  function chip(kind, label, value, valueClass = '') {
    const c = el('span', 'stat-chip');
    if (kind) {
      const dot = el('i', `dot dot-${kind}`);
      dot.setAttribute('aria-hidden', 'true');
      c.append(dot);
    }
    c.append(label, el('span', `num ${valueClass}`.trim(), value));
    return c;
  }

  // 처음 불러왔을 때 한 번만: 고장 첫 번째 → 가동 중 첫 번째 → 첫 기계. 이미 골랐으면 그대로 둔다.
  function autoSelect() {
    if (autoDone) return;
    autoDone = true;
    if (selectedId) return;
    const ms = state.machines;
    const first = ms.find((m) => m.state === 'broken') || ms.find((m) => m.state === 'running') || ms[0];
    if (first) {
      selectedId = first.id;
      onSelect(selectedId);
    }
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
    renderDetail(detailEl, m || null);
  }

  return {
    update(next, failed) {
      errorEl.hidden = !failed;
      if (!next) return;
      state = next;
      renderSummary();
      renderRows();
      autoSelect();
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
