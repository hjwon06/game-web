// 씬이 쓰는 그리기 도구. 상태는 갖지 않고, 만든 오브젝트를 돌려준다.
// Phaser 는 숫자 색을 쓴다. 이 COLORS 가 캔버스 안 색의 유일한 원본이다 (값은 styles.css 토큰과 같게 유지).
export const COLORS = {
  defectTint: 0xff5050,
  clear: 0xffffff,
  accent: 0x1e3a8a,
  badge: { running: 0x0f766e, stopped: 0x64748b, defect: 0xb91c1c },
};

export const BOX_SCALE = 2;
const BADGE_R = 6; // 12px 원
const BADGE_INSET = 10;
const OUTLINE = 2;

const frameOf = (v) => (Array.isArray(v) ? v[0] : v);

export function drawFloor(scene, grid, add) {
  const { floor } = scene.sp.tiles;
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
  // 불량 경고띠: 기계 바로 아래 줄(2칸). 상태가 불량일 때만 보인다.
  const tapeFrame = frameOf(scene.sp.tiles.warning);
  const tape = [];
  if (tapeFrame != null && m.y + 2 < scene.grid.h) {
    for (let i = 0; i < 2; i++) {
      const p = scene.px(m.x + i, m.y + 2);
      tape.push(add(scene.add.image(p.x, p.y, 'tiles', tapeFrame).setScale(scene.zoom).setDepth(2).setVisible(false)));
    }
  }
  return { spr, badge, tape, rect: r, cx, cy, state: null };
}

// 상태 배지: 기계 오른쪽 위의 12px 원 + 흰 기호. 가동 = 채운 원, 정지 = 두 줄, 불량 = 느낌표
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
  return scene.add.rectangle(0, 0, 1, 1).setStrokeStyle(OUTLINE, COLORS.accent).setFillStyle().setDepth(30).setVisible(false);
}

export function placeOutline(outline, v) {
  if (!v) return outline.setVisible(false);
  outline.setPosition(v.cx, v.cy).setSize(v.rect.w - OUTLINE, v.rect.h - OUTLINE).setVisible(true);
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
