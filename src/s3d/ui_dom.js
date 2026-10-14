// 화면 카드 DOM. 처음에 한 번 만들고, 매 프레임 값이 바뀐 글자만 쓴다.
// 깜빡임은 ::after 덮개의 opacity 만 움직인다(sec3d.html 의 .flash). 처음 채울 때는 깜빡이지 않는다.
import { STOCKS } from './layout.js';
import { SEG_MIN } from './ui.js';

const FLAT = '#6B7280';
const SEG_NAME = ['장전', '장중', '종가', '밤'];

const rowHtml = s => `
  <div class="u-row" data-code="${s.code}">
    <span class="u-name">${s.name}</span>
    <span class="u-num u-px" data-c="px">–</span>
    <span class="u-num u-rt" data-c="rt">–</span>
    <span class="u-vol"><em class="u-lab">거래량</em><span class="u-num" data-c="vol">–</span></span>
    <span class="u-q">
      <i class="u-bar-q"><b data-c="bar"></b></i>
      <span class="u-qn"><span class="u-num u-buy" data-c="buy">–</span><span class="u-num u-sell" data-c="sell">–</span></span>
    </span>
  </div>`;

const item = (k, lab, wide) => `<div class="u-it${wide ? ' u-wide' : ''}"><span class="u-lab">${lab}</span><b class="u-num" data-k="${k}">–</b></div>`;

const HTML = `
<header class="u-top" data-k="top">
  <span class="u-logo">증권 거리</span>
  <span class="u-sub">가상 시장 · 시뮬레이터 규칙</span>
  <span class="u-chip u-stage" data-k="stage" hidden></span>
  <span class="u-spacer"></span>
  <span class="u-chip u-gray" data-k="stopped" hidden></span>
  <span class="u-chip u-gray" data-k="conn" hidden>연결 끊김</span>
  <span class="u-real u-num" data-k="real"></span>
</header>
<section class="u-card u-timecard" data-k="timecard">
  <div class="u-lab">가상 시각</div>
  <div class="u-clock"><span class="u-hm" data-k="hm">--:--</span><span class="u-sec" data-k="sec">--</span></div>
  <div class="u-date" data-k="date">–</div>
  <div class="u-next" data-k="next">–</div>
  <div class="u-band" data-k="band">${SEG_MIN.map((m, i) => `<i style="flex-grow:${m}" title="${SEG_NAME[i]} ${m}분"></i>`).join('')}<b class="u-mark" data-k="mark"></b></div>
  <div class="u-lab u-legend">장전 30분 · 장중 380분 · 종가 10분 · 밤</div>
  <div class="u-speed" data-k="speed">실제 1초 = 가상 12초</div>
</section>
<div class="u-bottom">
  <section class="u-card u-board" data-k="board">
    <div class="u-head"><span class="u-title">숫자 판</span>
      <button type="button" class="u-fold" data-k="fold" aria-expanded="true">접기</button></div>
    ${STOCKS.map(rowHtml).join('')}
  </section>
  <section class="u-card u-today" data-k="todaycard">
    ${item('orders', '주문')}${item('execs', '체결')}${item('value', '체결 금액')}
    ${item('reject', '거절')}${item('recon', '대사 어긋남')}${item('settled', '마지막 결제')}
  </section>
</div>`;

export function buildDom(root) {
  root.insertAdjacentHTML('beforeend', HTML);
  const k = {}, rows = {};
  root.querySelectorAll('[data-k]').forEach(el => { k[el.dataset.k] = el; });
  root.querySelectorAll('.u-row').forEach(el => {
    const c = {};
    el.querySelectorAll('[data-c]').forEach(e => { c[e.dataset.c] = e; });
    rows[el.dataset.code] = c;
  });
  const barSegs = [...k.band.querySelectorAll('i')];

  // 값이 바뀌었으면 쓰고, 이전 값이 있었다면 깜빡인다
  function set(el, text, color) {
    if (el.textContent === text) return;
    const first = el.dataset.had !== '1';
    el.textContent = text; el.dataset.had = '1';
    if (first || !el.classList.contains('u-fl')) return;
    el.style.setProperty('--fc', color || FLAT);
    el.classList.remove('flash'); void el.offsetWidth; el.classList.add('flash');
  }
  const plain = (el, text) => { if (el.textContent !== text) el.textContent = text; };
  const show = (el, on) => { if (el.hidden === on) el.hidden = !on; };

  k.fold.addEventListener('click', () => {
    const folded = k.board.classList.toggle('is-folded');
    k.fold.setAttribute('aria-expanded', String(!folded));
    k.fold.textContent = folded ? '펼치기' : '접기';
  });
  Object.values(rows).forEach(c => Object.values(c).forEach(e => { if (e.classList.contains('u-num')) e.classList.add('u-fl'); }));
  k.todaycard.querySelectorAll('.u-num').forEach(e => e.classList.add('u-fl'));

  function render(m) {
    show(k.stage, !!m.stage); if (m.stage) plain(k.stage, m.stage);
    show(k.stopped, m.stopped);
    if (m.stopped) k.stopped.innerHTML = `<span class="u-long">시뮬레이터 </span>멈춤 · 마지막 <span class="u-long">가상 시각 </span>${m.hm}`;
    show(k.conn, m.conn);
    k.top.classList.toggle('is-stopped', m.stopped);
    plain(k.real, m.real);

    k.timecard.classList.toggle('is-stopped', m.stopped);
    plain(k.hm, m.hm); plain(k.sec, ':' + m.sec); plain(k.date, m.date); plain(k.next, m.next);
    plain(k.speed, `실제 1초 = 가상 ${m.speed}초`);
    barSegs.forEach((s, i) => s.classList.toggle('on', i === m.seg));
    k.mark.style.left = (m.mark * 100).toFixed(3) + '%';

    m.rows.forEach(r => {
      const c = rows[r.code];
      c.px.style.color = c.rt.style.color = r.color;
      set(c.px, r.px, r.color); set(c.rt, r.rt, r.color); set(c.vol, r.vol);
      set(c.buy, r.buy); set(c.sell, r.sell);
      c.bar.style.transform = `scaleX(${r.ratio.toFixed(3)})`;
    });

    const t = m.today;
    set(k.orders, t ? won(t.orders) : '–'); set(k.execs, t ? won(t.executions) : '–');
    set(k.value, t ? (t.value / 1e8).toFixed(1) + '억 원' : '–');
    set(k.reject, t ? t.reject : '–'); set(k.recon, t ? t.reconcile : '–');
    set(k.settled, t ? t.settled : '–');
  }
  const won = n => Number(n).toLocaleString('ko-KR');
  return { render };
}
