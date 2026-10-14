// 거리 데이터: /api/sec/street 를 3초마다 읽는다(ETag · after_seq · after_exec · 401 → /login).
// 재생 시각 = market_time + (받은 뒤 흐른 실시간 − 6초) × speed_now. clock 이 null 이거나 stale 이면 재생을 멈추고 마지막 값을 둔다.
// 시계는 main.js 가 initData 로 넘긴다(?capture=1 이면 step 으로만 움직인다).
let clockNow = () => performance.now();
export function initData(clockFn) { clockNow = clockFn; }

export const LAG_MS = 6000;       // 폴링 주기(3초)의 두 배 — 다음 응답이 오기 전에 재생이 바닥나지 않게
export const FLIGHT_MS = 4000;    // 토큰이 한 번 나는 실시간
const POLL_MS = 3000, TIMEOUT_MS = 2500;

// board: 서버 board 배열 · ver: board 가 바뀔 때마다 +1 · orders/execs: 아직 흘려보내지 않은 새 주문 · 체결(flow.js 가 비운다)
export const S = { clock: null, board: [], boardSig: '', ver: 0, settlements: [], seq: null, exec: null, orders: [], execs: [], ok: false, err: false };

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
  anchor = { mt, speed: Number(c.speed_now) || 0, at: now };
  frozen = null;
}

export function apply(body, now = clockNow()) {
  if (!body || typeof body !== 'object' || !Array.isArray(body.board)) throw new Error('/api/sec/street 모양이 맞지 않음');
  applyClock(body.clock, now);
  const dur = FLIGHT_MS * speedNow(); // 토큰 한 번의 비행 = 시장 시간 dur ms(받을 때의 배속으로 못박는다)
  (body.orders || []).forEach(o => { const t = ms(o.accepted_at); if (t != null && o.house != null) S.orders.push({ ...o, t0: t, dur }); });
  (body.executions || []).forEach(e => { const t = ms(e.executed_at); if (t != null) S.execs.push({ ...e, t0: t, dur }); });
  if (typeof body.last_seq === 'number') S.seq = Math.max(S.seq == null ? 0 : S.seq, body.last_seq);
  if (typeof body.last_exec === 'number') S.exec = Math.max(S.exec == null ? 0 : S.exec, body.last_exec);
  S.settlements = Array.isArray(body.settlements) ? body.settlements : [];
  const sig = JSON.stringify(body.board.map(r => [r.code, r.last_price, r.change, r.open_buy_qty, r.open_sell_qty, r.open_orders]));
  if (sig !== S.boardSig) { S.boardSig = sig; S.board = body.board; S.ver++; }
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
