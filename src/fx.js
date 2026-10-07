// 상태 전이 연출 뼈대. 이전 응답과 비교해 바뀐 기계에만 1회씩 틀고, 같은 응답이면 아무것도 하지 않는다.
// 연출은 눈에 보이는 것만 바꾼다(원본 상태는 건드리지 않는다). 상시 효과 없음: 모두 끝나면 원래 모습으로 돌아온다.
import { itemFrame } from './scene_draw.js';
import { expandRoute } from './scene_belt.js';

const DIR_VEC = { right: [1, 0], left: [-1, 0], down: [0, 1], up: [0, -1] };

const STOP_MS = 250; // 정지: 어두워졌다 돌아옴
const SHAKE_MS = 150; // 고장: 가로 흔들림
const SHAKE_AMP = 2; // px
const REPAIR_MS = 300; // 수리: 밝아지는 펄스
const START_MS = 150; // 정지 → 가동: 짧게 밝아짐(정지의 어두워짐과 짝)
const START_PEAK = 0.5;
const REPAIR_PEAK = 0.7;
const FLOAT_MS = 400; // 생산: 아이템이 다음 구역 쪽으로 떠오름
const STAGGER_MAX = 300; // 기계별 시차 상한(ms)
const MAX_PARTICLES = 8; // 전이 1회당 파티클 상한
const DIM_TINT = 0x4b5563;
const SPARK = { broken: 0xff5050, repair: 0xfff2b0 };

// 기계 코드로 정하는 시차(0~300ms). 같은 코드는 언제나 같은 값이다.
export function staggerOf(id) {
  let h = 0;
  for (const ch of String(id)) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return h % (STAGGER_MAX + 1);
}

const mixTint = (a, b, t) => {
  const ch = (s) => Math.round(((a >> s) & 255) + (((b >> s) & 255) - ((a >> s) & 255)) * t);
  return (ch(16) << 16) | (ch(8) << 8) | ch(0);
};

export class Fx {
  constructor(scene) {
    this.scene = scene;
    this.prev = null; // id -> { state, made }
    this.away = false; // 탭이 숨겨졌다가 돌아온 직후 첫 응답은 연출 없이 반영
    this.onVisibility = () => { if (document.visibilityState === 'hidden') this.away = true; };
    document.addEventListener('visibilitychange', this.onVisibility);
    scene.events.once('shutdown', () => document.removeEventListener('visibilitychange', this.onVisibility));
  }

  // 새 응답을 알린다. 상태는 이미 씬에 반영돼 있고, 여기서는 연출만 건다.
  observe(f) {
    const hidden = document.visibilityState === 'hidden';
    const skip = !this.prev || this.away || hidden;
    this.away = hidden;
    const events = [];
    f.machines.forEach((m) => {
      const p = this.prev?.get(m.id);
      if (!p || skip) return;
      if (m.state !== p.state) {
        const kind = m.state === 'broken' ? 'broken' : p.state === 'broken' ? 'repair' : m.state === 'stopped' ? 'stop' : m.state === 'running' ? 'start' : null;
        if (kind) events.push({ id: m.id, kind });
      }
      if (m.processed > p.made) events.push({ id: m.id, kind: 'produce' });
    });
    this.prev = new Map(f.machines.map((m) => [m.id, { state: m.state, made: m.processed }]));
    if (events.length) this.play(events, f);
  }

  play(events, f) {
    const view = (id) => this.scene.machines.get(id);
    // 같은 응답의 고장은 몇 대든 흔들림 1회로 합친다.
    const broken = events.filter((e) => e.kind === 'broken').map((e) => view(e.id)).filter(Boolean);
    if (broken.length) this.shake(broken);
    events.forEach((e) => {
      const v = view(e.id);
      if (!v) return;
      const delay = staggerOf(e.id);
      if (e.kind === 'stop') this.dim(v, delay);
      else if (e.kind === 'repair') this.pulse(v, delay, REPAIR_MS, REPAIR_PEAK, true);
      else if (e.kind === 'start') this.pulse(v, delay, START_MS, START_PEAK, false);
      else if (e.kind === 'produce') this.float(v, f, delay);
    });
  }

  // 같은 기계에 같은 종류 연출이 겹치면 앞의 것을 끊고 원래 모습으로 되돌린 뒤 새로 건다.
  hold(v, key, tween, cleanup) {
    this.release(v, key);
    v.fx[key] = { tween, cleanup };
  }

  release(v, key) {
    const h = v.fx[key];
    if (!h) return;
    delete v.fx[key];
    h.tween.stop();
    h.cleanup();
  }

  dim(v, delay) {
    const k = { t: 0 };
    const done = () => {
      delete v.fx.tint;
      v.fxBusy = false;
      this.scene.paintTint(v);
    };
    this.release(v, 'tint');
    v.fxBusy = true;
    const tween = this.scene.tweens.add({
      targets: k, t: 1, delay, duration: STOP_MS / 2, yoyo: true,
      onUpdate: () => v.spr.active && v.spr.setTint(mixTint(0xffffff, DIM_TINT, k.t)),
      onComplete: done,
    });
    this.hold(v, 'tint', tween, () => { v.fxBusy = false; this.scene.paintTint(v); });
  }

