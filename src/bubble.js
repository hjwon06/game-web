// 선택한 기계 위 말풍선: 지금 상태에서 가능한 조작 버튼만 보여 준다. 명령은 commands.js 가 보내고 여기서는 호출만 한다.
// "처리 중"과 결과 문구는 모듈이 들고 있어서, 3초마다 상태가 다시 와도 지워지지 않는다.
import { sendCommand } from './commands.js';

// 상태별 버튼. 첫 번째가 주 버튼(채움), 나머지는 보조(테두리만).
const ACTIONS = {
  running: [['stop', '정지'], ['break', '고장']],
  stopped: [['start', '가동'], ['break', '고장']],
  broken: [['repair', '수리']],
};
const RESULT_TEXT = {
  409: '다른 곳에서 먼저 바뀌었습니다. 최신 상태로 맞췄습니다',
  422: '지금 상태에서는 할 수 없는 조작입니다',
  0: '서버에 닿지 않습니다. 잠시 뒤 다시 눌러 주세요',
  other: '서버 오류가 났습니다. 잠시 뒤 다시 눌러 주세요',
};
const RESULT_MS = 5000;
const GAP = 14; // 기계 그림 위변과 말풍선 사이(선택 테두리 4px + 꼬리)
const MARGIN = 8; // 화면 가장자리 여백

const el = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

// anchorOf(id) → 화면 좌표의 기계 사각형 {x, y, w, h} (main.js 가 월드→화면 변환을 한 곳에서 한다)
export function createBubble(root, { anchorOf }) {
  const busy = new Map(); // 기계 id -> 처리 중인 명령 kind
  const notices = new Map(); // 기계 id -> { text, timer }
  let machine = null;
  let built = '';
  let result = null;

  function setNotice(id, text) {
    const old = notices.get(id);
    if (old) clearTimeout(old.timer);
    if (text) notices.set(id, { text, timer: setTimeout(() => setNotice(id, ''), RESULT_MS) });
    else notices.delete(id);
    render();
  }

  async function run(kind) {
    const m = machine;
    if (!m || busy.has(m.id)) return;
    busy.set(m.id, kind);
    setNotice(m.id, '');
    let text = '';
    try {
      const res = await sendCommand(m, kind);
      const status = res && Number.isFinite(res.status) ? res.status : 0;
      text = status === 200 ? '' : RESULT_TEXT[status] ?? RESULT_TEXT.other;
    } catch {
      text = RESULT_TEXT[0];
    }
    busy.delete(m.id);
    setNotice(m.id, text);
  }

  function render() {
    if (!machine) { root.hidden = true; built = ''; return; }
    root.hidden = false;
    const note = notices.get(machine.id);
    const doing = busy.get(machine.id);
    const key = [machine.id, machine.state, doing ?? '', note ? note.text : ''].join('|');
    if (key !== built) {
      built = key;
      const row = el('div', 'bubble-row');
      (ACTIONS[machine.state] || []).forEach(([kind, label], i) => {
        const btn = el('button', `cmd-btn${i === 0 ? '' : ' is-sub'}`, doing === kind ? '처리 중' : label);
        btn.type = 'button';
        btn.dataset.kind = kind;
        btn.disabled = Boolean(doing); // 처리 중에는 모두 잠금
        btn.addEventListener('click', () => run(kind));
        row.append(btn);
      });
      result = el('p', 'cmd-result', note ? note.text : '');
      result.setAttribute('role', 'status');
      root.replaceChildren(row, result);
    }
    place();
  }

  // 기계 그림 위 가운데에 붙인다. 화면 밖으로 나가면 밀어 넣고, 꼬리는 기계 가운데를 계속 가리킨다.
  function place() {
    const a = machine && anchorOf(machine.id);
    if (!a) { root.hidden = true; return; }
    const cx = a.x + a.w / 2;
    const half = root.offsetWidth / 2;
    const left = Math.min(Math.max(cx, half + MARGIN), window.innerWidth - half - MARGIN);
    root.style.left = `${left}px`;
    root.style.top = `${Math.max(a.y - GAP, root.offsetHeight + MARGIN)}px`;
    root.style.setProperty('--arrow', `${half + (cx - left)}px`);
  }

  return {
    // 선택이 바뀌었거나 새 상태가 왔을 때. machine 이 null 이면 닫는다.
    update(next) {
      machine = next;
      render();
    },
    place,
  };
}
