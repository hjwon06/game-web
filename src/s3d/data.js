// 거리 데이터: /api/sec/street 를 3초마다 읽는다(ETag · after_seq · after_exec · 401 → /login).
// 재생 시각 = anchor.mt + (받은 뒤 흐른 실시간 − 6초) × speed_now. clock 이 null 이거나 stale 이면 재생을 멈추고 마지막 값을 둔다.
// 응답마다 anchor 를 다시 박지 않는다: 예측 재생 시각과 응답 기준의 차가 2초 × 배속을 넘을 때만 다시 맞추고, 안이면 30% 만 당긴다.
// board · settlements 는 market_time 과 함께 쌓아 두고 재생 시각이 그 시각을 지날 때 적용한다(advance).
// 시계는 main.js 가 initData 로 넘긴다(?capture=1 이면 step 으로만 움직이고, 폴링 대신 feed 가 apply 를 부른다).
let clockNow = () => performance.now();
export function initData(clockFn) { clockNow = clockFn; }

export const LAG_MS = 6000;       // 폴링 주기(3초)의 두 배 — 다음 응답이 오기 전에 재생이 바닥나지 않게
export const FLIGHT_MS = 4000;    // 토큰이 한 번 나는 실시간
const POLL_MS = 3000, TIMEOUT_MS = 2500;
const SNAP_MS = 2000, PULL = .3, QUEUE_MAX = 600;

// board: 지금 화면에 적용된 board · boardTime: 그 market_time(ms) · ver: board 가 바뀔 때마다 +1
// orders/execs/runs: 아직 흘려보내지 않은 새 주문 · 체결 · 결제 run(flow.js · trucks.js 가 비운다)
export const S = { clock: null, board: [], boardSig: '', boardTime: null, ver: 0, settlements: [], seq: null, exec: null,
  orders: [], execs: [], runs: [], ok: false, err: false,
  shown: { clock: null, board: [], today: null, reconcile: null } }; // 재생 시각에 맞춰 적용된 카드용 값

let anchor = null;  // { mt(시장 ms), speed, at(화면 시계 ms) }
let frozen = null;  // 멈춘 재생 시각(시장 ms)
export const speedNow = () => (anchor && anchor.speed > 0 ? anchor.speed : 1);

// 재생 시각(시장 ms). 데이터가 한 번도 없으면 null. now 의 순수 함수라 step 크기와 무관하다.
export function playTime(now) {
  if (frozen != null) return frozen;
  return anchor ? anchor.mt + (now - anchor.at - LAG_MS) * anchor.speed : null;
}
export const isFrozen = () => frozen != null;

const ms = v => { const t = Date.parse(v); return isNaN(t) ? null : t; };

// ---- c3d/data.js 에서 복사: getJ(ETag 캐시 · 304 · 401 → /login) ----
const etags = {};
async function getJ(url) {
  const path = url.split('?')[0], hit = etags[path], h = { Accept: 'application/json' };
  if (hit && hit.url === url) h['If-None-Match'] = hit.tag;
  const ctrl = new AbortController(), to = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(url, { headers: h, cache: 'no-store', signal: ctrl.signal });
    if (r.status === 401) { location.href = '/login'; throw new Error('HTTP 401'); }
    if (r.status === 304 && hit && hit.url === url) return { body: hit.body, same: true };
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const body = await r.json(), tag = r.headers.get('ETag');
    if (tag) etags[path] = { url, tag, body }; else delete etags[path];
    return { body, same: false };
  } finally { clearTimeout(to); }
}

function applyClock(c, now) {
  S.clock = c || null;
  const mt = c && ms(c.market_time);
  if (!c || c.stale || mt == null) { // 데몬이 멈췄거나 시계를 모른다: 지금 재생 시각에서 멈춘다
    if (frozen == null && anchor) frozen = playTime(now);
    return;
  }
  const speed = Number(c.speed_now) || 0, sp = speed > 0 ? speed : 1;
  if (anchor && frozen == null) {
    const pred = playTime(now), diff = mt - LAG_MS * sp - pred; // 응답 기준 "지금" 의 재생 시각 − 예측
    // 작은 차이는 30% 만 당긴다: 지금 재생 시각이 pred + 0.3·diff 가 되도록 mt 를 역산
    if (Math.abs(diff) <= SNAP_MS * sp) { anchor = { mt: pred + PULL * diff + LAG_MS * sp, speed, at: now }; return; }
  }
  anchor = { mt, speed, at: now };
  frozen = null;
}

