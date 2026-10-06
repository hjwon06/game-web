// 오른쪽 상태 패널. 받은 상태를 보여주기만 한다. 문자열은 전부 textContent 로 넣는다.
const STATE_LABEL = { running: '가동', stopped: '정지', defect: '불량' };

const label = (state) => STATE_LABEL[state] ?? String(state);

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

export function createPanel(root) {
  const title = root.querySelector('#panel-title');
  const body = root.querySelector('#panel-body');
  const error = root.querySelector('#panel-error');
  let factory = null;
  let selectedId = null;
  let onDeselect = () => {};

  function renderList() {
    title.textContent = '기계 목록';
    const list = el('ul', 'machine-list');
    factory.machines.forEach((m) => {
      const li = el('li', 'machine-row');
      li.append(el('span', 'machine-name', m.name), el('span', 'machine-state', label(m.state)));
      list.append(li);
    });
    body.replaceChildren(list);
  }

  function renderDetail(m) {
    title.textContent = m.name;
    const dl = el('dl', 'detail');
    [
      ['상태', label(m.state)],
      ['처리 수량', String(m.processed)],
      ['마지막 갱신 시각', factory.updated_at],
    ].forEach(([k, v]) => dl.append(el('dt', null, k), el('dd', null, v)));
    const back = el('button', 'back', '목록으로');
    back.type = 'button';
    back.addEventListener('click', () => onDeselect());
    body.replaceChildren(dl, back);
  }

  function render() {
    if (!factory) {
      title.textContent = '기계 목록';
      body.replaceChildren(el('p', 'muted', '상태를 불러오는 중입니다'));
      return;
    }
    const m = selectedId && factory.machines.find((x) => x.id === selectedId);
    if (m) renderDetail(m);
    else renderList();
  }

  return {
    // 선택 해제 요청(목록으로 버튼)을 씬에 되돌려 주기 위한 콜백 등록
    onDeselect(fn) {
      onDeselect = fn;
    },
    update(next, failed) {
      if (next) factory = next;
      error.hidden = !failed;
      if (failed) error.textContent = '상태 파일을 읽지 못했습니다';
      render();
    },
    select(id) {
      selectedId = id;
      render();
    },
  };
}
