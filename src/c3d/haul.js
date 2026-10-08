// 3D-③ 운반 주체: 지게차 2대(상시) · 트럭 최대 2대 · 검사 작업자 1명 = 동시에 최대 5. 화물은 지게차에 실려서만 움직인다.
// src/campus/campus_haul.js 의 규칙을 3D 로 옮겼다: 위치는 작업(tasks)의 started_at~expected_finish_at(4~10초)을 서버 시계로 보간하고,
// 모든 위치·방향·포크 높이는 "시계의 함수"다(프레임 누적 없음) → capture 모드에서 step 크기와 무관하게 같은 값이 나온다.
import * as THREE from 'three';
import { S, srvNow, resCode, bKeyOf, arrive, dataReady, itemColor } from './data.js';
import { forklift, setForks, pallet, setShutter, worker } from './models.js';
import { truck, setTrailerColor } from './kenney.js';
import { binSlots, dockSpots, hideDemo } from './campus.js';
import { GW } from './layout.js';

const VIS_MIN = 4000, VIS_MAX = 10000, FORK_N = 2, TRUCK_MAX = 2, ENTER_MS = 5000, LEAVE_MS = 4000, HOLD_MS = 2000, PRUNE_MS = 30000;
const FORK_KINDS = ['putaway', 'pick', 'feed'];
// 지게차 차체 길이 ≈ 2.5(마스트 끝~카운터웨이트) + 여유 0.6 = 3.1 이상. 방향은 건물 안으로 들어가지 않는 쪽(기본 남쪽)
const SLOT_GAP = 3.2, SPREAD = { ship: [-1, 0], qc: [-1, 0] };
const RET_SPEED = 6, LIFT = .35, FLOOR_Y = .06, WORKER_AT = [31, 30.2];

// ---- 도로 그래프(campus_flow.js 와 같은 값. 2D 그리드 (x, y) = 3D (x, z)) ----
const NODE = { gate: [44.5, 16.3], j1: [26.2, 16.3], j2: [26.2, 12.5], j3: [14, 12.5], j4: [3.5, 12.5], j5: [26.2, 26.5], j6: [39, 16.3],
  mat: [14, 7.5], prod: [3.5, 17.6], qc: [27.6, 26.5], ship: [39, 18.4], scrap: [35.6, 26.5], office: [12.6, 7] };
const EDGE = [['gate', 'j6'], ['j6', 'j1'], ['j6', 'ship'], ['j1', 'j2'], ['j1', 'j5'], ['j2', 'j3'], ['j3', 'j4'], ['j3', 'mat'], ['j4', 'prod'], ['j5', 'qc'], ['qc', 'scrap'], ['j3', 'office']];
const ADJ = {};
EDGE.forEach(([a, b]) => { (ADJ[a] = ADJ[a] || []).push(b); (ADJ[b] = ADJ[b] || []).push(a); });
function routeNames(a, b) {
  if (a === b) return [a];
  const prev = { [a]: null }, q = [a];
  while (q.length) { const n = q.shift(); if (n === b) break; (ADJ[n] || []).forEach(m => { if (!(m in prev)) { prev[m] = n; q.push(m); } }); }
  const path = []; for (let n = b; n != null; n = prev[n]) path.unshift(n);
  return path;
}

// ---- 폴리라인: 길이·위치·방향 ----
const polyLen = pts => pts.slice(1).reduce((s, p, i) => s + Math.hypot(p[0] - pts[i][0], p[1] - pts[i][1]), 0);
const mk = pts => ({ pts, len: polyLen(pts) });
function at(P, s) { // 호 길이 s 지점
  let d = Math.max(0, Math.min(P.len, s));
  for (let i = 0; i < P.pts.length - 1; i++) {
    const a = P.pts[i], b = P.pts[i + 1], l = Math.hypot(b[0] - a[0], b[1] - a[1]);
    if (d <= l && l > 0) return [a[0] + (b[0] - a[0]) * d / l, a[1] + (b[1] - a[1]) * d / l];
    d -= l;
  }
  return P.pts[P.pts.length - 1];
}
// 진행 방향(rotation.y). 앞뒤 ±w 의 현 방향이라 모퉁이에서 부드럽게 돈다
function head(P, s, w = .8) {
  const a = at(P, s - w), b = at(P, s + w);
  let dx = b[0] - a[0], dz = b[1] - a[1];
  if (Math.hypot(dx, dz) < 1e-4) { const n = P.pts.length; dx = P.pts[n - 1][0] - P.pts[Math.max(0, n - 2)][0]; dz = P.pts[n - 1][1] - P.pts[Math.max(0, n - 2)][1]; }
  return Math.atan2(dx, dz);
}
const lerpA = (a, b, t) => a + Math.atan2(Math.sin(b - a), Math.cos(b - a)) * t;
const ease = t => t * t * (3 - 2 * t);
const clamp01 = v => Math.max(0, Math.min(1, v));

