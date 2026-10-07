// 화면 위에 얹는 글자들: 좌상단 HUD(가동·정지·고장 수, 계정), 우상단 고장 칩, 구역 이름표·기계 명판.
// 전부 받은 상태를 보여주기만 한다. 서버 문자열은 textContent 로만 넣는다. 좌표는 main.js 가 준 anchorOf 만 쓴다.

const el = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

// 로그인한 이름은 한 번만 받는다. 실패해도 화면은 그대로 둔다(401 이면 state.js 가 로그인으로 보낸다).
let meRequested = false;
function loadMe() {
  if (meRequested) return;
  meRequested = true;
  fetch('/api/me', { cache: 'no-cache' })
    .then((res) => (res.ok ? res.json() : null))
    .then((me) => {
      if (!me || !me.name) return;
      document.getElementById('hud-user-name').textContent = me.name;
      document.getElementById('hud-user').hidden = false;
    })
    .catch(() => { meRequested = false; });
}

// "가동 N · 정지 N · 고장 N" 한 줄 + 연결 끊김 표시 + 고장 칩. onPickBroken(id): 칩을 눌렀을 때.
export function createHud({ onPickBroken }) {
  const countEl = document.getElementById('hud-count');
  const linkEl = document.getElementById('hud-link');
  const chip = document.getElementById('alert-chip');
  const chipText = chip.querySelector('span');
  let broken = [];
  let turn = 0;

  chip.addEventListener('click', () => {
    if (!broken.length) return;
    turn = (turn + 1) % broken.length; // 여러 대면 누를 때마다 다음 고장 기계
    onPickBroken(broken[turn].id);
  });

  const part = (label, n) => {
    const frag = document.createDocumentFragment();
    frag.append(`${label} `, el('span', 'num', String(n)));
    return frag;
  };

  return {
    update(state, error) {
      loadMe();
      linkEl.hidden = !error;
      if (!state) return;
      const by = (s) => state.machines.filter((m) => m.state === s);
      countEl.replaceChildren(part('가동', by('running').length), ' · ', part('정지', by('stopped').length), ' · ', part('고장', by('broken').length));
      broken = by('broken');
      chip.hidden = broken.length === 0;
      if (!broken.length) { turn = 0; return; }
      turn = Math.min(turn, broken.length - 1);
      chipText.textContent = broken.length === 1 ? `${broken[0].name} 고장` : `${broken[0].name} 외 ${broken.length - 1}대 고장`;
    },
  };
}

// 구역 이름표(01 입고…)와 기계 명판. 명판은 이름만, 선택·고장 기계만 진하게(고장은 빨간 점 포함).
export function createLabels(root) {
  let key = '';
  let zoneEls = [];
  let plates = new Map(); // id -> { node, dot }

  function build(state) {
    root.replaceChildren();
    zoneEls = state.zones.map((z, i) => {
      const tag = el('span', 'zone-label');
      tag.append(el('b', 'zone-no num', String(i + 1).padStart(2, '0')), z.name);
      root.append(tag);
      return { tag, z };
    });
    plates = new Map(state.machines.map((m) => {
      const node = el('div', 'plate');
      const dot = el('i', 'dot');
      dot.hidden = true;
      node.append(dot, el('span', '', m.name));
      root.append(node);
      return [m.id, { node, dot }];
    }));
  }

  return {
    // 구조가 바뀐 응답에서만 DOM 을 새로 만들고, 아니면 강조만 바꾼다.
    update(state, selectedId) {
      const k = JSON.stringify([state.zones, state.machines.map((m) => [m.id, m.name])]);
      if (k !== key) { key = k; build(state); }
      state.machines.forEach((m) => {
        const p = plates.get(m.id);
        if (!p) return;
        p.node.classList.toggle('is-bad', m.state === 'broken');
        p.node.classList.toggle('is-hot', m.id === selectedId && m.state !== 'broken');
        p.dot.hidden = m.state !== 'broken';
      });
    },
    // cell: 칸 한 변(px), toScreen(wx, wy): 월드 → 화면, anchorOf(id): 화면 좌표 기계 사각형
    place({ cell, toScreen, anchorOf }) {
      zoneEls.forEach(({ tag, z }) => {
        const p = toScreen(z.label.x * cell + 12, z.label.y * cell + 12);
        tag.style.left = `${p.x}px`;
        tag.style.top = `${p.y}px`;
      });
      plates.forEach((p, id) => {
        const a = anchorOf(id);
        if (!a) return;
        p.node.style.left = `${a.x + a.w / 2}px`;
        p.node.style.top = `${a.y + a.h + 8}px`;
      });
    },
  };
}