  // 트윈 1개가 목록 전체를 흔든다. 겹쳐서 다시 걸린 기계는 목록에서 빠지고 제자리로 돌아간다.
  shake(list) {
    const k = { t: 0 };
    const group = [...list];
    const reset = (v) => { if (v.spr.active) v.spr.x = v.cx; };
    list.forEach((v) => this.release(v, 'shake'));
    this.scene.tweens.add({
      targets: k, t: 1, duration: SHAKE_MS,
      onUpdate: () => group.forEach((v) => v.spr.active && (v.spr.x = v.cx + Math.sin(k.t * Math.PI * 4) * SHAKE_AMP)),
      onComplete: () => group.forEach((v) => { reset(v); delete v.fx.shake; }),
    });
    list.forEach((v) => {
      this.hold(v, 'shake', { stop() {} }, () => { group.splice(group.indexOf(v), 1); reset(v); });
      this.burst(v.cx, v.rect.y + v.rect.h / 2, 4, SPARK.broken, 0);
    });
  }

  // 밝아지는 펄스: 기계 모양 그대로의 흰 그림자를 겹쳐 알파만 올렸다 내린다.
  pulse(v, delay, ms, peak, sparks) {
    const { spr } = v;
    const ghost = this.scene.track(this.scene.add.image(spr.x, spr.y, spr.texture.key, spr.frame.name)
      .setOrigin(0.5, 1).setScale(spr.scaleX).setTintFill(0xffffff).setAlpha(0).setDepth(11));
    const cleanup = () => ghost.destroy();
    this.release(v, 'pulse');
    v.rampUntil = this.scene.now + delay + ms; // 이 동안은 켜짐(on) 프레임을 보여 준다
    const tween = this.scene.tweens.add({
      targets: ghost, alpha: peak, delay, duration: ms / 2, yoyo: true,
      onComplete: () => { delete v.fx.pulse; cleanup(); },
    });
    this.hold(v, 'pulse', tween, cleanup);
    if (sparks) this.burst(v.cx, v.rect.y + v.rect.h / 2, 6, SPARK.repair, delay);
  }

  // 생산 1건: 아이템이 기계 위에서 떠올라 다음 기계(=다음 구역) 방향으로 흘러간다.
  float(v, f, delay) {
    const sc = this.scene;
    const i = f.machines.findIndex((m) => m.id === v.id);
    const me = f.machines[i];
    const next = f.machines[i + 1];
    // 다음 기계가 없으면(마지막 기계) 그 기계가 놓인 벨트 칸의 진행 방향을 쓴다.
    const cell = expandRoute(f.belt.route).find((c) => c.x === me.x && c.y === me.y);
    let [dx, dy] = DIR_VEC[cell?.dir] ?? DIR_VEC.right;
    if (next) {
      const len = Math.hypot(next.x - me.x, next.y - me.y) || 1;
      dx = (next.x - me.x) / len;
      dy = (next.y - me.y) / len;
    }
    const item = f.zones.find((z) => z.id === me.zone)?.item ?? 0;
    const spr = sc.track(sc.add.image(v.cx, v.rect.y + sc.cell * 0.3, 'tiles', itemFrame(sc.sp.items.frames[item])).setScale(sc.zoom).setDepth(22).setVisible(false));
    sc.tweens.add({
      targets: spr, delay, duration: FLOAT_MS, ease: 'Sine.easeOut',
      x: spr.x + dx * sc.cell, y: spr.y + dy * sc.cell - sc.cell * 0.4, alpha: 0,
      onStart: () => spr.setVisible(true),
      onComplete: () => spr.destroy(),
    });
  }

  // 작은 네모 n 개(상한 8)가 퍼지며 사라진다.
  burst(x, y, n, color, delay) {
    const sc = this.scene;
    const count = Math.min(n, MAX_PARTICLES);
    for (let i = 0; i < count; i++) {
      const a = (i / count) * Math.PI * 2;
      const p = sc.track(sc.add.rectangle(x, y, 4, 4, color).setDepth(25).setVisible(false));
      sc.tweens.add({
        targets: p, delay, duration: 300, x: x + Math.cos(a) * 24, y: y + Math.sin(a) * 24, alpha: 0,
        onStart: () => p.setVisible(true),
        onComplete: () => p.destroy(),
      });
    }
  }
}

// ?stress=1 시험 모드용: 지금 상태를 바탕으로 12대를 무작위로 바꾸고 가동 중인 기계의 생산 수를 올린 새 상태를 만든다.
// 화면 코드 안에서만 쓰고 API 는 부르지 않는다. 연출 겹침을 눈으로 보는 용도다.
export function stressNext(s) {
  const pick = () => {
    const r = Math.random();
    return r < 0.5 ? 'running' : r < 0.75 ? 'stopped' : 'broken';
  };
  const machines = s.machines.map((m) => {
    const state = pick();
    const gain = state === 'running' ? 1 + Math.floor(Math.random() * 3) : 0;
    const wo = m.work_order ? { ...m.work_order, produced_qty: m.work_order.produced_qty + gain } : null;
    return { ...m, state, processed: m.processed + gain, work_order: wo };
  });
  return { ...s, updated_at: new Date().toISOString(), machines };
}
