// 상태 모듈. data/layout.json(배치, 1회) + /api/state + /api/hud(3초 폴링)를 합쳐 구독자에게 알린다.
// 원본은 서버다. 이 모듈은 상태를 수정하지 않는다(명령은 commands.js).

const LAYOUT_URL = 'data/layout.json';
const STATE_URL = '/api/state';
const HUD_URL = '/api/hud';
const POLL_MS = 3000;
const TIMEOUT_MS = 2500;

const listeners = new Set();
let layout = null;
let current = null; // 마지막으로 성공해서 만든 상태 (깊게 freeze)
let failed = false;
let timer = null;
let inFlight = false;
let lastKey = null; // 변경 감지용: 서버 응답 내용
const warned = new Set();

function deepFreeze(obj) {
  if (obj && typeof obj === 'object' && !Object.isFrozen(obj)) {
    Object.freeze(obj);
    Object.values(obj).forEach(deepFreeze);
  }
  return obj;
}

function emit() {
  const event = { state: current, error: failed };
  listeners.forEach((fn) => {
    try { fn(event); } catch (e) { console.error('state listener 오류', e); }
  });
}

async function getJson(url) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    // no-cache: 브라우저가 ETag 로 재검증하고 304 는 투명하게 200 처럼 돌려준다.
    const res = await fetch(url, { cache: 'no-cache', signal: ctrl.signal });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await res.json();
  } finally {
    clearTimeout(t);
  }
}

function warnOnce(msg) {
  if (warned.has(msg)) return;
  warned.add(msg);
  console.warn(msg);
}

function merge(api, hud) {
  if (!api || !Number.isInteger(api.version) || !Array.isArray(api.machines)) {
    throw new Error('/api/state 모양이 맞지 않음');
  }
  if (!hud || !Array.isArray(hud.machines)) throw new Error('/api/hud 모양이 맞지 않음');
  const byCode = new Map(api.machines.map((m) => [m.code, m]));
  const hudBy = new Map(hud.machines.map((m) => [m.code, m]));
  const laid = new Set(layout.machines.map((m) => m.id));
  api.machines.forEach((m) => {
    if (!laid.has(m.code)) warnOnce(`서버에만 있는 기계(그리지 않음): ${m.code}`);
  });
  const machines = [];
  layout.machines.forEach((l) => {
    const s = byCode.get(l.id);
    if (!s) { warnOnce(`layout 에만 있는 기계(그리지 않음): ${l.id}`); return; }
    const h = hudBy.get(l.id);
    const wo = h && h.work_order ? h.work_order : null;
    machines.push({
      id: l.id, name: s.name, x: l.x, y: l.y, color: l.color,
      state: s.state, version: s.version,
      processed: wo ? wo.produced_qty : 0,
      work_order: wo,
      last_minute_good: h ? h.last_minute_good : 0,
    });
  });
  return {
    version: api.version,
    updated_at: new Date().toISOString(),
    grid: layout.grid,
    conveyors: layout.conveyors,
    workers: layout.workers,
    machines,
    hud: { defect_ratio_10m: hud.defect_ratio_10m ?? null, broken: hud.broken || [] },
  };
}

async function fetchAll() {
  if (!layout) {
    const l = await getJson(LAYOUT_URL);
    if (!l || !l.grid || !Array.isArray(l.machines)) throw new Error('layout.json 모양이 맞지 않음');
    layout = l;
  }
  const [api, hud] = await Promise.all([getJson(STATE_URL), getJson(HUD_URL)]);
  return { api, hud };
}

// 한 번 읽는다. 내용이 바뀌었거나 실패 여부가 바뀐 경우에만 구독자에게 알린다.
// 같은 내용이면 updated_at 도 갱신하지 않는다(마지막 "변경" 시각이 아니라 emit 기준).
export async function refresh() {
  if (inFlight) return;
  inFlight = true;
  try {
    const { api, hud } = await fetchAll();
    const key = JSON.stringify([api, hud]);
    const recovered = failed;
    failed = false;
    if (key !== lastKey || !current) {
      current = deepFreeze(merge(api, hud));
      lastKey = key;
      emit();
    } else if (recovered) {
      current = deepFreeze({ ...current, updated_at: new Date().toISOString() });
      emit();
    }
  } catch (e) {
    const changed = !failed;
    failed = true;
    if (changed) emit();
  } finally {
    inFlight = false;
  }
}

// 명령 직후 즉시 한 번 읽기용. 진행 중인 읽기가 있으면 끝난 뒤 한 번 더 읽는다.
export async function refreshNow() {
  for (let i = 0; i < 20 && inFlight; i++) await new Promise((r) => setTimeout(r, 50));
  await refresh();
}

// listener({ state, error }) — state 는 읽기 전용, 아직 한 번도 못 읽었으면 null.
export function subscribe(listener) {
  listeners.add(listener);
  if (current || failed) listener({ state: current, error: failed });
  return () => listeners.delete(listener);
}

export function start() {
  if (timer) return;
  refresh();
  timer = setInterval(refresh, POLL_MS);
}

export function stop() {
  clearInterval(timer);
  timer = null;
}

export function getState() {
  return current;
}
