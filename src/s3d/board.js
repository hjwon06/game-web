// 3D 숫자 판: 남쪽을 보는 판에 CanvasTexture 5줄 — 종목명 · 현재가 · 등락률 · 매수 잔량 · 매도 잔량.
// 상승 #C0392B ▲ · 하락 #2563EB ▼ · 0 은 #6B7280. board 가 바뀔 때(S.ver)만 다시 그린다.
import * as THREE from 'three';
import { part } from '../c3d/models.js';
import { S } from './data.js';
import { BOARD, STOCKS, NAVY } from './layout.js';

const W = 1024, H = 696, ROW = H / 5;
const UP = '#C0392B', DOWN = '#2563EB', FLAT = '#6B7280', INK = '#1A1A2E';
const won = n => Number(n).toLocaleString('ko-KR');

export function rowView(r) {
  const base = r.base_price || 0, chg = Number(r.change) || 0;
  const pct = base ? chg / base * 100 : 0;
  const color = chg > 0 ? UP : chg < 0 ? DOWN : FLAT, mark = chg > 0 ? '▲' : chg < 0 ? '▼' : '';
  return { name: r.name, price: won(r.last_price), rate: `${mark}${mark ? ' ' : ''}${chg > 0 ? '+' : ''}${pct.toFixed(2)}%`, color,
    buy: won(r.open_buy_qty || 0), sell: won(r.open_sell_qty || 0) };
}

export function createBoard(parent) {
  const cv = document.createElement('canvas');
  cv.width = W; cv.height = H;
  const g = cv.getContext('2d'), tex = new THREE.CanvasTexture(cv);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.anisotropy = 4;

  const { x, z, w, h, y0 } = BOARD, th = .12;
  const panel = new THREE.Mesh(new THREE.PlaneGeometry(w, h), new THREE.MeshBasicMaterial({ map: tex }));
  panel.name = 'board';
  panel.position.set(x, y0 + h / 2, z + th / 2 + .01); // 평면은 +z(남쪽)를 본다
  parent.add(panel);
  part(parent, w + .2, h + .2, th, NAVY, x, y0 + h / 2, z, .7);                       // 네이비 틀
  for (const sx of [-1, 1]) part(parent, .14, y0, .14, 0x6B7280, x + sx * (w / 2 - .5), y0 / 2, z, .8); // 다리

  let ver = -1;
  function draw() {
    g.fillStyle = '#FFFFFF'; g.fillRect(0, 0, W, H);
    const rows = STOCKS.map(s => S.board.find(r => r.code === s.code) || { name: s.name, last_price: 0, change: 0, base_price: 0 });
    rows.forEach((r, i) => {
      const v = rowView(r), y = i * ROW, mid = y + ROW / 2;
      if (i) { g.fillStyle = '#E5E7EB'; g.fillRect(0, y, W, 2); }
      g.fillStyle = STOCKS[i].color; g.fillRect(0, y + 10, 14, ROW - 20);
      g.textBaseline = 'middle';
      g.font = '700 40px Pretendard, sans-serif';
      g.fillStyle = INK; g.textAlign = 'left'; g.fillText(v.name || STOCKS[i].name, 34, mid);
      g.textAlign = 'right';
      g.fillStyle = v.color; g.fillText(v.price, 560, mid);
      g.font = '600 34px Pretendard, sans-serif';
      g.fillText(v.rate, 790, mid);
      g.font = '500 24px Pretendard, sans-serif';
      g.fillStyle = DOWN; g.fillText('매수 ' + v.buy, W - 24, mid - 18);
      g.fillStyle = UP; g.fillText('매도 ' + v.sell, W - 24, mid + 18);
    });
    tex.needsUpdate = true;
  }
  // 글꼴이 늦게 도착하면 한 번 더 그린다
  if (document.fonts) document.fonts.ready.then(() => { ver = -1; });

  return { tick() { if (ver !== S.ver) { ver = S.ver; draw(); } }, canvas: cv };
}
