// 3D-⑥ 조작: 건물 비행(키 0~7) · 클릭 선택 · 추적 · 이름표(CSS2D) · 녹화 투어.
// 선택의 통로는 window 'c3d:select' {type: site|truck|forklift|machine|bin, code} 하나다: 클릭·키·검색·탭 행이 모두 이 이벤트를 쏘고, 여기서 한 곳에서 받는다.
// 카메라 움직임은 전부 main.js 의 시계(now, capture 의 step 포함)의 함수다: 비행은 (now - 시작)/0.9초, 추적은 대상의 위치 변화량만큼 평행이동 → 프레임 수와 무관.
import * as THREE from 'three';
import { CSS2DRenderer, CSS2DObject } from 'three/addons/renderers/CSS2DRenderer.js';
import { BUILDINGS, HALL, OPEN_WALL, CENTER } from './layout.js';
import { fitCampus, VIEW } from './scene.js';
import { binSlots, machines } from './campus.js';
import { OPS } from './ui.js';

const FLY_MS = 900, BLUE = 0x2563EB, DRAG_PX = 5;
const KEY_SITE = { 1: 'office', 2: 'mat', 3: 'prod', 4: 'qc', 5: 'ship', 6: 'maint', 7: 'util' };
const TASK_KO = { putaway: '적치', pick: '피킹', feed: '라인 공급', unload: '하차', load: '상차', inspect: '검사', count: '실사' }; // ui.js 의 TASK_KO 와 같은 값
const TRUCK_ST = { enter: '진입 중', leave: '출발 중' };

// 건물 7곳(생산동은 HALL). cx·cz = 바닥 중심, h = 벽 높이
const SITE = {};
BUILDINGS.forEach(b => { SITE[b.id] = { name: b.name, x: b.x, y: b.y, w: b.w, d: b.d, h: b.open ? OPEN_WALL : b.h }; });
SITE.prod = { name: '생산동', x: HALL.x, y: HALL.y, w: HALL.w, d: HALL.d, h: 2.2 };

const ease = u => u < .5 ? 2 * u * u : 1 - Math.pow(-2 * u + 2, 2) / 2;
const clamp01 = v => Math.max(0, Math.min(1, v));
const r2 = v => Math.round(v * 100) / 100;
const vec = v => ({ x: r2(v.x), y: r2(v.y), z: r2(v.z) });
const typing = t => !!t && (/^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName) || t.isContentEditable);

