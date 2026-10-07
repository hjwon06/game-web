// 벨트: layout.belt.route(꺾이는 점 목록)를 칸으로 펼치고, 기계 사이마다 구간(seg)을 나눈다.
// 구간은 이어진 기계(앞·뒤) 중 하나라도 running 일 때만 돌고, 아이템은 구간 안에서만 흐른다. 아이템 종류는 구간 뒤쪽 기계의 구역이 정한다.
import { itemFrame } from './scene_draw.js';

const SPEED = 1.0; // 칸/초
const GAP = 1.5; // 아이템 간격(칸)
const DIRS = { right: 'right', left: 'left', down: 'down', up: 'up' };

// 꺾이는 칸에서 남기는 반쪽(프레임 안 x, y, w, h). 벨트 한 칸은 32px.
const HALF = 16;
const HALF_IN = { right: [0, 0, HALF, 32], left: [HALF, 0, HALF, 32], down: [0, 0, 32, HALF], up: [0, HALF, 32, HALF] };
const HALF_OUT = { right: [HALF, 0, HALF, 32], left: [0, 0, HALF, 32], down: [0, HALF, 32, HALF], up: [0, 0, 32, HALF] };

export function expandRoute(route) {
  const cells = [];
  for (let i = 0; i < route.length - 1; i++) {
    const [ax, ay] = route[i];
    const [bx, by] = route[i + 1];
    const dx = Math.sign(bx - ax);
    const dy = Math.sign(by - ay);
    const dir = dx > 0 ? 'right' : dx < 0 ? 'left' : dy > 0 ? 'down' : 'up';
    for (let x = ax, y = ay; x !== bx || y !== by; x += dx, y += dy) cells.push({ x, y, dir });
  }
  const last = route[route.length - 1];
  cells.push({ x: last[0], y: last[1], dir: cells.length ? cells[cells.length - 1].dir : 'right' });
  return cells;
}

export function buildBelt(scene, f, add) {
  const { belt, items } = scene.sp;
  const cells = expandRoute(f.belt.route);
  const pts = cells.map((c) => scene.px(c.x, c.y));
  const at = new Map(cells.map((c, i) => [`${c.x},${c.y}`, i]));
  const ms = f.machines
    .map((m) => ({ m, i: at.get(`${m.x},${m.y}`) }))
    .filter((e) => e.i !== undefined)
    .sort((a, b) => a.i - b.i);
  const zoneItem = (m) => f.zones.find((z) => z.id === m?.zone)?.item ?? 0;
  const segs = [];
  for (let k = 0; k <= ms.length; k++) {
    const from = ms[k - 1];
    const to = ms[k];
    segs.push({
      from: from?.m.id,
      to: to?.m.id,
      start: from ? from.i : 0,
      end: to ? to.i : cells.length - 1,
      frame: itemFrame(items.frames[zoneItem((to || from)?.m)] ?? items.frames[0]),
      running: false,
      cells: [],
      items: [],
      since: 0,
    });
  }
  cells.forEach((c, i) => {
    const seg = segs[ms.filter((e) => e.i < i).length];
    const prev = i > 0 && cells[i - 1].dir !== c.dir ? cells[i - 1].dir : null;
    const put = (dir, keep) => {
      const frames = belt[DIRS[dir]];
      const spr = add(scene.add.image(pts[i].x, pts[i].y, 'tiles', frames[0]).setScale(scene.zoom).setDepth(1));
      if (keep) {
        // 자른 반쪽은 프레임을 바꾸지 않는다(setFrame 뒤 crop 유지 여부에 기대지 않기 위해). 애니 목록에도 넣지 않는다.
        spr.setCrop(...keep);
        return;
      }
      seg.cells.push({ spr, frames });
    };
    // 꺾이는 칸: 코너 그림이 없어서(sprites.json belt.corner = null) 들어오는 쪽 반 칸 + 나가는 쪽 반 칸을 고정 프레임 2장으로 맞대 ㄱ 자로 잇는다.
    if (prev) {
      put(prev, HALF_IN[prev]);
      put(c.dir, HALF_OUT[c.dir]);
    } else put(c.dir);
  });
  const b = { cells, pts, segs, phase: 0, scene };
  // 멈춘 벨트에서도 아이템이 보이도록 구간마다 미리 채운다.
  segs.forEach((seg) => {
    for (let s = seg.end - 0.5; s > seg.start; s -= GAP) {
      addItem(b, seg, s);
      seg.since = s - seg.start; // 가장 뒤 아이템이 출발점에서 떨어진 거리 = 다음 생성까지 이미 흐른 거리
    }
  });
  return b;
}

// 아이템은 계속 생기고 사라지므로 씬의 추적 목록(objs)에 넣지 않는다. 정리는 destroyBelt 가 맡는다.
function addItem(b, seg, s) {
  const spr = b.scene.add.image(0, 0, 'tiles', seg.frame).setScale(b.scene.zoom).setDepth(5);
  const it = { s, spr };
  placeItem(b, it);
  seg.items.push(it);
}

function placeItem(b, it) {
  const i = Math.min(Math.floor(it.s), b.pts.length - 2);
  const t = it.s - i;
  const a = b.pts[i];
  const z = b.pts[i + 1] || a;
  it.spr.setPosition(a.x + (z.x - a.x) * t, a.y + (z.y - a.y) * t);
}

export function destroyBelt(b) {
  b?.segs.forEach((seg) => seg.items.forEach((it) => it.spr.destroy()));
}

// machines: Map<id, view>. 이어진 기계 중 하나라도 running 이면 구간이 돈다.
export function setBeltRunning(b, machines) {
  b.segs.forEach((seg) => {
    seg.running = [seg.from, seg.to].some((id) => id && machines.get(id)?.state === 'running');
  });
}

export function updateBelt(b, dt, frameMs) {
  b.phase += dt * 1000;
  const k = Math.floor(b.phase / frameMs);
  b.segs.forEach((seg) => {
    if (!seg.running) return;
    seg.cells.forEach((c) => c.spr.setFrame(c.frames[k % c.frames.length]));
    seg.since += SPEED * dt;
    if (seg.since >= GAP) {
      seg.since -= GAP;
      addItem(b, seg, seg.start);
    }
    seg.items = seg.items.filter((it) => {
      it.s += SPEED * dt;
      if (it.s >= seg.end) {
        it.spr.destroy();
        return false;
      }
      placeItem(b, it);
      return true;
    });
  });
}
