// 씬이 쓰는 그리기 도구. 상태는 갖지 않고, 만든 오브젝트를 돌려준다.
// Phaser 는 숫자 색을 쓴다. 이 COLORS 가 캔버스 안 색의 유일한 원본이다 (값은 styles.css 토큰과 같게 유지).
export const COLORS = {
  brokenTint: 0xff5050,
  clear: 0xffffff,
  accent: 0x1e3a8a,
  badge: { running: 0x0f766e, stopped: 0x64748b, broken: 0xb91c1c },
};

// 캔버스 안 바닥·격자·선택 색은 여기 한 곳에만 둔다.
export const CANVAS_FLOOR = 0x2b3445; // #2B3445
export const CANVAS_GRID = 0x34405a; // #34405A, 칸(48px)마다 1px
export const CANVAS_SELECT = { inner: 0xf1f5f9, outer: 0x1e3a8a }; // 안 2px 실선 + 바깥 1px

export const BOX_SCALE = 2;
const BADGE_R = 6; // 12px 원
const BADGE_INSET = 10;
const DASH = 6;
const DASH_GAP = 4;

export function drawFloor(scene, grid, add) {
  const { floor } = scene.sp.tiles;
  if (!floor || floor.length === 0) {
    const w = grid.w * scene.cell;
    const h = grid.h * scene.cell;
    const g = add(scene.add.graphics().setDepth(0));
    g.fillStyle(CANVAS_FLOOR, 1).fillRect(0, 0, w, h);
    g.lineStyle(1, CANVAS_GRID, 1);
    for (let x = 0; x <= w; x += scene.cell) g.lineBetween(x + 0.5, 0, x + 0.5, h);
    for (let y = 0; y <= h; y += scene.cell) g.lineBetween(0, y + 0.5, w, y + 0.5);
    return;
  }
  for (let y = 0; y < grid.h; y++) {
    for (let x = 0; x < grid.w; x++) {
      const p = scene.px(x, y);
      add(scene.add.image(p.x, p.y, 'tiles', floor[(x + y) % floor.length]).setScale(scene.zoom).setDepth(0));
    }
  }
}

// 기계는 2x2 칸. (m.x, m.y) 가 왼쪽 위 칸이다.
export function machineRect(scene, m) {
  const c = scene.cell;
  return { x: m.x * c, y: m.y * c, w: c * 2, h: c * 2 };
}

export function drawMachine(scene, m, add) {
  const r = machineRect(scene, m);
  const cx = r.x + r.w / 2;
  const cy = r.y + r.h / 2;
  const spr = add(scene.add.image(cx, cy, 'tiles', scene.sp.tiles.machine[m.color]).setScale(scene.zoom * 2).setDepth(10));
  spr.setInteractive({ useHandCursor: true });
  const badge = add(scene.add.graphics().setDepth(15));
  // 고장 외곽선: 기계 둘레 2px 점선. 상태가 고장일 때만 보인다.
  const dash = add(scene.add.graphics().setDepth(12).setVisible(false));
  dash.lineStyle(2, COLORS.badge.broken, 1);
  const { x, y, w, h } = r;
  const edge = (x1, y1, x2, y2) => {
    const len = Math.hypot(x2 - x1, y2 - y1);
    const ux = (x2 - x1) / len;
    const uy = (y2 - y1) / len;
    for (let d = 0; d < len; d += DASH + DASH_GAP) {
      const e = Math.min(d + DASH, len);
      dash.lineBetween(x1 + ux * d, y1 + uy * d, x1 + ux * e, y1 + uy * e);
    }
  };
  edge(x + 1, y + 1, x + w - 1, y + 1);
  edge(x + w - 1, y + 1, x + w - 1, y + h - 1);
  edge(x + w - 1, y + h - 1, x + 1, y + h - 1);
  edge(x + 1, y + h - 1, x + 1, y + 1);
  return { spr, badge, dash, rect: r, cx, cy, state: null };
}