// ---- 작업 → 길 ----
// side = { code, b }. 칸 앞(바닥)에서 도로 노드까지의 점 목록을 돌려준다
const avgX = bin => bin.reduce((s, v) => s + v.x, 0) / bin.length;
const hintNode = side => { const b = side.b || 'mat'; return b === 'prod' ? 'j3' : b; };
function exit(side, i, hint) {
  const b = side.b || 'mat', bin = binSlots[side.code];
  if (b === 'mat' && bin) { // 자재창고 칸: 남쪽 앞마당 → 도로(y 12.5). 가는 쪽이 동쪽이면 j2, 서쪽이면 j3
    const x = avgX(bin), names = routeNames('mat', hint), node = names[2] === 'j2' ? 'j2' : 'j3';
    return { pts: [[x, 10.6], [x, NODE.j3[1]], NODE[node]], node };
  }
  if (b === 'ship' && bin) { const x = avgX(bin); return { pts: [[x, 17.7], [x, NODE.j6[1]], NODE.j6], node: 'j6' }; } // 출하장 칸: 북쪽 길
  if (b === 'prod') return { pts: [[12.7 + i, 16.6], [13.2, 15.5], [13.2, NODE.j3[1]], NODE.j3], node: 'j3' }; // 생산동 북쪽 출입 틈(x 12~14.4)
  const n = NODE[b] ? b : 'mat', d = SPREAD[n] || [0, 1], g = i * SLOT_GAP; // 같은 노드를 쓰는 지게차는 번호마다 한 칸씩 비켜 선다
  return { pts: i ? [[NODE[n][0] + d[0] * g, NODE[n][1] + d[1] * g], NODE[n]] : [NODE[n]], node: n };
}
function pathBetween(a, b, i) {
  const A = exit(a, i, hintNode(b)), B = exit(b, i, hintNode(a));
  let pts;
  if ((a.b || 'mat') === 'mat' && (b.b || 'mat') === 'mat' && binSlots[a.code] && binSlots[b.code]) pts = [...A.pts.slice(0, 2), ...B.pts.slice(0, 2).reverse()];
  else pts = [...A.pts, ...routeNames(A.node, B.node).map(n => NODE[n]), ...B.pts.slice().reverse()];
  pts = pts.filter((p, k) => k === 0 || Math.hypot(p[0] - pts[k - 1][0], p[1] - pts[k - 1][1]) > .01);
  if (pts.length < 2) pts = [pts[0], [pts[0][0] + .05, pts[0][1]]];
  return pts;
}
const homeSide = f => { const r = f.res || {}; return { code: '', b: bKeyOf(r.home_location_code || (r.home_location && r.home_location.code) || '', r.home_building) || 'mat' }; };

function visWin(t) { // 화면에 보이는 운반 구간(서버 ms). 길이를 4~10초로 맞춘다
  if (t.t0 == null) return null;
  const end = Math.max(t.t1 || 0, t.tf || 0) || t.t0 + VIS_MIN, dur = end - t.t0;
  return dur > VIS_MAX ? [end - VIS_MAX, end] : dur < VIS_MIN ? [t.t0, t.t0 + VIS_MIN] : [t.t0, end];
}

