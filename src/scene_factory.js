// 상태·입력·애니메이션을 맡는다. 그리기 도구는 scene_draw.js, 벨트는 scene_belt.js, 전이 연출은 fx.js.
// 상태의 원본은 서버(state.js 가 배치와 합쳐 준다)이고 여기서는 읽기만 한다. 칸 번호·배율은 data/sprites.json 에서만 온다.
import { COLORS, drawBadge, drawFloor, drawMachine, machineFrame, makeOutline, placeOutline, registerFrames } from './scene_draw.js';
import { buildBelt, destroyBelt, setBeltRunning, updateBelt } from './scene_belt.js';
import { Fx, staggerOf } from './fx.js';

const BLINK_MS = 500;
const HIT_MIN_PX = 44; // 히트박스 최소 크기(화면 픽셀)
const PLATE_H = 5; // 기계 그림 아래 명판 높이(월드 px = 이 값 × 배율). 히트박스에 포함한다

export class FactoryScene extends Phaser.Scene {
  constructor({ sprites, onSelect }) {
    super('factory');
    this.sp = sprites;
    this.zoom = sprites.scale; // this.scale 은 Phaser ScaleManager 라서 이름을 피한다
    this.cell = sprites.sheet.tile * this.zoom;
    this.onSelect = onSelect || (() => {});
    this.pending = null;
    this.built = false;
    this.signature = '';
    this.objs = new Set(); // 다시 그릴 때 지울 오브젝트. 연출용 일회성 스프라이트도 여기 넣고, 스스로 사라지면 빠진다
    this.machines = new Map();
    this.belt = null;
    this.selectedId = null;
    this.blinkOn = false;
    this.hitK = 0; // 마지막으로 히트박스를 맞출 때의 화면 배율(월드 px / 화면 px)
    this.now = 0; // 씬 시계(ms). fx.js 가 켜짐 프레임 구간을 잡을 때 읽는다
    this.track = (obj) => {
      this.objs.add(obj);
      obj.once('destroy', () => this.objs.delete(obj));
      return obj;
    };
  }

  preload() {
    const tile = this.sp.sheet.tile;
    this.load.spritesheet('tiles', this.sp.sheet.file, { frameWidth: tile, frameHeight: tile });
  }

  create() {
    registerFrames(this);
    this.fx = new Fx(this);
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
    this.fx.observe(factory);
  }

  structureOf(f) {
    return JSON.stringify([f.grid, f.zones, f.belt, f.machines.map((m) => [m.id, m.x, m.y, m.kind, m.zone])]);
  }

  rebuild(f) {
    [...this.objs].forEach((o) => {
      this.tweens.killTweensOf(o);
      o.destroy();
    });
    destroyBelt(this.belt);
    this.objs.clear();
    this.machines.clear();
    this.scale.setGameSize(f.grid.w * this.cell, f.grid.h * this.cell);

    drawFloor(this, f, this.track);
    this.belt = buildBelt(this, f, this.track);
    f.machines.forEach((m) => {
      const v = drawMachine(this, m, this.track);
      v.t = staggerOf(m.id) * 3; // 기계마다 그림 박자가 어긋나게
      v.spr.disableInteractive(); // 클릭은 히트박스만 받는다. 그림이 작아도 44px 보장이 깨지지 않게
      v.hit = this.track(this.add.zone(0, 0, 1, 1).setInteractive({ useHandCursor: true }).setDepth(20));
      v.hit.on('pointerdown', () => this.pick(m.id));
      this.machines.set(m.id, v);
    });
    this.fitHits(true);
    if (this.selectedId && !this.machines.has(this.selectedId)) this.selectedId = null;
    placeOutline(this.outline, this.machines.get(this.selectedId));
  }

  // running = 일하는 그림(애니는 update), stopped·broken = 꺼진 그림. 고장은 거기에 빨간 깜빡임이 더해진다.
  applyMachineStates(f) {
    f.machines.forEach((m) => {
      const v = this.machines.get(m.id);
      if (!v) return;
      v.state = m.state;
      if (m.state !== 'running') this.setFrame(v, v.def.off);
      v.dash.setVisible(m.state === 'broken');
      this.paintTint(v);
      drawBadge(v, m.state);
    });
    setBeltRunning(this.belt, this.machines);
  }

  setFrame(v, n) {
    const key = machineFrame(v.kind, n);
    if (v.frame === key) return;
    v.frame = key;
    v.spr.setFrame(key);
  }

  paintTint(v) {
    if (v.fxBusy) return; // 정지 연출이 색을 잡고 있는 동안은 건드리지 않는다
    if (v.state === 'broken' && this.blinkOn) v.spr.setTint(COLORS.brokenTint);
    else v.spr.clearTint();
  }

  blink() {
    this.blinkOn = !this.blinkOn;
    this.machines.forEach((v) => this.paintTint(v));
  }

  // 히트박스 = 그림 + 명판, 단 화면에서 44×44px 아래로는 줄지 않는다. 선택 테두리는 v.rect(그림 크기)라서 영향 없다.
  // 캔버스 표시 배율이 바뀌면(리사이즈) 월드 크기를 다시 잡는다. 배율이 그대로면 아무것도 하지 않는다.
  fitHits(force) {
    const k = this.scale.displayScale.x || 1;
    if (!force && k === this.hitK) return;
    this.hitK = k;
    const min = HIT_MIN_PX * k;
    this.machines.forEach((v) => {
      const r = v.rect;
      const bottom = r.y + r.h + PLATE_H * this.zoom;
      const w = Math.max(r.w, min);
      const h = Math.max(bottom - r.y, min);
      v.hit.setPosition(r.x + r.w / 2, bottom - h / 2).setSize(w, h);
    });
  }

  // 캔버스가 눌렸을 때: 안쪽 선택을 바꾸고 콜백 하나(onSelect)로 바깥에 알린다.
  pick(id) {
    this.select(id);
    this.onSelect(id);
  }

  // 바깥(고장 칩 등)이 고른 경우: 표시만 바꾼다. onSelect 를 부르지 않는다.
  select(id) {
    this.selectedId = id;
    if (this.outline) placeOutline(this.outline, this.machines.get(id));
  }

  update(time, delta) {
    this.now = time;
    this.fitHits(false);
    this.machines.forEach((v) => {
      if (v.state !== 'running') return;
      v.t += delta;
      const list = time < v.rampUntil ? v.def.on : v.def.working;
      this.setFrame(v, list[Math.floor(v.t / v.def.ms) % list.length]);
    });
    if (this.belt) updateBelt(this.belt, delta / 1000, this.sp.belt.ms);
  }
}