// 상태 배지: 기계 오른쪽 위의 12px 원 + 흰 기호. 가동 = 채운 원, 정지 = 두 줄, 고장 = 느낌표
export function drawBadge(v, state) {
  const g = v.badge;
  const bx = v.rect.x + v.rect.w - BADGE_INSET;
  const by = v.rect.y + BADGE_INSET;
  g.clear();
  g.fillStyle(COLORS.badge[state] ?? COLORS.badge.stopped, 1).fillCircle(bx, by, BADGE_R);
  g.fillStyle(COLORS.clear, 1);
  if (state === 'running') g.fillCircle(bx, by, 3);
  else if (state === 'stopped') g.fillRect(bx - 3, by - 3, 2, 6).fillRect(bx + 1, by - 3, 2, 6);
  else g.fillRect(bx - 1, by - 4, 2, 5).fillRect(bx - 1, by + 2, 2, 2);
}

export function makeOutline(scene) {
  return scene.add.graphics().setDepth(30).setVisible(false);
}

// 두 겹: 안쪽 2px 밝은 실선 + 바깥 1px 남색
export function placeOutline(outline, v) {
  outline.clear();
  if (!v) return outline.setVisible(false);
  const { x, y, w, h } = v.rect;
  outline.lineStyle(2, CANVAS_SELECT.inner, 1).strokeRect(x + 1, y + 1, w - 2, h - 2);
  outline.lineStyle(1, CANVAS_SELECT.outer, 1).strokeRect(x - 0.5, y - 0.5, w + 1, h + 1);
  return outline.setVisible(true);
}

// 벨트: 칸마다 타일을 깔고, 상자가 지나갈 경로(pts)는 마지막 칸에서 기계 가장자리까지 잇는다.
export function buildBelt(scene, c, f, add) {
  const { tiles } = scene.sp;
  const target = f.machines.find((m) => m.id === c.to);
  const pts = c.path.map(([x, y]) => scene.px(x, y));
  if (target) {
    const r = machineRect(scene, target);
    const last = pts[pts.length - 1];
    pts.push({ x: Math.min(Math.max(last.x, r.x), r.x + r.w), y: Math.min(Math.max(last.y, r.y), r.y + r.h) });
  }
  const cells = c.path.map((_p, i) => {
    const cur = pts[i];
    const next = pts[i + 1];
    const key = c.path.length === 1 ? 'belt_mid' : i === 0 ? 'belt_left' : i === c.path.length - 1 ? 'belt_right' : 'belt_mid';
    const spr = add(scene.add.image(cur.x, cur.y, 'tiles', tiles[key][0]).setScale(scene.zoom).setDepth(1));
    if (next) spr.setAngle(next.x < cur.x ? 180 : next.y > cur.y ? 90 : next.y < cur.y ? -90 : 0);
    return { spr, frames: tiles[key] };
  });
  const cum = [0];
  for (let i = 1; i < pts.length; i++) cum.push(cum[i - 1] + Math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y));
  return { id: c.id, to: c.to, pts, cum, total: cum[cum.length - 1], cells, boxes: [], running: false, phase: 0, sinceSpawn: 0, boxFrame: tiles.box };
}

export function addBox(scene, b, s, add) {
  const spr = add(scene.add.image(0, 0, 'tiles', b.boxFrame).setScale(BOX_SCALE).setDepth(5));
  const box = { s, spr };
  placeBox(b, box);
  b.boxes.push(box);
}

export function placeBox(b, box) {
  let i = 1;
  while (i < b.cum.length - 1 && b.cum[i] < box.s) i++;
  const a = b.pts[i - 1];
  const z = b.pts[i];
  const span = b.cum[i] - b.cum[i - 1] || 1;
  const t = Math.min(1, (box.s - b.cum[i - 1]) / span);
  box.spr.setPosition(a.x + (z.x - a.x) * t, a.y + (z.y - a.y) * t);
}
