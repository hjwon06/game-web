// 씬이 쓰는 그리기 도구. 상태는 갖지 않고, 만든 오브젝트를 돌려준다.
// Phaser 는 숫자 색을 쓴다. 이 COLORS 가 캔버스 안 색의 유일한 원본이다 (값은 styles.css 토큰과 같게 유지).
export const COLORS = {
  brokenTint: 0xffffff, // 고장은 깜빡이지 않는다(대비 100% 고정). scene_factory 의 깜빡임 호출이 흰색 = 변화 없음이 되게 둔다
  accent: 0x1b3a5c,
  band: 0xdcd7ce, // 구역 띠 (바닥은 CSS 가 깐다)
  bandLine: 0xcec9bf, // 띠 안쪽 32px 격자
};

// 상태별 기계 모습(S8). sat 1 = 원본 채도, 0 = 회색. 고장은 원본 그대로 + 불투명 100%.
const LOOK = {
  running: { alpha: 0.9, sat: 0.7 }, // 전부 흐리면 고장 강조가 죽는다(T2: .55 → .7)
  stopped: { alpha: 0.55, sat: 0 },
  broken: { alpha: 1, sat: 1 },
};
const SELECT_PAD = 4;

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
  [...items.frames, ...(scene.sp.props?.frames || [])].forEach((n) => {
    const o = cellOrigin(sheet, n);
    if (!tex.has(itemFrame(n))) tex.add(itemFrame(n), 0, o.x, o.y, items.crop, items.crop);
  });
}

// 소품: { f: 시트 칸 번호(16px 그림, 2배로 한 칸 크기) } 또는 { mark: 시트 칸 번호(32px 바닥 표시) } + 칸 좌표 x, y.
// 채도·불투명도를 낮추고 벨트·기계보다 아래(depth 1~2)에 둔다. 칸 크기에서 나오므로 배율이 바뀌어도 따라온다.
export function drawProps(scene, props, add) {
  const sp = scene.sp.props;
  if (!sp) return;
  const c = scene.cell;
  props.forEach((p) => {
    const x = p.x * c + c / 2;
    const y = p.y * c + c / 2;
    if (p.mark !== undefined) {
      add(scene.add.image(x, y, 'tiles', p.mark).setScale(scene.zoom).setAlpha(sp.markAlpha).setDepth(1));
      return;
    }
    const spr = add(scene.add.image(x, y, 'tiles', itemFrame(p.f)).setScale(sp.scale * scene.zoom).setAlpha(sp.alpha).setDepth(2));
    const fx = spr.preFX ? spr.preFX.addColorMatrix() : null;
    if (fx) (fx.colorMatrix || fx).saturate(sp.sat - 1);
  });
}

// 바닥은 CSS(#game)가 깔고, 여기서는 구역 띠만 그린다: 띠 색 + 32px 격자(칸 하나 = 시트 한 칸 × 배율).
// 띠 색·격자색은 styles.css 의 --band / --band-line 과 같아야 한다(캔버스 밖 여백이 같은 띠로 이어진다).
export function drawFloor(scene, f, add) {
  const c = scene.cell;
  const g = add(scene.add.graphics().setDepth(0));
  f.zones.forEach((z) => {
    g.fillStyle(COLORS.band, 1).fillRect(z.x * c, z.y * c, z.w * c, z.h * c);
    g.lineStyle(1, COLORS.bandLine, 1);
    for (let i = 0; i <= z.w; i++) g.lineBetween((z.x + i) * c + 0.5, z.y * c, (z.x + i) * c + 0.5, (z.y + z.h) * c);
    for (let j = 0; j <= z.h; j++) g.lineBetween(z.x * c, (z.y + j) * c + 0.5, (z.x + z.w) * c, (z.y + j) * c + 0.5);
  });
}

const machineDef = (scene, kind) => scene.sp.machines[kind] || Object.values(scene.sp.machines)[0];

// 기계는 벨트 한 칸 위에 올라앉는다. (m.x, m.y) 가 그 칸이고, 그림 아래변이 칸 아래변에 닿는다.
// 선택 테두리·말풍선·명판 기준 사각형은 그림 crop(w×h) 그대로라서 그림이 바뀌어도 어긋나지 않는다.
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
  // 채도는 색 행렬로 바꾼다(WebGL). 캔버스 렌더러에서는 preFX 가 없어 불투명도만 적용된다.
  const fx = spr.preFX ? spr.preFX.addColorMatrix() : null;
  // dash: scene_factory 가 고장 외곽선 토글로 부르는 자리. 외곽선은 없앴으므로 아무것도 하지 않는다.
  const dash = { setVisible() {} };
  return { id: m.id, spr, cm: fx && (fx.colorMatrix || fx), dash, rect: r, cx, def, kind: m.kind, state: null, t: 0, frame: '', rampUntil: 0, fxBusy: false, fx: {} };
}

// 상태 표시(S8). scene_factory 가 응답마다 부르는 자리라 이름은 그대로 두고 기계 모습을 상태에 맞춘다.
// 빨간 점은 명판(DOM, hud.js)이 맡는다.
export function drawBadge(v, state) {
  const look = LOOK[state] ?? LOOK.stopped;
  v.spr.setAlpha(look.alpha);
  if (!v.cm) return;
  v.cm.reset();
  if (look.sat < 1) v.cm.saturate(look.sat - 1);
}

export function makeOutline(scene) {
  return scene.add.graphics().setDepth(30).setVisible(false);
}

// 선택 테두리: 기계 그림 크기에서 4px 바깥, 2px 실선 한 겹
export function placeOutline(outline, v) {
  outline.clear();
  if (!v) return outline.setVisible(false);
  const { x, y, w, h } = v.rect;
  outline.lineStyle(2, COLORS.accent, 1).strokeRect(x - SELECT_PAD, y - SELECT_PAD, w + SELECT_PAD * 2, h + SELECT_PAD * 2);
  return outline.setVisible(true);
}
