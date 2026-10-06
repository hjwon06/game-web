// 그리기와 입력만 한다. 상태의 원본은 data/factory.json 이고 여기서는 읽기만 한다.
// 타일 번호는 data/sprites.json 에서만 온다 (sheet / floor / belt / box / machine / worker).
const TILE = 16;
const SCALE = 3;
const CELL = TILE * SCALE;
const BOX_SCALE = 2;
const BELT_SPEED = 1.2; // 칸/초
const BOX_GAP = 1.5; // 상자 사이 간격(칸)
const BELT_FRAME_MS = 200;
const BLINK_MS = 500;
const DEFECT_TINT = 0xff5050;

export class FactoryScene extends Phaser.Scene {
  constructor({ sprites, onSelect }) {
    super('factory');
    this.sp = sprites;
    this.onSelect = onSelect || (() => {});
    this.pending = null;
    this.built = false;
    this.signature = '';
    this.objs = [];
    this.machines = new Map();
    this.belts = [];
    this.selectedId = null;
    this.blinkOn = false;
  }

  preload() {
    const { path, tile } = this.sp.sheet;
    this.load.spritesheet('tiles', path, { frameWidth: tile || TILE, frameHeight: tile || TILE });
  }

  create() {
    this.cameras.main.setBackgroundColor('#F2F3F5');
    this.marker = this.add.rectangle(0, 0, CELL, CELL).setStrokeStyle(3, 0x1a1a2e).setFillStyle().setDepth(30).setVisible(false);
    this.input.on('pointerdown', (_p, over) => {
      if (over.length === 0) this.select(null);
    });
    this.time.addEvent({ delay: BLINK_MS, loop: true, callback: () => this.blink() });
    this.built = true;
    if (this.pending) this.applyState(this.pending);
  }

  // 외부(main.js)가 새 상태를 알릴 때 부른다. 읽기 전용으로 받아 그린다.
  applyState(factory) {
    this.pending = factory;
    if (!this.built || !factory) return;
    const sig = this.structureOf(factory);
    if (sig !== this.signature) {
      this.signature = sig;
      this.rebuild(factory);
    }
    this.applyMachineStates(factory);
  }

  structureOf(f) {
    return JSON.stringify([
      f.grid,
      f.machines.map((m) => [m.id, m.x, m.y, m.color]),
      f.conveyors.map((c) => [c.id, c.path, c.to]),
      f.workers.map((w) => [w.id, w.x, w.y]),
    ]);
  }

  px(x, y) {
    return { x: x * CELL + CELL / 2, y: y * CELL + CELL / 2 };
  }

  track(obj) {
    this.objs.push(obj);
    return obj;
  }

  rebuild(f) {
    this.objs.forEach((o) => {
      this.tweens.killTweensOf(o);
      o.destroy();
    });
    this.objs = [];
    this.machines.clear();
    this.belts = [];
    this.scale.setGameSize(f.grid.w * CELL, f.grid.h * CELL);

    const { floor, belt, box, machine, worker } = this.sp;
    for (let y = 0; y < f.grid.h; y++) {
      for (let x = 0; x < f.grid.w; x++) {
        const p = this.px(x, y);
        this.track(this.add.image(p.x, p.y, 'tiles', floor[(x + y) % floor.length]).setScale(SCALE).setDepth(0));
      }
    }
    f.conveyors.forEach((c) => this.buildBelt(c, f, belt, box));
    f.machines.forEach((m) => {
      const p = this.px(m.x, m.y);
      const spr = this.track(this.add.image(p.x, p.y, 'tiles', machine[m.color]).setScale(SCALE).setDepth(10));
      spr.setInteractive({ useHandCursor: true });
      spr.on('pointerdown', () => this.select(m.id));
      this.machines.set(m.id, { spr, x: p.x, y: p.y, state: null });
    });
    f.workers.forEach((w) => {
      const p = this.px(w.x, w.y);
      const spr = this.track(this.add.image(p.x, p.y, 'tiles', worker).setScale(SCALE).setDepth(20));
      this.tweens.add({ targets: spr, y: p.y - SCALE * 2, duration: 450, yoyo: true, repeat: -1, ease: 'Sine.easeInOut' });
    });
    if (this.selectedId && !this.machines.has(this.selectedId)) this.select(null);
    else this.placeMarker();
  }

