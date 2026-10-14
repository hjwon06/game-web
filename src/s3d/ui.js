// 화면 카드(C1~C6)의 값. 3D 장면과 같은 data.js 의 값을 읽기만 한다(새 폴링 없음).
// 시각은 재생 시각(playTime), 그 밖의 값은 재생 시각에 맞춰 적용된 S.shown · S.settlements 다.
import { S, isFrozen, speedNow } from './data.js';
import { STOCKS } from './layout.js';
import { rowView } from './board.js';

export const PHASE_LABEL = { pre_open: '장전 단일가', continuous: '장중', closing: '종가 단일가', closed: '장 마감' };
const NEXT = { pre_open: '09:00 시가 단일가 · 랜덤엔드 30초 이내', continuous: '15:20 종가 단일가',
  closing: '15:30 장 마감', closed: '다음 영업일 08:30' };
// 하루 시간표(08:30 시작, 실제 분 비율): 장전 30 · 장중 380 · 종가 10 · 밤 1020
export const SEG_MIN = [30, 380, 10, 1020];
const DAY_MIN = 1440, START_MIN = 8 * 60 + 30;
const SEG_OF = { pre_open: 0, continuous: 1, closing: 2, closed: 3 };
const REASON = { insufficient: '잔고 부족', price_limit: '가격 제한', tick: '호가 단위', closed: '장 외' };
const WD = '일월화수목금토';
const p2 = n => String(n).padStart(2, '0');
const won = n => Number(n).toLocaleString('ko-KR');

// ms → KST 달력 값(서버 시각은 +09:00 고정이라 오프셋만 더해 UTC 게터로 읽는다)
export function kst(ms) {
  const d = new Date(ms + 9 * 36e5);
  return { y: d.getUTCFullYear(), mo: d.getUTCMonth() + 1, d: d.getUTCDate(), wd: WD[d.getUTCDay()],
    h: d.getUTCHours(), mi: d.getUTCMinutes(), s: d.getUTCSeconds() };
}
const md = iso => { // 'YYYY-MM-DD' → '11월 2일 월'
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso || '');
  if (!m) return null;
  return `${+m[2]}월 ${+m[3]}일 ${WD[new Date(Date.UTC(+m[1], +m[2] - 1, +m[3])).getUTCDay()]}`;
};

// 단계는 재생 시각으로 정한다(서버 clock.phase 는 재생보다 실시간 6초 앞선다). 시각 기준은 Phase 표와 같다:
// 08:30 장전 단일가 · 09:00 장중 · 15:20 종가 단일가 · 15:30 장 마감. 재생 날짜가 거래일(clock.trade_date)이 아니면 휴장.
export function phaseAt(P, tradeDate) {
  if (P == null) return null;
  const t = kst(P);
  if (tradeDate && `${t.y}-${p2(t.mo)}-${p2(t.d)}` !== String(tradeDate).slice(0, 10)) return 'closed';
  const m = t.h * 60 + t.mi;
  return m < 8 * 60 + 30 ? 'closed' : m < 9 * 60 ? 'pre_open' : m < 15 * 60 + 20 ? 'continuous' : m < 15 * 60 + 30 ? 'closing' : 'closed';
}

// P: 재생 시각(시장 ms | null), real: 실제 시각(ms)
export function model(P, real) {
  const sh = S.shown, c = sh.clock, t = P == null ? null : kst(P);
  const phase = phaseAt(P, c && c.trade_date);
  const stopped = S.ok && (!S.clock || !!S.clock.stale || isFrozen());
  const hm = t ? `${p2(t.h)}:${p2(t.mi)}` : '--:--';
  const rows = STOCKS.map(s => {
    const r = sh.board.find(x => x.code === s.code);
    if (!r) return { code: s.code, name: s.name, last: null, change: null, px: '–', rt: '–', color: '#6B7280', vol: '–', buy: '–', sell: '–', ratio: .5 };
    const v = rowView(r), b = r.open_buy_qty || 0, q = r.open_sell_qty || 0;
    return { code: s.code, name: s.name, last: r.last_price, change: r.change, px: v.price, rt: v.rate, color: v.color,
      vol: won(r.volume || 0), buy: v.buy, sell: v.sell, ratio: b + q ? b / (b + q) : .5 };
  });
  const td = sh.today;
  const rej = td ? Object.entries(td.rejected || {}).sort((a, b) => b[1] - a[1]) : [];
  const rejTotal = rej.reduce((n, e) => n + e[1], 0);
  const settled = S.settlements.find(s => s.status === 'settled') || null;
  const rec = sh.reconcile;
  const rt = kst(real);
  return {
    ok: S.ok, stopped, conn: S.err, stage: phase ? PHASE_LABEL[phase] || phase : null, phase,
    seg: phase ? SEG_OF[phase] : null,
    mark: !t ? null : (((t.h * 60 + t.mi + t.s / 60 - START_MIN) % DAY_MIN) + DAY_MIN) % DAY_MIN / DAY_MIN,
    hm, sec: t ? p2(t.s) : '--',
    date: md(c && c.trade_date) || (t ? `${t.mo}월 ${t.d}일 ${t.wd}` : '–'),
    next: phase ? NEXT[phase] || '–' : '–',
    speed: speedNow(), real: `${p2(rt.h)}:${p2(rt.mi)}:${p2(rt.s)}`,
    rows,
    today: td ? {
      orders: td.orders, executions: td.executions, value: td.value,
      reject: rejTotal ? `${REASON[rej[0][0]] || rej[0][0]} ${rej[0][1]}건` : '거절 0', rejTotal,
      reconcile: rec == null ? '확인 중' : rec === 0 ? '0건 · 원장 = 잔고' : `${rec}건 어긋남`, reconcileCount: rec == null ? null : rec,
      settled: settled ? `${(md(settled.settle_date) || settled.settle_date).replace(/ [일월화수목금토]$/, '')} · 원장 ${settled.entries}줄` : '없음',
      settledRaw: settled ? { date: settled.settle_date, entries: settled.entries } : null,
    } : null,
  };
}

// window.__s3d.ui() 의 모양: {time, phase, next, rows:[{code, last, change}], today}
export function summary(m) {
  const t = m.today;
  return {
    time: m.hm, sec: m.sec, date: m.date, phase: m.phase, stage: m.stage, next: m.next, speed: m.speed,
    stopped: m.stopped, connected: !m.conn,
    rows: m.rows.map(r => ({ code: r.code, last: r.last, change: r.change })),
    today: t && { orders: t.orders, executions: t.executions, value: t.value, rejected: t.rejTotal, reject: t.reject,
      reconcile: t.reconcileCount, settled: t.settledRaw },
  };
}