// ---- 지게차 ----
// 한 작업의 타임라인(서버 ms): 접근(빈 포크) → 올림(P) → 운반 → 내림(D) → 홈 복귀. 접근·운반은 같은 속도로 달린다.
function setWin(tl, w) { tl.w0 = w[0]; tl.w1 = w[1]; tl.P = tl.D = Math.min(700, (w[1] - w[0]) * .1); }
function retPoseAt(tl, t) { // 복귀 구간의 위치 (t < w1 이면 도착 지점)
  const u = clamp01((t - tl.w1) / tl.retDur), s = u * tl.ret.len;
  return { p: at(tl.ret, s), h: head(tl.ret, s), mv: u > 0 && u < 1 };
}
function buildTL(f, act, w, prev) {
  const home = homeSide(f), from = act.from, to = act.to;
  const car = mk(pathBetween(from, to, f.i)), ret = mk(pathBetween(to, home, f.i));
  const org = prev ? retPoseAt(prev, w[0]).p : exit(home, f.i, hintNode(from)).pts[0], orgSide = prev ? prev.toSide : home;
  const apPts = [org, ...pathBetween(orgSide, from, f.i).slice(1)], ap = mk(apPts);
  const tl = { id: act.id, car, ret, retDur: Math.max(600, ret.len / RET_SPEED * 1000), ap: ap.len > .05 ? ap : null, toSide: to };
  setWin(tl, w);
  return tl;
}
function forkPose(tl, t) { // → { p, h, fv, load, mv }
  const tau = t - tl.w0, dur = tl.w1 - tl.w0, { ap, car, P, D } = tl;
  const La = ap ? ap.len : 0, Lc = car.len, M = dur - P - D, ta = M * La / (La + Lc), tc = M - ta;
  const hc0 = head(car, 0), hc1 = head(car, car.len), ha1 = ap ? head(ap, La) : hc0, ha0 = ap ? head(ap, 0) : hc0;
  if (tau < 0) return { p: ap ? ap.pts[0] : car.pts[0], h: ha0, fv: 0, load: false, mv: false };
  if (tau < ta) { const s = tau / ta * La; return { p: at(ap, s), h: head(ap, s), fv: 0, load: false, mv: true }; }
  if (tau < ta + P) { const q = (tau - ta) / P; return { p: car.pts[0], h: lerpA(ha1, hc0, ease(q)), fv: LIFT * q, load: true, mv: false }; }
  if (tau < ta + P + tc) { const s = (tau - ta - P) / tc * Lc; return { p: at(car, s), h: head(car, s), fv: LIFT, load: true, mv: true }; }
  if (tau < dur) { const q = (tau - ta - P - tc) / D; return { p: car.pts[car.pts.length - 1], h: hc1, fv: LIFT * (1 - q), load: true, mv: false }; }
  const r = retPoseAt(tl, t); // 닿은 순간 화물은 칸으로 넘어가고(칸 팔레트가 바뀐다) 지게차는 홈으로 돌아간다
  return { p: r.p, h: r.mv || t - tl.w1 < tl.retDur ? r.h : head(tl.ret, tl.ret.len), fv: 0, load: false, mv: r.mv };
}
function activeTask(f) {
  let best = null;
  S.tasks.forEach(t => {
    if (!FORK_KINDS.includes(t.kind) || t.t0 == null || resCode(t) !== f.code) return;
    if (t.status !== 'started' && !(t.status === 'done' && !S.arrived.has(t.id))) return;
    if (!best || (t.status === 'started' && best.status !== 'started') || (t.status === best.status && t.t0 > best.t0)) best = t;
  });
  return best;
}
const byCode = (a, b) => a.code < b.code ? -1 : 1;

// ---- 트럭 ----
function wantTrucks(now) { // 지금 트럭이 서 있어야 하는 도크: 시작했거나 곧 시작할 unload·load 가 있는 자원
  const want = new Map();
  S.tasks.forEach(t => {
    if (t.kind !== 'unload' && t.kind !== 'load') return;
    if (!(t.status === 'started' || (t.status === 'planned' && t.planned != null && t.planned <= now + 15000))) return;
    want.set(t.rid != null ? 'r' + t.rid : 'c' + t.kind, { inb: t.kind === 'unload', rid: t.rid, key: t.ref || t.product });
  });
  return want;
}
function truckPath(inb, spot) {
  const { x, z } = spot.position, road = [[GW + 14, 16.3], [44.5, 16.3]];
  return mk(inb ? [...road, [39, 16.3], [26.2, 16.3], [26.2, 14.1], [x + 2.4, 14.1], [x, z]] // 입고: 정문 → 큰길 → 자재창고 앞 → 후진 진입 자세
    : [...road, [44.5, 27.9], [x + 2.4, 27.9], [x, z]]);                                      // 출하: 정문 → 출하장 동쪽 → 남쪽 길
}
function truckPose(k, t) {
  const L = k.path.len, u = k.st === 'enter' ? clamp01((t - k.t0) / ENTER_MS) : k.st === 'stand' ? 1 : 1 - clamp01((t - k.t0) / LEAVE_MS), s = u * L;
  const p = at(k.path, s), last = k.path.pts, ll = Math.hypot(last[last.length - 1][0] - last[last.length - 2][0], last[last.length - 1][1] - last[last.length - 2][1]);
  const tr = head(k.path, s, 1.6) + (k.st === 'leave' ? Math.PI : 0); // 나갈 때는 경로를 거꾸로 달린다
  const w = ease(clamp01((s - (L - ll)) / ll)); // 마지막 구간에서 도크 자세(문 쪽으로 후미)로 돌아선다
  return { p, h: lerpA(tr, k.spot.rotationY, w) };
}
function shutterOf(k, t) {
  if (k.st === 'enter') return clamp01(((t - k.t0) - (ENTER_MS - 700)) / 700);
  if (k.st === 'stand') return 1;
  return 1 - clamp01((t - k.t0) / 700);
}

