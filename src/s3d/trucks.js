// 결제 트럭. settlements 에 처음 보는 settled 날짜가 오면 트럭 2대가 결제원 도크 → 남쪽 길 → 도로 그래프 → 동네 → 도크(실시간 10초).
// 서 있는 동안(출발 전 · 돌아온 뒤) 도크 셔터가 열린다. 시작 시각 = 그 결제의 settled_at(가상 시각). 위치는 P 의 함수.
import { dockDoor, setShutter } from '../c3d/models.js';
import { loadTrucks, truck, TRUCK_LEN } from '../c3d/kenney.js';
import { S, speedNow } from './data.js';
import { CLEARING_DOCKS, byId, nodes, mk, at, head, lerpA, ease, clamp01, AISLE_X } from './layout.js';

const RUN_MS = 10000;      // 한 번의 실시간
// 트럭 k 의 일정(실시간 초): 출발 · 동네 도착 · 동네 출발 · 도크 도착
const PLAN = [[.6, 4.0, 5.4, 8.8], [1.1, 4.5, 5.9, 9.3]];
const STOP_Z = [22.4, 18.8]; // 동네 안 길(x 12~14.4)에 한 대씩 앞뒤로 선다
const SHUT_S = .4;           // 셔터가 여닫히는 시간(초)
const SOUTH_Y = 27.9;        // 결제원 남쪽 길

function routeFor(dockX, stopZ) {
  const standZ = byId('clearing').y + byId('clearing').d + .3 + TRUCK_LEN / 2;
  return mk([[dockX, standZ], [dockX, SOUTH_Y], [26.2, SOUTH_Y], ...nodes('j5', 'j3'), [AISLE_X, 12.5], [AISLE_X, 15], [AISLE_X, stopZ]]);
}

export function createTrucks(parent) {
  const zEdge = byId('clearing').y + byId('clearing').d;
  const docks = CLEARING_DOCKS.map((s, k) => {
    const door = dockDoor(`결제 ${k + 1}`), x = s.x + s.w / 2;
    door.position.set(x, 0, zEdge);
    setShutter(door, 0);
    parent.add(door);
    const out = routeFor(x, STOP_Z[k]), back = mk(out.pts.slice().reverse());
    return { door, x, out, back, v: 0, obj: null };
  });
  loadTrucks().then(() => {
    docks.forEach(d => { d.obj = truck('truck'); d.obj.visible = false; parent.add(d.obj); });
  }, e => console.error('[s3d] truck load failed', e));

  const seen = new Set(), runs = [];
  let inited = false, shown = { visible: 0, shutter: docks.map(() => 0) };

  function watch(P) {
    if (!S.ok) return;
    S.settlements.forEach(s => {
      if (s.status !== 'settled' || seen.has(s.settle_date)) return;
      seen.add(s.settle_date);
      if (!inited) return; // 처음 받은 목록은 이미 지난 일이다
      const t0 = s.settled_at ? Date.parse(s.settled_at) : P;
      runs.push({ date: s.settle_date, t0: isNaN(t0) ? P : t0, dur: RUN_MS * speedNow() });
    });
    inited = true;
  }

  // sec(실시간 초)에서 트럭 k 의 자세와 셔터 값
  function pose(d, k, sec) {
    const [o0, o1, b0, b1] = PLAN[k], { out, back } = d;
    let p, h, shut;
    if (sec < o0) { p = out.pts[0]; h = 0; shut = 1 - clamp01((sec - (o0 - SHUT_S)) / SHUT_S); }
    else if (sec < o1) { const s = (sec - o0) / (o1 - o0) * out.len; p = at(out, s); h = head(out, s, 1.6); shut = 0; }
    else if (sec < b0) { p = out.pts[out.pts.length - 1]; h = 0; shut = 0; }
    else if (sec < b1) {
      const s = (sec - b0) / (b1 - b0) * back.len, ll = Math.hypot(back.pts.at(-1)[0] - back.pts.at(-2)[0], back.pts.at(-1)[1] - back.pts.at(-2)[1]);
      p = at(back, s);
      h = lerpA(lerpA(0, head(back, s, 1.6), ease(clamp01(s / 1.5))), 0, ease(clamp01((s - (back.len - ll)) / ll))); // 동네에서 돌아서고, 도크에서 후미를 문 쪽으로
      shut = 0;
    } else { p = back.pts.at(-1); h = 0; shut = clamp01((sec - b1) / SHUT_S); }
    return { p, h, shut };
  }

  function tick(P) {
    if (P == null) return;
    watch(P);
    let run = null;
    runs.forEach(r => { const u = (P - r.t0) / r.dur; if (u >= 0 && u <= 1 && (!run || r.t0 > run.t0)) run = r; });
    while (runs.length > 8 && (P - runs[0].t0) / runs[0].dur > 1) runs.shift();
    let visible = 0;
    docks.forEach((d, k) => {
      let v = 0;
      if (run && d.obj) {
        const { p, h, shut } = pose(d, k, (P - run.t0) / run.dur * RUN_MS / 1000);
        d.obj.position.set(p[0], 0, p[1]);
        d.obj.rotation.y = h;
        d.obj.visible = true;
        visible++; v = shut;
      } else if (d.obj) d.obj.visible = false;
      if (d.v !== v) { d.v = v; setShutter(d.door, v); }
    });
    shown = { visible, shutter: docks.map(d => Math.round(d.v * 100) / 100) };
  }

  return { tick, state: () => ({ ...shown, runs: seen.size }) };
}
