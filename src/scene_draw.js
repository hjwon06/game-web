// 씬이 쓰는 그리기 도구. 상태는 갖지 않고, 만든 오브젝트를 돌려준다.
// Phaser 는 숫자 색을 쓴다. 이 COLORS 가 캔버스 안 색의 유일한 원본이다 (값은 styles.css 토큰과 같게 유지).
export const COLORS = {
  brokenTint: 0xff5050,
  clear: 0xffffff,
  accent: 0x1e3a8a,
  badge: { running: 0x0f766e, stopped: 0x64748b, broken: 0xb91c1c },
};

// 캔버스 안 바닥·선택 색은 여기 한 곳에만 둔다. 구역 바닥 톤은 layout.json(zones[].tone)에서 온다.
export const CANVAS_FLOOR = 0x262f3d;
export const CANVAS_ZONE_EDGE = 0x1b2230; // 구역 경계 1px
export const CANVAS_SELECT = { inner: 0xf1f5f9, outer: 0x1e3a8a }; // 안 2px 실선 + 바깥 1px

const BADGE_R = 6; // 12px 원
const BADGE_INSET = 10;
const DASH = 6;
const DASH_GAP = 4;

// 시트의 칸 번호(행×열수+열)를 시트 픽셀 좌표로.
const cellOrigin = (sheet, n) => ({ x: (n % sheet.cols) * sheet.tile, y: Math.floor(n / sheet.cols) * sheet.tile });

export const machineFrame = (kind, n) => `m:${kind}:${n}`;
export const itemFrame = (n) => `i:${n}`;

// 32px 칸보다 큰 기계·작은 아이템은 칸 번호 + crop 으로 이름 붙인 프레임을 만든다. 칸 번호가 곧 시트 위치다.
export function registerFrames(scene) {
  const tex = scene.textures.get('tiles');
  const { sheet, machines, items } = scene.sp;
  Object.entries(machines).forEach(([kind, d]) => {
    const { dx, dy, w, h } = d.crop;
    [d.off, ...d.on, ...d.working].forEach((n) => {
      const o = cellOrigin(sheet, n);
      if (!tex.has(machineFrame(kind, n))) tex.add(machineFrame(kind, n), 0, o.x + dx, o.y + dy, w, h);
    });
  });
  items.frames.forEach((n) => {
    const o = cellOrigin(sheet, n);
    if (!tex.has(itemFrame(n))) tex.add(itemFrame(n), 0, o.x, o.y, items.crop, items.crop);
  });
}

// 구역마다 바닥 톤을 한 단계씩 다르게 깔고 경계를 1px 로 긋는다.
export function drawFloor(scene, f, add) {
  const c = scene.cell;
  const g = add(scene.add.graphics().setDepth(0));
  g.fillStyle(CANVAS_FLOOR, 1).fillRect(0, 0, f.grid.w * c, f.grid.h * c);
  f.zones.forEach((z) => {
    g.fillStyle(Phaser.Display.Color.HexStringToColor(z.tone).color, 1).fillRect(z.x * c, z.y * c, z.w * c, z.h * c);
    g.lineStyle(1, CANVAS_ZONE_EDGE, 1).strokeRect(z.x * c + 0.5, z.y * c + 0.5, z.w * c - 1, z.h * c - 1);
  });
}

const machineDef = (scene, kind) => scene.sp.machines[kind] || Object.values(scene.sp.machines)[0];

// 기계는 벨트 한 칸 위에 올라앉는다. (m.x, m.y) 가 그 칸이고, 그림 아래변이 칸 아래변에 닿는다.
// 선택·고장·배지용 사각형은 그림 crop(w×h) 그대로라서 그림이 바뀌어도 어긋나지 않는다.
export function machineRect(scene, m) {
  const c = scene.cell;
  const { w: cw, h: ch } = machineDef(scene, m.kind).crop;
  const w = cw * scene.zoom;
  const h = ch * scene.zoom;
  return { x: m.x * c + (c - w) / 2, y: (m.y + 1) * c - h, w, h };
}

export function drawMachine(scene, m, add) {
  const def = machineDef(scene, m.kind);
  const r = machineRect(scene, m);
  const cx = r.x + r.w / 2;
  const spr = add(scene.add.image(cx, r.y + r.h, 'tiles', machineFrame(m.kind, def.off)).setOrigin(0.5, 1).setScale(scene.zoom).setDepth(10));
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
  return { id: m.id, spr, badge, dash, rect: r, cx, def, kind: m.kind, state: null, t: 0, frame: '', rampUntil: 0, fxBusy: false, fx: {} };
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