export function createNav({ scene, camera, controls, canvas, haul, now, setTouched }) {
  // ---- 시점: 남쪽에서 방위 15°, 극각 50° (controls 의 극각 한계 35~65° 안) ----
  const az = THREE.MathUtils.degToRad(VIEW.azimuth), po = THREE.MathUtils.degToRad(50);
  const DIR = new THREE.Vector3(Math.sin(po) * Math.sin(az), Math.cos(po), Math.sin(po) * Math.cos(az));

  // ---- 대상 찾기: 지금 장면에서 대상을 다시 찾는 get() 을 가진 객체. 사라지면 get() 이 null ----
  // moving: 따라갈 대상, dist: 카메라 거리, ring: 바깥 반지름, ringY: 링 높이(없으면 바닥)
  function locate(type, code) {
    const { forks, trucks } = haul.list();
    if (type === 'forklift') {
      const f = forks.find(x => x.code === code);
      if (!f) return null;
      const p = new THREE.Vector3();
      return { moving: true, dist: 13, ring: 1.1, label: () => f.obj.userData.label, get: () => f.obj.visible ? p.set(f.obj.position.x, .6, f.obj.position.z) : null };
    }
    if (type === 'truck') {
      const k = trucks.find(x => x.code === code || x.dock === code);
      if (!k) return null;
      const p = new THREE.Vector3();
      return { moving: true, dist: 17, ring: 2.3, label: () => k.obj.userData.label, get: () => trucks.includes(k) ? p.set(k.obj.position.x, 1, k.obj.position.z) : null };
    }
    if (type === 'machine') {
      const m = machines[code];
      if (!m) return null;
      const p = new THREE.Vector3(m.position.x, .8, m.position.z);
      return { moving: false, dist: 11, ring: 1.5, get: () => p };
    }
    if (type === 'bin') {
      const c = binCenter(code);
      if (!c) return null;
      return { moving: false, dist: 9, ring: .9, ringY: binSlots[code][0].y + .03, get: () => c };
    }
    if (type === 'site') {
      const s = SITE[code];
      if (!s) return null;
      const p = new THREE.Vector3(s.x + s.w / 2, Math.min(s.h, 3) / 2, s.y + s.d / 2);
      return { moving: false, dist: THREE.MathUtils.clamp(Math.max(s.w, s.d) * 2.2 + 10, 24, 56), ring: Math.hypot(s.w, s.d) / 2 + .6, label: () => siteLabels[code], get: () => p };
    }
    return null;
  }
  // 단지에 없는 대상은 가까운 도크가 있는 건물로 대신 간다
  function fallbackSite(type, code) {
    if (type === 'truck') { const t = ((OPS.data && OPS.data.trucks) || []).find(x => String(x.no) === code); return t ? (t.type === 'in' ? 'mat' : 'ship') : (/^SO-/i.test(code) ? 'ship' : /^PO-/i.test(code) ? 'mat' : null); }
    if (/^DOCK-OUT/i.test(code)) return 'ship';
    if (/^DOCK/i.test(code) || type === 'forklift') return 'mat';
    return null;
  }

  // ---- 칸 중심 / 점 → 칸·건물 ----
  const centers = {};
  function binCenter(code) {
    const s = binSlots[code];
    if (!s) return null;
    return centers[code] || (centers[code] = s.reduce((a, v) => a.add(v), new THREE.Vector3()).multiplyScalar(1 / s.length).add(new THREE.Vector3(0, .45, 0)));
  }
  function binAt(pt) {
    let best = null, bd = 1.1;
    for (const code in binSlots) { const d = binCenter(code).distanceTo(pt); if (d < bd) { bd = d; best = code; } }
    return best;
  }
  function siteAt(pt) {
    for (const id in SITE) { const s = SITE[id]; if (pt.x >= s.x - .2 && pt.x <= s.x + s.w + .2 && pt.z >= s.y - .2 && pt.z <= s.y + s.d + .2 && pt.y <= s.h + .5) return id; }
    return null;
  }

  // ---- 선택 링(블루, 바닥) ----
  const ring = new THREE.Mesh(new THREE.RingGeometry(.9, 1, 64), new THREE.MeshBasicMaterial({ color: BLUE, side: THREE.DoubleSide, depthTest: false, transparent: true }));
  ring.rotation.x = -Math.PI / 2;
  ring.renderOrder = 20;
  ring.visible = false;
  ring.raycast = () => {};
  scene.add(ring);
  function setRing(r) {
    ring.geometry.dispose();
    ring.geometry = new THREE.RingGeometry(r - .12, r, 64);
  }

  // ---- 이름표 ----
  const labelRoot = new CSS2DRenderer();
  Object.assign(labelRoot.domElement.style, { position: 'fixed', inset: '0', pointerEvents: 'none', overflow: 'hidden' });
  labelRoot.domElement.id = 'c3d-labels';
  const ui = document.getElementById('ui');
  document.body.insertBefore(labelRoot.domElement, ui); // 관제 카드 아래, 캔버스 위
  function mkLabel(cls) {
    const el = document.createElement('div'), t = document.createElement('b'), s = document.createElement('span');
    el.className = 'c3dl ' + cls;
    el.append(t, s);
    const o = new CSS2DObject(el);
    o.userData.t = t; o.userData.s = s; o.userData.key = '';
    return o;
  }
  function setLabel(o, title, sub) {
    const key = title + '|' + sub;
    if (o.userData.key === key) return;
    o.userData.key = key;
    o.userData.t.textContent = title;
    o.userData.s.textContent = sub;
    o.userData.s.hidden = !sub;
  }
  const siteLabels = {};
  Object.entries(SITE).forEach(([id, s]) => {
    const o = mkLabel('bld');
    setLabel(o, s.name, '');
    o.position.set(s.x + s.w / 2, s.h + .9, s.y + s.d / 2);
    scene.add(o);
    siteLabels[id] = o;
  });
  // 트럭·지게차 이름표: 개체(obj)의 자식으로 달고 글자는 바뀔 때만 쓴다.
  // CSS2DObject 는 자기가 장면에서 빠질 때만 DOM 을 지운다 — 트럭 obj 가 빠질 때는 지워지지 않으므로 직접 치운다.
  const dyn = new Map(); // 개체 → 이름표
  function dynLabel(owner, y) {
    let o = dyn.get(owner);
    if (!o) { o = mkLabel('dyn'); o.position.set(0, y, 0); owner.obj.add(o); owner.obj.userData.label = o; dyn.set(owner, o); }
    o.visible = owner.obj.visible; // 숨은 개체의 이름표가 원점에 뜨지 않게
    return o;
  }
  function syncLabels() {
    const { forks, trucks } = haul.list();
    forks.forEach(f => setLabel(dynLabel(f, 1.7), f.code, f.act ? TASK_KO[f.act.kind] || f.act.kind : '대기'));
    trucks.forEach(k => setLabel(dynLabel(k, 2.6), k.code || k.dock, TRUCK_ST[k.st] || (k.inb ? '하차 중' : '상차 중')));
    dyn.forEach((o, owner) => { if (!forks.includes(owner) && !trucks.includes(owner)) { o.element.remove(); dyn.delete(owner); } });
  }

  // ---- 홈 구도 ----
  let homeCache = null;
  const home = () => {
    if (!homeCache) { const c = camera.clone(), tg = new THREE.Vector3(CENTER.x, 0, CENTER.z); fitCampus(c, tg); homeCache = { pos: c.position.clone(), tgt: tg, dist: c.position.distanceTo(tg) }; }
    return homeCache;
  };
  addEventListener('resize', () => { homeCache = null; });

  // ---- 선택·비행·추적 ----
  let sel = null, cur = null, follow = false, fly = null, selLabel = null, farState = null;
  const last = { pos: new THREE.Vector3(), tgt: new THREE.Vector3() }, prev = new THREE.Vector3();

  function startFly(dest, onEnd) {
    fly = { t0: now(), p0: camera.position.clone(), g0: controls.target.clone(), dest, onEnd };
    setTouched(true);
  }
  function release() { fly = null; follow = false; }
  function clearSel() {
    release(); sel = null; cur = null; ring.visible = false;
    if (selLabel) selLabel.element.classList.remove('sel');
    selLabel = null;
  }

  function onSelect(type, code) {
    let loc = locate(type, code);
    if (!loc) { const c = fallbackSite(type, code); if (c) { type = 'site'; code = c; loc = locate(type, code); } }
    if (!loc) return;
    release();
    sel = { type, code }; cur = loc;
    if (selLabel) selLabel.element.classList.remove('sel');
    selLabel = null;
    setRing(loc.ring);
    const dest = () => {
      const g = loc.get();
      if (g) { last.tgt.copy(g); last.pos.copy(g).addScaledVector(DIR, loc.dist); }
      return last;
    };
    dest();
    follow = loc.moving; // camera().following 은 선택 즉시 켜진다. 비행이 끝난 뒤부터 대상의 이동량만큼 따라간다
    startFly(dest, () => { const g = follow && cur === loc && loc.get(); if (g) prev.copy(g); });
  }
  addEventListener('c3d:select', e => { const d = e.detail || {}; if (d.type && d.code != null) onSelect(d.type, String(d.code)); });

  function goKey(k) {
    if (k === '0') { clearSel(); setTouched(true); startFly(() => { const h = home(); last.pos.copy(h.pos); last.tgt.copy(h.tgt); return last; }, () => setTouched(false)); }
    else if (KEY_SITE[k]) window.dispatchEvent(new CustomEvent('c3d:select', { detail: { type: 'site', code: KEY_SITE[k] } }));
  }
  addEventListener('keydown', e => {
    if (e.ctrlKey || e.metaKey || e.altKey || typing(e.target)) return;
    if (e.key === 'Escape') release();
    else if (/^[0-7]$/.test(e.key)) goKey(e.key);
  });

  // ---- 클릭 선택 / 드래그하면 해제 ----
  const ray = new THREE.Raycaster(), ndc = new THREE.Vector2();
  const shown = o => { for (; o; o = o.parent) if (!o.visible) return false; return true; };
  function resolveHit(h) {
    for (let o = h.object; o; o = o.parent) if (o.userData && o.userData.pick) { const s = o.userData.pick(); if (s) return s; break; }
    const bin = binAt(h.point);
    if (bin) return { type: 'bin', code: bin };
    const site = siteAt(h.point);
    return site ? { type: 'site', code: site } : null;
  }
  function pickAt(cx, cy) {
    const r = canvas.getBoundingClientRect();
    ndc.set((cx - r.left) / r.width * 2 - 1, -((cy - r.top) / r.height) * 2 + 1);
    ray.setFromCamera(ndc, camera);
    for (const h of ray.intersectObjects(scene.children, true)) { if (!shown(h.object)) continue; const s = resolveHit(h); if (s) return s; }
    return null;
  }
  let down = null;
  canvas.addEventListener('pointerdown', e => { down = { x: e.clientX, y: e.clientY, moved: false, btn: e.button }; });
  canvas.addEventListener('pointermove', e => {
    if (!down || down.moved) return;
    if (Math.hypot(e.clientX - down.x, e.clientY - down.y) > DRAG_PX) { down.moved = true; release(); } // 드래그 = 추적·비행 해제
  });
  canvas.addEventListener('pointerup', e => {
    const d = down; down = null;
    if (!d || d.moved || d.btn !== 0) return;
    const s = pickAt(e.clientX, e.clientY);
    if (s) window.dispatchEvent(new CustomEvent('c3d:select', { detail: s }));
  });
  canvas.addEventListener('pointercancel', () => { down = null; });

  // ---- 녹화 투어: steps = [{key} | {select:{type,code}}, hold(ms)] — 단계 시작에서 hold 만큼 시계가 흐르면 다음으로 ----
  let T = null;
  function stepTour(t) {
    while (T && t >= T.until) {
      T.i++;
      if (T.i >= T.steps.length) { const done = T.done; T = null; done(); return; }
      const s = T.steps[T.i] || {};
      if (s.key != null) goKey(String(s.key));
      else if (s.select) window.dispatchEvent(new CustomEvent('c3d:select', { detail: s.select }));
      T.until = t + (Number.isFinite(s.hold) ? s.hold : 3000);
    }
  }
  function tour(steps) {
    if (T) T.done(); // 먼저 돌던 투어는 끝낸 것으로 친다
    return new Promise(res => { T = { steps: Array.isArray(steps) ? steps : [], i: -1, until: now(), done: res }; stepTour(now()); });
  }

  // ---- 매 프레임(haul.tick 뒤) ----
  function tick(t) {
    syncLabels();
    if (sel && !cur.get()) clearSel(); // 트럭이 떠났다
    if (fly) {
      const u = clamp01((t - fly.t0) / FLY_MS), d = fly.dest(), e = ease(u);
      camera.position.lerpVectors(fly.p0, d.pos, e);
      controls.target.lerpVectors(fly.g0, d.tgt, e);
      if (u >= 1) { const end = fly.onEnd; fly = null; if (end) end(); }
    } else if (follow && cur) {
      const g = cur.get();
      if (g) { const dx = g.x - prev.x, dy = g.y - prev.y, dz = g.z - prev.z; camera.position.x += dx; camera.position.y += dy; camera.position.z += dz; controls.target.x += dx; controls.target.y += dy; controls.target.z += dz; prev.copy(g); }
    }
    if (sel) {
      const g = cur.get();
      if (g) { ring.visible = true; ring.position.set(g.x, cur.ringY != null ? cur.ringY : .12, g.z); }
      const lb = cur.label && cur.label();
      if (lb !== selLabel) { if (selLabel) selLabel.element.classList.remove('sel'); selLabel = lb || null; if (selLabel) selLabel.element.classList.add('sel'); }
    }
    const far = camera.position.distanceTo(controls.target) > home().dist * .8; // 처음 구도 근처에서는 건물 이름만
    if (far !== farState) { farState = far; labelRoot.domElement.classList.toggle('far', far); }
    stepTour(t);
  }

  return {
    tick, home: () => goKey('0'), tour, release,
    render: () => labelRoot.render(scene, camera),
    resize: () => labelRoot.setSize(window.innerWidth, window.innerHeight),
    camera: () => ({ position: vec(camera.position), target: vec(controls.target), following: follow && sel ? sel.code : null, flying: !!fly, selected: sel ? { ...sel } : null }),
  };
}
