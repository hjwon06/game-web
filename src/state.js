// 상태 읽기 전용 모듈. data/factory.json 을 폴링해 구독자에게 알린다.
// 상태를 수정하는 함수는 의도적으로 없다. 원본은 파일(나중에는 서버)이 갖는다.

const STATE_URL = 'data/factory.json';
const POLL_MS = 3000;
const TIMEOUT_MS = 2500;

const listeners = new Set();
let current = null; // 마지막으로 성공해서 받은 상태 (깊게 freeze)
let failed = false; // 마지막 읽기가 실패했는가
let timer = null;
let inFlight = false;

function deepFreeze(obj) {
  if (obj && typeof obj === 'object' && !Object.isFrozen(obj)) {
    Object.freeze(obj);
    Object.values(obj).forEach(deepFreeze);
  }
  return obj;
}

function isValid(s) {
  return s && Number.isInteger(s.version) && s.grid && Array.isArray(s.machines)
    && Array.isArray(s.conveyors) && Array.isArray(s.workers);
}

function emit() {
  const event = { state: current, error: failed };
  listeners.forEach((fn) => {
    try { fn(event); } catch (e) { console.error('state listener 오류', e); }
  });
}

async function fetchState() {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(`${STATE_URL}?t=${Date.now()}`, { cache: 'no-store', signal: ctrl.signal });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const json = await res.json();
    if (!isValid(json)) throw new Error('상태 파일 모양이 맞지 않음');
    return json;
  } finally {
    clearTimeout(t);
  }
}

// 한 번 읽는다. version 이 바뀌었거나 실패 여부가 바뀐 경우에만 구독자에게 알린다.
export async function refresh() {
  if (inFlight) return; // 느린 응답 위에 요청이 쌓이지 않게 한다
  inFlight = true;
  try {
    const next = await fetchState();
    const changed = !current || next.version !== current.version || failed;
    if (!current || next.version !== current.version) current = deepFreeze(next);
    failed = false;
    if (changed) emit();
  } catch (e) {
    // 마지막 상태는 유지한다. 실패 여부만 알린다.
    const changed = !failed;
    failed = true;
    if (changed) emit();
  } finally {
    inFlight = false;
  }
}

// listener({ state, error }) — state 는 읽기 전용, 아직 한 번도 못 읽었으면 null.
// 구독 즉시 현재 값을 한 번 돌려준다. 반환값은 구독 해제 함수.
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
