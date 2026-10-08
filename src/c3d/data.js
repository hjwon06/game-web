// 3D 단지 데이터. src/campus/campus_data.js 의 폴링·정규화·서버 시계 규칙을 ES 모듈로 옮겼다(2D 파일은 전역 스크립트라 import 할 수 없다).
// 3초마다 /api/campus?after_seq=… 와 /api/hud 를 ETag 로 읽고(칸은 5초마다 include=bins) 401 이면 /login.
// 시계: main.js 의 시계(clock.now)를 initData 로 받아 쓴다. capture 모드에서도 now()/srvNow() 가 같은 함수로 움직인다.
let clockNow = () => performance.now();
let base = Date.now() - clockNow();
export function initData(clockFn) { clockNow = clockFn; base = Date.now() - clockNow(); }
export const now = () => clockNow(); // 화면 시계(ms)
const wall = () => base + clockNow(); // 내 시각(epoch ms) = 시작 시각 + 화면 시계

// 기계 상태(hud): code → { st: running|stopped|broken, wo: [작업지시, 품목, 생산, 목표] | null, short: 자재 대기 시작 ms | null }
export const MS = new Map();
for (let i = 1; i <= 12; i++) MS.set('M' + i, { st: 'stopped', wo: null, short: null });

// S.tasks=작업 id→정규화한 작업, S.res=자원 목록, S.off=서버시각-내시각(ms), S.bins=서버 칸 값,
// S.shown=화면에 보이는 칸 값(그 칸으로 가는 지게차가 닿은 순간에만 바뀐다), S.arrived=닿은 작업 id, S.ver=shown 이 바뀔 때마다 +1
export const S = { c: null, hudOk: false, err: false, seq: null, tasks: new Map(), res: [], off: 0, offSet: false, bins: null, binsAt: 0, shown: new Map(), arrived: new Set(), ver: 0 };
export const dataReady = () => !!(S.c && S.hudOk);
export const srvNow = () => wall() + S.off; // 서버 시계 기준 지금(ms)

// ---- 작업·자원·칸 정규화: 서버 필드 이름 몇 가지를 모두 받는다 ----
const BKEY = { material: 'mat', mat: 'mat', warehouse: 'mat', production: 'prod', prod: 'prod', hall: 'prod', qc: 'qc', shipping: 'ship', ship: 'ship', office: 'office', gate: 'gate' };
const BPREFIX = [[/^(RAW|RECV|REC|MAT|DOCK-?IN|IN)\b/i, 'mat'], [/^(PROD|WIP|LINE|MFG)/i, 'prod'], [/^(QC|INSP)/i, 'qc'], [/^(FG|SHIP|DOCK-?OUT|OUT)/i, 'ship'], [/^(SUP|CUST|GATE|ROAD)/i, 'gate']];
export function bKeyOf(code, b) {
  const k = b && BKEY[String(b).toLowerCase()];
  if (k) return k;
  const hit = BPREFIX.find(([re]) => re.test(code || ''));
  return hit ? hit[1] : null;
}
const tsOf = v => { if (!v) return null; const s = String(v), ms = Date.parse(/(Z|[+-]\d\d:?\d\d)$/.test(s) ? s : s + 'Z'); return isNaN(ms) ? null : ms; };
export const PAL = ['#C9A227', '#0E7C86', '#B5532D', '#6A7FC1', '#7A8C62', '#A0577C', '#4E8F5F', '#8B6F47'];
export function itemColor(key) { let h = 0; String(key || '').split('').forEach(c => { h = (h * 31 + c.charCodeAt(0)) >>> 0; }); return PAL[h % PAL.length]; }
function sideOf(t, k) { const o = t[k] || t[k + '_location'] || {}; const code = t[k + '_code'] || o.code || ''; return { code, b: bKeyOf(code, t[k + '_building'] || o.building) }; }
function normTask(t) {
  const pr = t.product, pn = typeof pr === 'string' ? pr : (pr && pr.name) || t.product_name || '', pc = (pr && pr.code) || t.product_code || pn;
  return { id: t.id, seq: t.seq, kind: t.kind, status: t.status === 'finished' ? 'done' : t.status, rid: t.resource_id == null ? (t.resource && t.resource.id) : t.resource_id,
    rcode: t.resource_code || (t.resource && t.resource.code) || null, product: pn, color: t.product_color || itemColor(pc), qty: Number(t.qty), ref: t.ref || '',
    from: sideOf(t, 'from'), to: sideOf(t, 'to'), planned: tsOf(t.planned_at), t0: tsOf(t.started_at), t1: tsOf(t.expected_finish_at), tf: tsOf(t.finished_at) };
}
export const resById = id => S.res.find(r => r.id === id);
export const resCode = t => t.rcode || (resById(t.rid) || {}).code || null;

