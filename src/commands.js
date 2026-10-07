// 기계 조작 명령. 서버 POST /api/commands 로 보낸다. 같은 키로 재시도해도 서버가 멱등 처리한다.
import { refreshNow } from './state.js';

const URL = '/api/commands';
const TIMEOUT_MS = 4000;

async function post(body) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify(body),
      signal: ctrl.signal,
    });
    let json = null;
    try { json = await res.json(); } catch (e) { /* 본문 없음 */ }
    return { status: res.status, machine: (json && json.machine) || null };
  } finally {
    clearTimeout(t);
  }
}

// → { status, machine }. status 0 = 서버에 닿지 않음.
export async function sendCommand(machine, kind) {
  const body = {
    idempotency_key: crypto.randomUUID(),
    machine_code: machine.id,
    kind,
    base_version: machine.version,
  };
  let result;
  try {
    result = await post(body);
  } catch (e) {
    try { result = await post(body); } catch (e2) { result = { status: 0, machine: null }; }
  }
  await refreshNow();
  return result;
}
