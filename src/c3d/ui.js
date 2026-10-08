// 3D-⑤ 관제 UI: 상단 바 · 숫자 카드 · 상세 카드 · 출하 추적 · 도크/지게차/트럭 탭 · 줌 버튼.
// 순수 DOM. 서버 문자열은 textContent 로만 넣는다. 골격은 campus3d.html 의 #ui, 여기서는 채우기만 한다.
// /api/campus?include=ops 를 2초마다 따로 읽는다(작업·이동 폴링과 분리). 선택은 window 'c3d:select' {type, code}.
import { MS, S } from './data.js';

const OPS_MS = 2000, LOST_MS = 10000, STAGES = [['received', '접수'], ['picked', '피킹'], ['staged', '출하대 집결'], ['loaded', '상차'], ['shipped', '출하']];
const SITE_NAME = { mat: '자재창고', ship: '출하장', qc: '품질검사', prod: '생산동' };
const MACHINE_ST = { running: ['가동 중', 'ok'], stopped: ['정지', ''], broken: ['고장', 'bad'] };
const $ = id => document.getElementById(id);
const el = (tag, cls, text) => { const n = document.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };
const pill = (text, tone) => el('span', 'pill' + (tone ? ' ' + tone : ''), text);
const pct = v => v == null || isNaN(v) ? null : Math.round(v <= 1 ? v * 100 : v);
const clamp01 = v => Math.max(0, Math.min(1, v || 0));
const fmt = n => Number(n || 0).toLocaleString('ko-KR');
const kst = new Intl.DateTimeFormat('ko-KR', { timeZone: 'Asia/Seoul', hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' });
const hhmm = v => { const d = new Date(v); return isNaN(d) ? '' : new Intl.DateTimeFormat('ko-KR', { timeZone: 'Asia/Seoul', hour12: false, hour: '2-digit', minute: '2-digit' }).format(d); };

function barEl(frac) { const b = el('div', 'bar'), i = el('i'); i.style.width = Math.round(clamp01(frac) * 100) + '%'; b.append(i); return b; }
function rowEl(k, v) { const r = el('div', 'row'); r.append(el('span', 'k', k)); const s = el('span', 'num'); if (v instanceof Node) s.append(v); else s.textContent = v; r.append(s); return r; }

// 서버 상태 문자열 → 한국어 칩. 모르는 값은 그대로 보여준다.
function statusKo(s, kind) {
  const t = String(s || '').toLowerCase();
  if (/unload|하차/.test(t)) return ['하차 중', 'act'];
  if (/load|상차/.test(t)) return ['상차 중', 'act'];
  if (/wait|queue|idle|대기/.test(t)) return ['대기', ''];
  if (/move|drive|busy|work|이동|진행/.test(t)) return ['이동 중', 'act'];
  if (!t) return [kind === 'forklift' ? '대기' : '-', ''];
  return [String(s), ''];
}

export function createUi({ zoomIn, zoomOut, home }) {
  const root = $('ui');
  let ops = null, okAt = 0, tab = 'dock', sel = null;
  const TABS = [['dock', '도크'], ['fork', '지게차'], ['truck', '트럭']];

  const select = (type, code) => window.dispatchEvent(new CustomEvent('c3d:select', { detail: { type, code } }));

  // ---- 접기 / H ----
  document.querySelectorAll('.grp').forEach(g => {
    const b = g.querySelector('[data-fold]');
    if (b) b.addEventListener('click', () => { const c = g.classList.toggle('collapsed'); b.textContent = c ? '펼치기' : '접기'; b.setAttribute('aria-label', b.textContent); });
  });
  addEventListener('keydown', e => {
    if ((e.key === 'h' || e.key === 'H') && !e.ctrlKey && !e.metaKey && !e.altKey && !/^(INPUT|TEXTAREA)$/.test((e.target || {}).tagName || '')) root.classList.toggle('hidden');
  });

  // ---- 줌 ----
  $('z-in').addEventListener('click', zoomIn);
  $('z-out').addEventListener('click', zoomOut);
  $('z-home').addEventListener('click', home);

  // ---- 시계 / 로그인 이름 ----
  const tickClock = () => { $('clock').textContent = kst.format(new Date()); };
  tickClock(); setInterval(tickClock, 1000);
  fetch('/api/me', { cache: 'no-cache' }).then(r => r.ok ? r.json() : null).then(m => { if (m && m.name) $('me').textContent = m.name; }).catch(() => {});

  // ---- 검색: 입력 + 결과 목록까지(이동은 ⑥) ----
  const inEl = $('search-in'), resEl = $('search-res');
  let sTimer = 0, sCtl = null;
  inEl.addEventListener('input', () => {
    clearTimeout(sTimer);
    const q = inEl.value.trim();
    if (!q) { resEl.replaceChildren(); return; }
    sTimer = setTimeout(async () => {
      if (sCtl) sCtl.abort();
      sCtl = new AbortController();
      try {
        const r = await fetch('/api/campus/search?q=' + encodeURIComponent(q), { headers: { Accept: 'application/json' }, signal: sCtl.signal });
        if (!r.ok) throw new Error(r.status);
        const list = (await r.json()).results || [];
        if (!list.length) { const li = el('li'); li.append(el('span', 'sub', '검색 결과가 없습니다')); resEl.replaceChildren(li); return; }
        resEl.replaceChildren(...list.slice(0, 20).map(x => { const li = el('li'); li.append(el('span', null, x.label || x.code), el('span', 'sub', x.code || '')); return li; }));
      } catch (e) { if (e.name !== 'AbortError') { const li = el('li'); li.append(el('span', 'sub', '검색을 불러오지 못했습니다')); resEl.replaceChildren(li); } }
    }, 250);
  });
  inEl.addEventListener('keydown', e => { if (e.key === 'Escape') { inEl.value = ''; resEl.replaceChildren(); inEl.blur(); } });

  // ---- 렌더 ----
  function renderTop() {
    const k = ops.kpi || {}, docks = ops.docks || [];
    const used = [...S.shown.values()].filter(v => v.qty > 0).length;
    $('site-chip').textContent = `자재창고 ${S.bins ? used : '-'}/24칸 · 도크 ${docks.filter(d => d.occupied).length}/${docks.length || 4}`;
    const d = k.pallets_delta_1h, ot = pct(k.on_time_rate);
    const card = (value, unit, label, extra) => { const c = el('div', 'kpi'), v = el('div', 'v num', value); if (unit) v.append(el('small', null, unit)); c.append(v, el('div', 'l', label)); if (extra) c.lastChild.textContent = label + ' · ' + extra; return c; };
    $('kpi').replaceChildren(
      card(fmt(k.pallets_on_hand), '팔레트', '재고', d == null ? '' : '최근 1시간 ' + (d > 0 ? '+' : d < 0 ? '−' : '') + Math.abs(d)),
      card(fmt(k.trucks_on_site), '대', '단지 내 트럭', `입고 ${k.trucks_in || 0} · 출하 ${k.trucks_out || 0}`),
      ot == null ? card('표본 없음', '', '정시 출하율 (최근 7일)') : card(String(ot), '%', '정시 출하율', '최근 7일'));
  }

  function renderDetail() {
    const body = $('d-body'), title = $('d-title'), pl = $('d-pill'), parts = [];
    const back = () => { if (!sel) return; const b = el('button', 'link', '자재창고로 돌아가기'); b.addEventListener('click', () => { sel = null; renderDetail(); }); parts.push(b); };
    pl.replaceChildren();
    const type = sel ? sel.type : 'site', code = sel ? sel.code : 'mat';
    if (type === 'truck') {
      const t = (ops.trucks || []).find(x => String(x.no) === String(code));
      title.textContent = '트럭 ' + code;
      if (t) {
        const [s, tone] = statusKo(t.status), inbound = t.type === 'in';
        pl.append(pill(s, tone));
        parts.push(rowEl(inbound ? '공급사' : '고객', t.party || '-'), rowEl('도크', t.dock || '-'), rowEl(inbound ? '하차' : '상차', `${t.done || 0} / ${t.total || 0}`), barEl(t.total ? t.done / t.total : 0), rowEl('도착 예정', t.eta ? hhmm(t.eta) || String(t.eta) : '-'));
      } else parts.push(el('div', 'empty', '이 트럭은 단지에 없습니다'));
    } else if (type === 'forklift') {
      const f = (ops.forklifts || []).find(x => x.code === code);
      title.textContent = '지게차 ' + code;
      if (f) {
        const k = f.task;
        pl.append(k ? pill('작업 중', 'act') : pill('대기'));
        if (k) parts.push(rowEl('작업', k.kind || '-'), rowEl('품목', `${k.product || '-'} ${fmt(k.qty)}`), rowEl('경로', `${k.from_code || '-'} → ${k.to_code || '-'}`), rowEl('진행률', pct(f.progress) + '%'), barEl(f.progress <= 1 ? f.progress : f.progress / 100));
        parts.push(rowEl('대기 건수', `${f.planned_count || 0}건`));
      } else parts.push(el('div', 'empty', '지게차 정보가 없습니다'));
    } else if (type === 'machine') {
      const m = MS.get(code), [s, tone] = MACHINE_ST[m && m.st] || ['확인 중', ''];
      title.textContent = '기계 ' + code;
      pl.append(pill(s, tone));
      if (m && m.wo) parts.push(rowEl('작업지시', m.wo[0] || '-'), rowEl('품목', m.wo[1] || '-'), rowEl('생산 / 목표', `${fmt(m.wo[2])} / ${fmt(m.wo[3])}`), barEl(m.wo[3] ? m.wo[2] / m.wo[3] : 0));
      else parts.push(el('div', 'empty', '진행 중인 작업지시가 없습니다'));
      if (m && m.short) parts.push(rowEl('자재', '대기 중'));
    } else if (type === 'bin') {
      const b = S.shown.get(code);
      title.textContent = '칸 ' + code;
      if (b && b.qty > 0) { pl.append(pill('재고 있음', 'ok')); parts.push(rowEl('품목', b.product || '-'), rowEl('수량', fmt(b.qty) + (b.cap ? ` / ${fmt(b.cap)}` : ''))); }
      else { pl.append(pill('빈 칸')); parts.push(el('div', 'empty', '이 칸은 비어 있습니다')); }
    } else {
      const site = (ops.sites || {})[code] || {}, items = site.items || [];
      title.textContent = SITE_NAME[code] || String(code);
      const low = items.some(i => isLow(i));
      pl.append(low ? pill('재고 부족 있음', 'warn') : pill('정상', 'ok'));
      parts.push(el('div', 'h5', '재고 상위 5'));
      if (!items.length) parts.push(el('div', 'empty', '표시할 품목이 없습니다'));
      items.slice(0, 5).forEach(i => parts.push(rowEl(i.product || '-', (() => { const w = el('span'); w.append(`${fmt(i.qty)} `, isLow(i) ? pill('부족', 'warn') : pill('재고 있음', 'ok')); return w; })())));
      if (site.forklift_rate != null) { parts.push(el('div', 'h5', `지게차 작업률 ${pct(site.forklift_rate)}%`), barEl(site.forklift_rate <= 1 ? site.forklift_rate : site.forklift_rate / 100)); }
    }
    back();
    body.replaceChildren(...parts);
  }
  const isLow = i => Number(i.qty) <= 0 || /low|short|out|부족/i.test(String(i.status || ''));

  function renderShip() {
    const sh = ops.shipment, ol = $('stages');
    $('ship-who').textContent = sh ? `${sh.so_no || ''} · ${sh.customer || ''}` : '';
    if (!sh) { const li = el('li', null, '추적할 수주가 없습니다'); ol.replaceChildren(li); return; }
    const at = Object.fromEntries((sh.stages || []).map(s => [s.key, s.at]));
    const curIdx = STAGES.findIndex(([k]) => !at[k]);
    ol.replaceChildren(...STAGES.map(([k, name], i) => {
      const li = el('li', at[k] ? 'done' : i === curIdx ? 'cur' : '');
      li.append(el('span', null, name), el('span', 't num', at[k] ? hhmm(at[k]) : i === curIdx ? '진행 중' : '-'));
      if (i === curIdx) li.setAttribute('aria-current', 'step');
      return li;
    }));
  }

  function renderTabs() {
    const docks = ops.docks || [], forks = ops.forklifts || [], trucks = ops.trucks || [];
    const counts = { dock: `${docks.filter(d => d.occupied).length}/${docks.length || 4}`, fork: forks.length, truck: trucks.length };
    const bar = $('tabs');
    if (!bar.firstChild) {
      TABS.forEach(([k]) => { const b = el('button'); b.setAttribute('role', 'tab'); b.dataset.k = k; b.addEventListener('click', () => { tab = k; renderTabs(); }); bar.append(b); });
      const f = el('button', 'fold', '접기'); f.dataset.fold = ''; f.addEventListener('click', () => { const c = $('g-tabs').classList.toggle('collapsed'); f.textContent = c ? '펼치기' : '접기'; });
      bar.append(f);
    }
    bar.querySelectorAll('[data-k]').forEach(b => { b.textContent = `${TABS.find(t => t[0] === b.dataset.k)[1]} ${counts[b.dataset.k]}`; b.setAttribute('aria-selected', String(b.dataset.k === tab)); });
    const row = (code, place, [s, tone], frac, type, selCode) => {
      const li = el('li'); li.tabIndex = 0;
      li.append(el('span', 'c num', code), el('span', 'p', place), pill(s, tone), barEl(frac));
      const go = () => select(type, selCode);
      li.addEventListener('click', go); li.addEventListener('keydown', e => { if (e.key === 'Enter') go(); });
      return li;
    };
    let rows;
    if (tab === 'dock') rows = docks.map(d => { const tr = d.truck && (d.truck.no || d.truck), t = trucks.find(x => String(x.no) === String(tr)); return row(d.code, d.occupied ? `트럭 ${tr || ''}` : (d.kind === 'out' ? '출하 도크' : '입고 도크'), d.occupied ? statusKo(t ? t.status : d.kind === 'out' ? 'loading' : 'unloading') : ['비어 있음', ''], t && t.total ? t.done / t.total : 0, tr ? 'truck' : 'site', tr ? String(tr) : (d.kind === 'out' ? 'ship' : 'mat')); });
    else if (tab === 'fork') rows = forks.map(f => row(f.code, f.task ? `${f.task.from_code || '-'} → ${f.task.to_code || '-'}` : '대기 위치', f.task ? ['이동 중', 'act'] : ['대기', ''], f.progress <= 1 ? f.progress : f.progress / 100, 'forklift', f.code));
    else rows = trucks.map(t => row(t.no, `${t.type === 'in' ? '입고' : '출하'} · ${t.dock || '도크 대기'}`, statusKo(t.status), t.total ? t.done / t.total : 0, 'truck', String(t.no)));
    const list = $('tab-list'), top = list.scrollTop;
    list.replaceChildren(...(rows.length ? rows : [el('li', 'empty', '해당하는 항목이 없습니다')]));
    list.scrollTop = top;
  }

  window.addEventListener('c3d:select', e => {
    const d = e.detail || {};
    if (!d.type || d.code == null) return;
    sel = d.type === 'site' && d.code === 'mat' ? null : { type: d.type, code: String(d.code) };
    if (ops) renderDetail();
  });

  // ---- 폴링 ----
  let busy = false;
  async function poll() {
    if (busy) return; busy = true;
    const ctl = new AbortController(), to = setTimeout(() => ctl.abort(), 4000);
    try {
      const r = await fetch('/api/campus?include=ops', { headers: { Accept: 'application/json' }, cache: 'no-store', signal: ctl.signal });
      if (r.status === 401) { location.href = '/login'; return; }
      if (!r.ok) throw new Error('HTTP ' + r.status);
      const j = await r.json();
      if (!j.ops) throw new Error('ops 없음');
      ops = j.ops; okAt = Date.now();
      renderTop(); renderDetail(); renderShip(); renderTabs();
    } catch (e) { /* 끊김 칩이 알린다 */ }
    finally { clearTimeout(to); busy = false; }
  }
  okAt = Date.now();
  poll(); setInterval(poll, OPS_MS);
  setInterval(() => { $('lost').hidden = Date.now() - okAt <= LOST_MS; }, 1000);
}
