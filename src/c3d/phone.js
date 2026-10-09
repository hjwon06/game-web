// 3D-⑦ 폰 동작. 폰이면 아래 카드 셋(상세·출하 추적·탭)을 접어서 시작하고, 하나만 펼쳐 둔다.
// 판정은 campus3d.html 의 폰 배치 조건(max-width:640px)을 그대로 포함한다(어긋나면 폰 배치인데 펼친 채로 시작한다).
// 가로 폰(터치 + 높이 500px 이하)은 배치는 PC 와 같고 접힘 동작만 폰과 같다. ui.js·main.js 는 건드리지 않고 클래스(.collapsed)만 다룬다.
const IDS = ['g-detail', 'g-ship', 'g-tabs'];
const mq = matchMedia('(max-width:640px), (pointer:coarse) and (max-height:500px)');
const cards = IDS.map(id => document.getElementById(id)).filter(Boolean);
const isOpen = g => !g.classList.contains('collapsed');
const prev = new Map(cards.map(g => [g, isOpen(g)]));

// 접기 버튼 글자를 상태에 맞춘다. #g-tabs 버튼은 ui.js renderTabs 가 나중에 만든다.
function syncText(g) {
  const b = g.querySelector('[data-fold]');
  if (!b) return;
  const t = isOpen(g) ? '접기' : '펼치기';
  if (b.textContent !== t) b.textContent = t;
  if (b.hasAttribute('aria-label') && b.getAttribute('aria-label') !== t) b.setAttribute('aria-label', t);
}

function setOpen(g, open) { g.classList.toggle('collapsed', !open); prev.set(g, open); syncText(g); }
function openOnly(g) { cards.forEach(c => setOpen(c, c === g)); }

// 폰이 아닐 때는 아무 것도 하지 않는다(카드마다 독립).
const obs = new MutationObserver(() => {
  cards.forEach(syncText);
  if (!mq.matches) { cards.forEach(g => prev.set(g, isOpen(g))); return; }
  const opened = cards.find(g => isOpen(g) && !prev.get(g));
  if (opened) openOnly(opened);
  else cards.forEach(g => prev.set(g, isOpen(g)));
});
cards.forEach(g => obs.observe(g, { attributes: true, attributeFilter: ['class'] }));
const tabs = document.getElementById('tabs');
if (tabs) obs.observe(tabs, { childList: true });

// 폰 ↔ PC 전환(회전·창 크기). 폰으로 들어가면 모두 접고, PC 로 돌아오면 모두 펼친다(PC 의 시작 상태).
let was = mq.matches;
const enter = () => cards.forEach(g => setOpen(g, false));
const leave = () => cards.forEach(g => setOpen(g, true));
if (was) enter();
mq.addEventListener('change', () => { if (mq.matches === was) return; was = mq.matches; (was ? enter : leave)(); });

// 대상 선택(3D·검색·탭 목록)이 오면 상세를 펼치고 나머지는 접는다.
window.addEventListener('c3d:select', () => { if (mq.matches) openOnly(document.getElementById('g-detail')); });