// ---- 조립 ----
// opsTrucks: ops.trucks 목록을 돌려주는 함수(3D-⑤ ui 가 폴링한다). 트럭 식별은 여기서 no(PO-…/SO-…)를 도크 코드로 맞춰 쓴다.
export function createHaul(parent, { kenneyReady, opsTrucks = () => [] }) {
  const forks = [], trucks = [], doorV = {};
  let truckOK = false;
  kenneyReady.then(() => { truckOK = true; }, () => {});

  for (let i = 0; i < FORK_N; i++) {
    const obj = forklift(), pal = pallet();
    pal.getObjectByName('boxes').material = new THREE.MeshStandardMaterial({ color: 0xC98A4B, roughness: .85 }); // 지게차마다 자기 품목색
    pal.visible = false;
    obj.getObjectByName('load').add(pal);
    obj.visible = false;
    parent.add(obj);
    const f = { i, code: 'F-0' + (i + 1), res: null, obj, pal, tl: null, act: null, pose: null };
    obj.userData.pick = () => ({ type: 'forklift', code: f.code }); // nav.js 레이캐스트가 읽는다
    forks.push(f);
  }
  const man = worker();
  man.position.set(WORKER_AT[0], FLOOR_Y, WORKER_AT[1]);
  man.rotation.y = Math.PI; // 검사동(북쪽)을 본다
  man.visible = false;
  parent.add(man);
  let inspecting = null;

  function stepFork(f, srv) {
    const act = activeTask(f);
    f.act = act;
    if (act) {
      const w = visWin(act);
      if (!f.tl || f.tl.id !== act.id) f.tl = buildTL(f, act, w, f.tl); else setWin(f.tl, w);
    } else if (f.tl && srv < f.tl.w1) f.tl.w1 = Math.max(f.tl.w0 + 1, srv); // 작업이 사라졌다(취소): 그 자리에서 내려놓고 홈으로
    if (f.tl) f.pose = forkPose(f.tl, srv);
    else { const p = exit(homeSide(f), f.i, 'mat').pts[0]; f.pose = { p, h: 0, fv: 0, load: false, mv: false }; }
    const { p, h, fv, load } = f.pose;
    f.obj.position.set(p[0], FLOOR_Y, p[1]);
    f.obj.rotation.y = h;
    setForks(f.obj, fv);
    f.pal.visible = load;
    if (load && f.act) f.pal.getObjectByName('boxes').material.color.set(f.act.color);
  }
  function ensureForks() {
    const rs = S.res.filter(r => r.kind === 'forklift').sort(byCode);
    forks.forEach((f, i) => { const r = rs[i]; if (r) { f.code = r.code; f.res = r; } });
  }

  // 3D 트럭 ↔ ops.trucks: 먼저 도크 코드가 같은 것, 그다음 같은 방향(입고/출하)의 아직 안 짝지은 현장 트럭 순서대로
  function assignNos() {
    const list = opsTrucks().filter(x => x.status !== 'en_route'), used = new Set();
    trucks.forEach(k => { const x = list.find(y => y.dock === k.dock); k.code = x ? String(x.no) : ''; if (x) used.add(k.code); });
    trucks.forEach(k => {
      if (k.code) return;
      const x = list.find(y => (y.type === 'in') === k.inb && !used.has(String(y.no)));
      if (x) { k.code = String(x.no); used.add(k.code); }
    });
  }

  function tickTrucks(t, srv) {
    const want = wantTrucks(srv);
    want.forEach((w, key) => {
      const k = trucks.find(x => x.key === key);
      if (k) { k.last = t; return; }
      if (trucks.length >= TRUCK_MAX || !truckOK) return;
      const slot = [0, 1].find(s => !trucks.some(x => x.inb === w.inb && x.slot === s));
      const dock = `DOCK-${w.inb ? 'IN' : 'OUT'}-0${(slot ?? 0) + 1}`, spot = dockSpots[dock];
      if (slot == null || !spot) return;
      let obj;
      try { obj = truck(w.inb ? 'truck' : 'delivery', itemColor(w.key)); } catch (e) { truckOK = false; return; } // Kenney 로드 실패(main.js 가 이미 로그를 남긴다)
      parent.add(obj);
      const nk = { key, inb: w.inb, slot, dock, spot, obj, path: truckPath(w.inb, spot), st: 'enter', t0: t, last: t, code: '' }; // code = PO/SO 번호(assignNos)
      obj.userData.pick = () => nk.code ? { type: 'truck', code: nk.code } : { type: 'site', code: nk.inb ? 'mat' : 'ship' }; // 번호를 아직 모르면 도크가 있는 건물
      trucks.push(nk);
    });
    for (let i = trucks.length - 1; i >= 0; i--) {
      const k = trucks[i];
      if (k.st === 'enter' && t - k.t0 >= ENTER_MS) { k.st = 'stand'; k.t0 = k.t0 + ENTER_MS; }
      if (k.st === 'stand' && t - k.last > HOLD_MS) { k.st = 'leave'; k.t0 = k.last + HOLD_MS; }
      if (k.st === 'leave' && t - k.t0 >= LEAVE_MS) { parent.remove(k.obj); k.obj.userData.trailer.material.dispose(); trucks.splice(i, 1); }
    }
    assignNos();
    const open = {};
    trucks.forEach(k => {
      const { p, h } = truckPose(k, t);
      k.obj.position.set(p[0], 0, p[1]);
      k.obj.rotation.y = h;
      k.pos = p;
      open[k.dock] = Math.max(open[k.dock] || 0, shutterOf(k, t));
    });
    Object.keys(dockSpots).forEach(code => { // 트럭이 없는 도크는 닫는다
      const v = open[code] || 0;
      if (doorV[code] !== v) { doorV[code] = v; setShutter(dockSpots[code].door, v); }
    });
  }

  function tick(t) { // t = main.js 시계(ms)
    if (!dataReady()) return;
    hideDemo(); // 실데이터가 들어오면 정지 소품을 치운다(Kenney 트럭은 늦게 붙을 수 있어 매번 비운다)
    ensureForks();
    const srv = srvNow();
    S.tasks.forEach((k, id) => {
      if (k.status === 'done' && !S.arrived.has(id)) { const w = visWin(k); if (!w || srv >= w[1]) arrive(k); } // 지게차가 닿은 순간 = 운반 구간이 끝난 순간
      const old = k.tf || k.t1 || k.planned || srv;
      if (((k.status === 'done' && S.arrived.has(id)) || k.status === 'cancelled') && srv - old > PRUNE_MS) { S.tasks.delete(id); S.arrived.delete(id); }
    });
    forks.forEach(f => { stepFork(f, srv); f.obj.visible = true; });
    tickTrucks(t, srv);
    inspecting = null;
    S.tasks.forEach(k => { if (k.kind === 'inspect' && k.status === 'started') inspecting = k; });
    man.visible = !!inspecting;
    man.scale.y = 1 + .02 * Math.sin(t / 180);
  }

  // 관찰용(루미 AC): 지게차 위치·작업, 트럭 상태, 동시에 보이는 운반 주체 수
  function state() {
    const r2 = v => Math.round(v * 100) / 100;
    return {
      forks: forks.map(f => ({ code: f.code, task: f.act ? f.act.id : null, kind: f.act ? f.act.kind : null, pos: f.pose ? [r2(f.pose.p[0]), r2(f.pose.p[1])] : null,
        loaded: !!(f.pose && f.pose.load), moving: !!(f.pose && f.pose.mv), forksUp: f.pose ? r2(f.pose.fv / LIFT) : 0 })),
      trucks: trucks.map(k => ({ code: k.code, state: k.st, dock: k.dock, inbound: k.inb, shutter: doorV[k.dock] || 0, pos: k.pos ? [r2(k.pos[0]), r2(k.pos[1])] : null })),
      inspector: !!inspecting,
      carriers: forks.filter(f => f.obj.visible).length + trucks.length + (inspecting ? 1 : 0),
    };
  }
  return { tick, state, list: () => ({ forks, trucks }) }; // nav.js 가 개체를 찾는다(살아 있는 배열)
}
