// 상태·입력·애니메이션을 맡는다. 그리기 도구는 scene_draw.js.
// 상태의 원본은 data/factory.json 이고 여기서는 읽기만 한다. 타일 번호·배율은 data/sprites.json 에서만 온다.
import { COLORS, addBox, buildBelt, drawBadge, drawFloor, drawMachine, makeOutline, placeBox, placeOutline } from './scene_draw.js';

const BELT_SPEED = 1.2; // 칸/초
const BOX_GAP = 1.5; // 상자 사이 간격(칸)
const BELT_FRAME_MS = 200;
const BLINK_MS = 500;
const STOPPED_ALPHA = 0.6;

export class FactoryScene extends Phaser.Scene {
  constructor({ sprites, onSelect }) {
    super('factory');
    this.sp = sprites;
    this.zoom = sprites.scale; // this.scale 은 Phaser ScaleManager 라서 이름을 피한다
    this.cell = sprites.sheet.tile * this.zoom;
    this.onSelect = onSelect || (() => {});
    this.grid = { w: 0, h: 0 };
    this.pending = null;
    this.built = false;
    this.signature = '';
    this.objs = [];
    this.machines = new Map();
    this.belts = [];
    this.selectedId = null;
    this.blinkOn = false;
    this.track = (obj) => {
      this.objs.push(obj);
      return obj;
    };
  }

  preload() {
    const tile = this.sp.sheet.tile;
    this.load.spritesheet('tiles', this.sp.sheet.file, { frameWidth: tile, frameHeight: tile });
  }

  create() {
    this.outline = makeOutline(this);
    // 빈 곳을 누르면 선택 해제. 캔버스에서 일어난 선택이므로 onSelect 로 알린다.
    this.input.on('pointerdown', (_p, over) => {
      if (over.length === 0 && this.selectedId) this.pick(null);
    });
    this.time.addEvent({ delay: BLINK_MS, loop: true, callback: () => this.blink() });
    this.built = true;
    if (this.pending) this.applyState(this.pending);
  }

  px(x, y) {
    const c = this.cell;
    return { x: x * c + c / 2, y: y * c + c / 2 };
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

  rebuild(f) {
    this.objs.forEach((o) => {
      this.tweens.killTweensOf(o);
      o.destroy();
    });
    this.objs = [];
    this.machines.clear();
    this.belts = [];
    this.grid = f.grid;
    this.scale.setGameSize(f.grid.w * this.cell, f.grid.h * this.cell);

    drawFloor(this, f.grid, this.track);
    f.conveyors.forEach((c) => this.addBelt(c, f));
    f.machines.forEach((m) => {
      const v = drawMachine(this, m, this.track);
      v.spr.on('pointerdown', () => this.pick(m.id));
      this.machines.set(m.id, v);
    });
    f.workers.forEach((w) => {
      const p = this.px(w.x, w.y);
      const spr = this.track(this.add.image(p.x, p.y, 'tiles', this.sp.tiles.worker).setScale(this.zoom).setDepth(20));
      this.tweens.add({ targets: spr, y: p.y - this.zoom * 2, duration: 450, yoyo: true, repeat: -1, ease: 'Sine.easeInOut' });
    });
    if (this.selectedId && !this.machines.has(this.selectedId)) this.selectedId = null;
    placeOutline(this.outline, this.machines.get(this.selectedId));
  }

  addBelt(c, f) {
    const b = buildBelt(this, c, f, this.track);
    // 멈춘 벨트에서도 기계 앞 상자가 보이도록 미리 채워 둔다.
    let s = b.total - this.cell * 0.5;
    while (s >= 0) {
      addBox(this, b, s, this.track);
      s -= BOX_GAP * this.cell;
    }
    b.sinceSpawn = (s + BOX_GAP * this.cell) / this.cell;
    this.belts.push(b);
  }

  applyMachineStates(f) {
    f.machines.forEach((m) => {
      const v = this.machines.get(m.id);
      if (!v) return;
      v.state = m.state;
      v.spr.setAlpha(m.state === 'stopped' ? STOPPED_ALPHA : 1);
      v.tape.forEach((t) => t.setVisible(m.state === 'defect'));
      this.paintTint(v);
      drawBadge(v, m.state);
    });
    this.belts.forEach((b) => {
      b.running = this.machines.get(b.to)?.state === 'running';
    });
  }

  paintTint(v) {
    if (v.state === 'defect' && this.blinkOn) v.spr.setTint(COLORS.defectTint);
    else v.spr.clearTint();
  }

  blink() {
    this.blinkOn = !this.blinkOn;
    this.machines.forEach((v) => this.paintTint(v));
  }

  // 캔버스를 눌러서 고른 경우: 안쪽 선택을 바꾸고 바깥(패널)에 알린다.
  pick(id) {
    this.select(id);
    this.onSelect(id);
  }

  // 바깥(목록)이 고른 경우: 표시만 바꾼다. onSelect 를 부르지 않는다.
  select(id) {
    this.selectedId = id;
    if (this.outline) placeOutline(this.outline, this.machines.get(id));
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
        addBox(this, b, 0, this.track);
      }
      b.boxes = b.boxes.filter((box) => {
        box.s += BELT_SPEED * this.cell * dt;
        if (box.s >= b.total) {
          box.spr.destroy();
          this.objs = this.objs.filter((o) => o !== box.spr);
          return false;
        }
        placeBox(b, box);
        return true;
      });
    });
  }
}