// ---- 쌓아 둔 스냅샷(board · settlements)을 재생 시각에 맞춰 적용 ----
const queue = [], seenSettle = new Set();
let settleInit = false, shownOnce = false, lastMt = null; // lastMt: 마지막으로 아는 market_time(ms)

function show(q, P) {
  if (q.sig !== S.boardSig) { S.boardSig = q.sig; S.board = q.board; S.ver++; }
  // 카드(ui.js)가 읽는 값. 시계가 null 인 응답은 거래일을 몰라 0 으로 비어 오므로 지난 값을 지우지 않고 둔다
  if (q.clock) S.shown = { clock: q.clock, board: q.board, today: q.today, reconcile: q.reconcile };
  S.settlements = q.settlements; S.boardTime = isFinite(q.mt) ? q.mt : S.boardTime;
  q.settlements.forEach(s => {
    if (s.status !== 'settled' || seenSettle.has(s.settle_date)) return;
    seenSettle.add(s.settle_date);
    if (settleInit) S.runs.push({ date: s.settle_date, t0: isFinite(q.mt) ? q.mt : P, speed: q.speed }); // 처음 받은 목록은 이미 지난 일
  });
  settleInit = true; shownOnce = true;
}

// P: 재생 시각(시장 ms). 지난 스냅샷을 순서대로 적용한다(결제 날짜를 놓치지 않게 건너뛰지 않는다)
export function advance(P) {
  if (P == null) return;
  while (queue.length && queue[0].mt <= P) show(queue.shift(), P);
}

export function apply(body, now = clockNow()) {
  if (!body || typeof body !== 'object' || !Array.isArray(body.board)) throw new Error('/api/sec/street 모양이 맞지 않음');
  applyClock(body.clock, now);
  const dur = FLIGHT_MS * speedNow(); // 토큰 한 번의 비행 = 시장 시간 dur ms(받을 때의 배속으로 못박는다)
  (body.orders || []).forEach(o => { const t = ms(o.accepted_at); if (t != null && o.house != null) S.orders.push({ ...o, t0: t, dur }); });
  (body.executions || []).forEach(e => { const t = ms(e.executed_at); if (t != null) S.execs.push({ ...e, t0: t, dur }); });
  if (typeof body.last_seq === 'number') S.seq = Math.max(S.seq == null ? 0 : S.seq, body.last_seq);
  if (typeof body.last_exec === 'number') S.exec = Math.max(S.exec == null ? 0 : S.exec, body.last_exec);
  const sig = JSON.stringify(body.board.map(r => [r.code, r.last_price, r.change, r.open_buy_qty, r.open_sell_qty, r.open_orders]));
  const cmt = body.clock && !body.clock.stale ? ms(body.clock.market_time) : null;
  if (cmt != null) lastMt = cmt;
  // stale · clock null 응답은 마지막으로 아는 market_time 에 붙인다(−Infinity 로 대기열을 건너뛰지 않는다)
  const snap = { mt: lastMt != null ? lastMt : NaN, speed: speedNow(),
    board: body.board, sig, settlements: Array.isArray(body.settlements) ? body.settlements : [],
    clock: body.clock || null, today: body.today || null, reconcile: body.reconcile == null ? null : body.reconcile };
  if (!shownOnce || lastMt == null) show(snap, null); // 첫 응답 · 시각을 한 번도 모르는 응답은 맞출 기준이 없다: 바로 보인다
  else { queue.push(snap); if (queue.length > QUEUE_MAX) queue.splice(0, queue.length - QUEUE_MAX).forEach(q => show(q, null)); }
  S.ok = true;
}

let busy = false;
async function poll() {
  if (busy) return; busy = true;
  try {
    const q = [];
    if (S.seq != null) q.push('after_seq=' + S.seq);
    if (S.exec != null) q.push('after_exec=' + S.exec);
    const r = await getJ('/api/sec/street' + (q.length ? '?' + q.join('&') : ''));
    if (!r.same) apply(r.body); // 304: 이미 처리한 응답
    S.err = false;
  } catch (e) { S.err = true; }
  finally { busy = false; }
}
export function startPolling() { poll(); setInterval(poll, POLL_MS); }