// 칸 표시 동기화: 그 칸에 걸린 putaway·feed·pick 이 아직 지게차에 닿지 않았으면 옛 값을 붙든다
const pendingBin = code => { for (const t of S.tasks.values()) if (['putaway', 'feed', 'pick'].includes(t.kind) && (t.from.code === code || t.to.code === code) && (t.status === 'started' || (t.status === 'done' && !S.arrived.has(t.id)))) return true; return false; };
function syncBins() {
  if (!S.bins) return;
  S.bins.forEach(b => {
    if (S.shown.has(b.code) && pendingBin(b.code)) return;
    const p = b.product, pn = typeof p === 'string' ? p : (p && p.name) || b.product_name || '';
    const v = { product: pn, qty: Number(b.qty) || 0, cap: Number(b.capacity == null ? b.capacity_units : b.capacity) || 0, color: itemColor((p && p.code) || b.product_code || pn) };
    const o = S.shown.get(b.code);
    if (!o || o.qty !== v.qty || o.color !== v.color) S.ver++;
    S.shown.set(b.code, v);
  });
}
export function arrive(t) { S.arrived.add(t.id); syncBins(); }

const POLL_MS = 3000, TIMEOUT_MS = 2500, BINS_MS = 5000, etags = {};
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
function applyHud(hud) {
  if (!hud || !Array.isArray(hud.machines)) throw new Error('/api/hud 모양이 맞지 않음');
  hud.machines.forEach(x => {
    const m = MS.get(x.code); if (!m) return;
    const w = x.work_order;
    m.st = x.state; m.wo = w ? [w.code, w.product, w.produced_qty, w.target_qty] : null;
  });
  S.hudOk = true;
}
function applyCampus(c, same, withBins) {
  if (!c || !c.buildings) throw new Error('/api/campus 모양이 맞지 않음');
  S.c = c;
  if (same) return; // 304: 이미 처리한 응답
  const hm = c.buildings.hall && c.buildings.hall.machines; // 자재 대기: 기계 상태와 별개 표시
  if (Array.isArray(hm)) hm.forEach(h => { const m = MS.get(h.code); if (m) m.short = h.material_short ? tsOf(h.since) || wall() : null; });
  const st = tsOf(c.server_time), o = st == null ? null : st - wall(); // 서버 시각 오프셋(급변은 완만히)
  if (o != null) { S.off = S.offSet ? S.off * .7 + o * .3 : o; S.offSet = true; }
  if (Array.isArray(c.resources)) S.res = c.resources;
  (c.tasks || []).forEach(t => { S.tasks.set(t.id, normTask(t)); if (typeof t.seq === 'number') S.seq = Math.max(S.seq == null ? 0 : S.seq, t.seq); });
  if (typeof c.last_seq === 'number') S.seq = Math.max(S.seq == null ? 0 : S.seq, c.last_seq); // 단조 증가만
  // 서버는 bins 를 {raw:[…], fg:[…]} 로 준다. 배열로 펴서 쓴다(배열로 와도 그대로).
  const bins = Array.isArray(c.bins) ? c.bins : (c.bins && typeof c.bins === 'object' ? [].concat(c.bins.raw || [], c.bins.fg || []) : null);
  if (withBins && bins) { S.bins = bins; S.binsAt = Date.now(); }
  syncBins();
}
let busy = false;
async function poll() {
  if (busy) return; busy = true;
  try {
    const wantBins = Date.now() - S.binsAt >= BINS_MS - 300, q = [];
    if (S.seq != null) q.push('after_seq=' + S.seq);
    if (wantBins) q.push('include=bins');
    const [c, h] = await Promise.all([getJ('/api/campus' + (q.length ? '?' + q.join('&') : '')), getJ('/api/hud')]);
    applyHud(h.body); applyCampus(c.body, c.same, wantBins); S.err = false;
  } catch (e) { S.err = true; }
  finally { busy = false; }
}
export function startPolling() { poll(); setInterval(poll, POLL_MS); }
