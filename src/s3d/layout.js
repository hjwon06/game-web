// 증권 거리 배치. 공장 건물 자리(c3d/layout.js)를 그대로 쓴다: office → 증권사 · mat → 거래소 · ship → 결제원 · HALL → 투자자 동네 · maint → 숫자 판. qc · util 자리는 비운다.
import { PX, HALL, DOCKS } from '../c3d/layout.js';
export { GW, GH, CENTER, HALL, OPEN_WALL } from '../c3d/layout.js';

export const NAVY = 0x1E3A5F;
export const WALL = 0xF8FAFC;

export const BUILDINGS = [
  { id: 'broker', name: '증권사', x: 5, y: 4, w: 7, d: 6, h: 96 * PX, top: '#E9ECF1' },
  { id: 'exchange', name: '거래소', x: 15, y: 3, w: 8, d: 7, open: true, gap: { z0: 7.6, z1: 9.6 } }, // 서쪽 벽의 출입구(주문이 들어오는 틈)
  { id: 'clearing', name: '결제원', x: 35, y: 18.4, w: 8, d: 5.4, open: true },
];
export const byId = id => BUILDINGS.find(b => b.id === id);

// 종목: 서버 Seed::EQUITIES 순서. color 는 상자 · 원판 색
export const STOCKS = [
  { code: 'VELEC', name: '가상전자', color: '#0E7C86' },
  { code: 'VBIO', name: '가상바이오', color: '#4E8F5F' },
  { code: 'VBANK', name: '가상은행', color: '#5B7083' },
  { code: 'VCONS', name: '가상건설', color: '#8B6F47' },
  { code: 'VGAME', name: '가상게임', color: '#A0577C' },
];
export const STOCK_IDX = Object.fromEntries(STOCKS.map((s, i) => [s.code, i]));
export const REJECT_COLOR = '#9CA3AF';

// 거래소 안 종목 칸: 칸마다 가로 2 × 세로(z) 5 × 4층 = 40 상자
export const EX = (() => {
  const b = byId('exchange'), cx = b.x + b.w / 2;
  return { cx, cz: b.y + b.d / 2, slotX: STOCKS.map((_, i) => cx + (i - 2) * 1.5), pileZ0: 4.4, door: [b.x, 8.6], front: 7.2 };
})();
export const BOX = { w: .44, h: .4, pitchX: .5, pitchZ: .46, perLayer: 10, max: 40 };

// 투자자 동네: HALL 안 8 × 5 집. 가운데 세로 길(x 12~14.4)은 북쪽 출입 틈에서 이어진다 → 서쪽 3열 · 동쪽 5열
export const AISLE_X = 13.2;
export const HOUSE_N = 40;
const COLS = [6.4, 8.25, 10.1, 15.1, 16.95, 18.8, 20.65, 22.5];
const ROW_Z = [17.4, 19.5, 21.6, 23.7, 25.8];
export const HOUSES = Array.from({ length: HOUSE_N }, (_, i) => ({ i, x: COLS[i % 8], z: ROW_Z[Math.floor(i / 8)] }));
export const HOUSE = { w: 1.3, d: 1.3, h: .9 };
export const DOOR_GAP = 1.05; // 집 앞 골목: 집 중심에서 북쪽으로 이만큼
export const NEIGHBOR = { x: HALL.x, y: HALL.y, w: HALL.w, d: HALL.d, cx: HALL.x + HALL.w / 2, cz: HALL.y + HALL.d / 2 };

// 결제원 남쪽 도크 문 2개(공장 DOCK-OUT 자리)
export const CLEARING_DOCKS = DOCKS.find(d => d.building === 'ship').slots;

// 숫자 판: 정비동 자리(x 28~33, y 3~8)에 남쪽을 보고 선다
export const BOARD = { x: 30.5, z: 5.5, w: 5, h: 3.4, y0: 1.2 };

// ---- 도로 그래프: c3d/haul.js 의 NODE · EDGE · routeNames · at · head 에서 복사(haul.js 는 export 하지 않는다) ----
export const NODE = { gate: [44.5, 16.3], j1: [26.2, 16.3], j2: [26.2, 12.5], j3: [14, 12.5], j4: [3.5, 12.5], j5: [26.2, 26.5], j6: [39, 16.3],
  mat: [14, 7.5], prod: [3.5, 17.6], qc: [27.6, 26.5], ship: [39, 18.4], scrap: [35.6, 26.5], office: [12.6, 7] };
const EDGE = [['gate', 'j6'], ['j6', 'j1'], ['j6', 'ship'], ['j1', 'j2'], ['j1', 'j5'], ['j2', 'j3'], ['j3', 'j4'], ['j3', 'mat'], ['j4', 'prod'], ['j5', 'qc'], ['qc', 'scrap'], ['j3', 'office']];
const ADJ = {};
EDGE.forEach(([a, b]) => { (ADJ[a] = ADJ[a] || []).push(b); (ADJ[b] = ADJ[b] || []).push(a); });
export function routeNames(a, b) {
  if (a === b) return [a];
  const prev = { [a]: null }, q = [a];
  while (q.length) { const n = q.shift(); if (n === b) break; (ADJ[n] || []).forEach(m => { if (!(m in prev)) { prev[m] = n; q.push(m); } }); }
  const path = []; for (let n = b; n != null; n = prev[n]) path.unshift(n);
  return path;
}
export const nodes = (a, b) => routeNames(a, b).map(n => NODE[n]);

const polyLen = pts => pts.slice(1).reduce((s, p, i) => s + Math.hypot(p[0] - pts[i][0], p[1] - pts[i][1]), 0);
export const mk = pts => ({ pts, len: polyLen(pts) });
export function at(P, s) { // 호 길이 s 지점
  let d = Math.max(0, Math.min(P.len, s));
  for (let i = 0; i < P.pts.length - 1; i++) {
    const a = P.pts[i], b = P.pts[i + 1], l = Math.hypot(b[0] - a[0], b[1] - a[1]);
    if (d <= l && l > 0) return [a[0] + (b[0] - a[0]) * d / l, a[1] + (b[1] - a[1]) * d / l];
    d -= l;
  }
  return P.pts[P.pts.length - 1];
}
// 진행 방향(rotation.y). 앞뒤 ±w 의 현 방향이라 모퉁이에서 부드럽게 돈다
export function head(P, s, w = .8) {
  const a = at(P, s - w), b = at(P, s + w);
  let dx = b[0] - a[0], dz = b[1] - a[1];
  if (Math.hypot(dx, dz) < 1e-4) { const n = P.pts.length; dx = P.pts[n - 1][0] - P.pts[Math.max(0, n - 2)][0]; dz = P.pts[n - 1][1] - P.pts[Math.max(0, n - 2)][1]; }
  return Math.atan2(dx, dz);
}
export const lerpA = (a, b, t) => a + Math.atan2(Math.sin(b - a), Math.cos(b - a)) * t;
export const ease = t => t * t * (3 - 2 * t);
export const clamp01 = v => Math.max(0, Math.min(1, v));
