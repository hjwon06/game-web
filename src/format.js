// 표시용 계산·포맷. DOM 도 Phaser 도 모른다. 상태 객체만 받는다.
const ISO_HEAD = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/;

// ISO 문자열 -> "YYYY.MM.DD HH:mm". 문자열에 적힌 시각 그대로 쓴다(브라우저 타임존에 따라 흔들리지 않게).
// 모양이 다르면 빈 문자열 — 원문을 화면에 내보내지 않는다.
export function formatTime(iso) {
  const m = ISO_HEAD.exec(String(iso));
  return m ? `${m[1]}.${m[2]}.${m[3]} ${m[4]}:${m[5]}` : '';
}

export function summarize(state) {
  const machines = (state && state.machines) || [];
  const count = (s) => machines.filter((m) => m.state === s).length;
  return {
    total: machines.length,
    running: count('running'),
    stopped: count('stopped'),
    defect: count('defect'),
    processedSum: machines.reduce((sum, m) => sum + (Number(m.processed) || 0), 0),
  };
}

export function incomingBelts(state, id) {
  const belts = (state && state.conveyors) || [];
  return belts.filter((c) => c.to === id).length;
}