  buildBelt(c, f, beltSp, boxFrame) {
    const target = f.machines.find((m) => m.id === c.to);
    const pts = c.path.map(([x, y]) => this.px(x, y));
    if (target) pts.push(this.px(target.x, target.y));
    const cells = c.path.map(([x, y], i) => {
      const next = pts[i + 1];
      const cur = pts[i];
      const key = c.path.length === 1 ? 'mid' : i === 0 ? 'start' : i === c.path.length - 1 ? 'end' : 'mid';
      const spr = this.track(this.add.image(cur.x, cur.y, 'tiles', beltSp[key][0]).setScale(SCALE).setDepth(1));
      if (next) spr.setAngle(next.x < cur.x ? 180 : next.y > cur.y ? 90 : next.y < cur.y ? -90 : 0);
      return { spr, frames: beltSp[key] };
    });
    const cum = [0];
    for (let i = 1; i < pts.length; i++) cum.push(cum[i - 1] + Math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y));
    const b = { id: c.id, to: c.to, pts, cum, total: cum[cum.length - 1], cells, boxes: [], running: false, phase: 0, sinceSpawn: 0, boxFrame };
    // 멈춘 벨트에서도 기계 앞 상자가 보이도록 미리 채워 둔다.
    let s = b.total - CELL * 0.9;
    while (s >= 0) {
      this.addBox(b, s);
      s -= BOX_GAP * CELL;
    }
    b.sinceSpawn = (s + BOX_GAP * CELL) / CELL;
    this.belts.push(b);
  }

  addBox(b, s) {
    const spr = this.track(this.add.image(0, 0, 'tiles', b.boxFrame).setScale(BOX_SCALE).setDepth(5));
    const box = { s, spr };
    this.placeBox(b, box);
    b.boxes.push(box);
  }

  placeBox(b, box) {
    let i = 1;
    while (i < b.cum.length - 1 && b.cum[i] < box.s) i++;
    const a = b.pts[i - 1];
    const z = b.pts[i];
    const span = b.cum[i] - b.cum[i - 1] || 1;
    const t = Math.min(1, (box.s - b.cum[i - 1]) / span);
    box.spr.setPosition(a.x + (z.x - a.x) * t, a.y + (z.y - a.y) * t);
  }

  applyMachineStates(f) {
    f.machines.forEach((m) => {
      const v = this.machines.get(m.id);
      if (!v) return;
      v.state = m.state;
      v.spr.setAlpha(m.state === 'stopped' ? 0.5 : 1);
      if (m.state !== 'defect') v.spr.clearTint();
      else v.spr.setTint(this.blinkOn ? DEFECT_TINT : 0xffffff);
    });
    this.belts.forEach((b) => {
      b.running = this.machines.get(b.to)?.state === 'running';
    });
  }

  blink() {
    this.blinkOn = !this.blinkOn;
    this.machines.forEach((v) => {
      if (v.state === 'defect') v.spr.setTint(this.blinkOn ? DEFECT_TINT : 0xffffff);
    });
  }

  select(id) {
    this.selectedId = id;
    this.placeMarker();
    this.onSelect(id);
  }

  placeMarker() {
    const v = this.selectedId && this.machines.get(this.selectedId);
    if (!v) return this.marker.setVisible(false);
    this.marker.setPosition(v.x, v.y).setVisible(true);
  }

  update(_time, delta) {
    const dt = delta / 1000;
    this.belts.forEach((b) => {
      if (!b.running) return;
      b.phase += dt;
      const frame = Math.floor((b.phase * 1000) / BELT_FRAME_MS) % 2;
      b.cells.forEach((c) => c.spr.setFrame(c.frames[frame]));
      b.sinceSpawn += BELT_SPEED * dt;
      if (b.sinceSpawn >= BOX_GAP) {
        b.sinceSpawn -= BOX_GAP;
        this.addBox(b, 0);
      }
      b.boxes = b.boxes.filter((box) => {
        box.s += BELT_SPEED * CELL * dt;
        if (box.s >= b.total) {
          box.spr.destroy();
          this.objs = this.objs.filter((o) => o !== box.spr);
          return false;
        }
        this.placeBox(b, box);
        return true;
      });
    });
  }
}
