// 좌하단 Inspect: 선택한 기계 하나의 이름·상태·작업지시·진행·최근 수치. 선택이 없으면 첫 3초 안내 문구만.
// 서버 문자열은 textContent 로만 넣는다. 숫자는 서버가 준 값만 보여준다. 골격은 한 번만 만들고 값만 갈아 끼운다.
export const STATE_LABEL = { running: '가동', stopped: '정지', broken: '고장' };
export const stateLabel = (s) => STATE_LABEL[s] ?? String(s);
export const fmt = (n) => Number(n).toLocaleString('ko-KR');

const DEFECT_WARN = 0.05; // 불량률 5% 이상이면 고장 색 글자
const HINT_LOUD_MS = 3000;

const el = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};
// 라벨 문구 + 값 칸(data-field). 값 칸을 돌려준다.
const field = (name, className = 'num') => {
  const node = el('span', className);
  node.dataset.field = name;
  return node;
};

export function createInspect(root, hint) {
  const name = el('span', 'ins-name');
  const code = el('span', 'ins-id num');
  const stText = field('state', '');
  const dot = el('i', 'dot');
  dot.setAttribute('aria-hidden', 'true');
  const st = el('span', 'ins-st');
  st.append(dot, stText);
  const wo = field('work_order', 'ins-wo-text');
  const bar = el('div', 'bar');
  bar.setAttribute('role', 'progressbar');
  const fill = el('i');
  bar.append(fill);
  const produced = field('produced');
  const target = field('target');
  const slash = document.createTextNode(' / ');
  const last = field('last_minute');
  const defect = field('defect_10m');

  const head = el('div', 'ins-head');
  head.append(name, code, st);
  const woBold = el('b');
  woBold.append(wo);
  const woLine = el('div', 'ins-wo');
  woLine.append('작업지시', woBold);
  const barN = el('div', 'bar-n');
  barN.append(produced, slash, target);
  const rows = el('div', 'ins-rows');
  const row = (label, node) => {
    const r = el('div', 'ins-row');
    r.append(label, node);
    return r;
  };
  rows.append(row('최근 1분 양품', last), row('최근 10분 불량률', defect));
  root.replaceChildren(head, woLine, bar, barN, rows);

  let firstAt = 0;

  return {
    // machine: 선택된 기계(없으면 null), state: 전체 상태(첫 응답 전이면 null)
    update(machine, state) {
      root.hidden = !machine;
      hint.hidden = Boolean(machine) || !state;
      if (state && !firstAt) {
        firstAt = Date.now();
        setTimeout(() => hint.classList.add('is-quiet'), HINT_LOUD_MS);
      }
      if (state && !machine) {
        const running = state.machines.filter((m) => m.state === 'running').length;
        hint.textContent = `${state.machines.length}대 중 ${running}대가 만들고 있습니다`;
      }
      if (!machine) return;
      const w = machine.work_order;
      name.textContent = machine.name;
      code.textContent = machine.id;
      stText.textContent = stateLabel(machine.state);
      st.className = `ins-st is-${machine.state}`;
      wo.textContent = w ? `${w.code} · ${w.product}` : '배정된 작업 없음';
      const made = w ? w.produced_qty : machine.processed;
      produced.textContent = fmt(made);
      target.textContent = w ? fmt(w.target_qty) : '';
      slash.textContent = w ? ' / ' : '';
      const pct = w && w.target_qty > 0 ? Math.min(100, Math.round((w.produced_qty / w.target_qty) * 100)) : 0;
      fill.style.width = `${pct}%`;
      bar.setAttribute('aria-valuenow', String(pct));
      last.textContent = fmt(machine.last_minute_good ?? 0);
      const ratio = state && state.hud && state.hud.defect_ratio_10m; // 서버가 공장 전체 값만 준다
      defect.textContent = typeof ratio === 'number' ? `${(ratio * 100).toFixed(1)}%` : '—';
      defect.classList.toggle('is-bad', typeof ratio === 'number' && ratio >= DEFECT_WARN);
    },
  };
}
