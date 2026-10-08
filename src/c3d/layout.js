// 3D 단지 배치 데이터. src/campus/campus_data.js · campus_world.js 의 값을 3D 좌표로 옮겼다.
// 2D 그리드 (x, y) → 3D (x, 0, y), 1칸 = 1 단위. 높이는 2D 의 h(px) / 12.
// 2D 쪽 값이 바뀌면 여기도 같이 고친다(2D 파일은 전역 스크립트라 import 할 수 없다).
export const PX = 1 / 12;

export const GW = 46, GH = 34;
export const HALL = { x: 5, y: 15, w: 19, d: 12 };

// real = 실데이터 장소, api = /api/campus buildings 의 키
export const BUILDINGS = [
  { id: 'office', name: '수주 사무동', x: 5, y: 4, w: 7, d: 6, h: 96, top: '#E9ECF1', real: true, api: 'office' },
  { id: 'mat', name: '자재창고', x: 15, y: 3, w: 8, d: 7, h: 64, top: '#E4E7EB', real: true, api: 'material' },
  { id: 'maint', name: '정비동', x: 28, y: 3, w: 5, d: 5, h: 48, top: '#E4E7EB', real: false },
  { id: 'util', name: '유틸리티', x: 37, y: 2, w: 5, d: 5, h: 40, top: '#E4E7EB', real: false },
  { id: 'qc', name: '품질검사동', x: 28, y: 23.5, w: 6, d: 6, h: 58, top: '#E6EEEC', real: true, api: 'qc' },
  { id: 'ship', name: '출하장', x: 35, y: 18.4, w: 8, d: 5.4, h: 46, top: '#EBEDF0', real: true, api: 'shipping' },
].map(b => ({ ...b, h: b.h * PX }));

// 도크 문 자리(남쪽 면). 문 모델은 3D-②. 2D 도크 칸: 자재창고 x=16.7+i*2.8, 출하장 x=36.2+i*2.4
export const DOCKS = [
  { building: 'mat', face: 's', slots: [0, 1, 2].map(i => ({ x: 16.7 + i * 2.8, y: 10.2, w: 1.1, d: 1.9 })) },
  { building: 'ship', face: 's', slots: [0, 1, 2].map(i => ({ x: 36.2 + i * 2.4, y: 24.3, w: 1.1, d: 1.9 })) },
];

export const PLAZA = { x: 1, y: 1, w: 42, d: 31 };
// 도로 사각형 [x, y, w, d]
export const ROADS = [[2.6, 11.6, 40, 1.8], [2.6, 1.2, 1.8, 29], [13.2, 1.2, 1.6, 12], [25.4, 1.2, 1.6, 29], [26, 15.4, 18.5, 1.8], [2.6, 29, 24, 1.6]];
// 도로 중앙 점선 [[x1,y1],[x2,y2]]
export const ROAD_DASHES = [[[3.5, 12.5], [42, 12.5]], [[26.2, 2], [26.2, 30]], [[26, 16.3], [44, 16.3]]];

// 단지 밖 외곽도로 [x, y, w, d] + 정문 앞 진입로
export const OUTER_ROADS = [[-3.2, -3.2, GW + 6.4, 1.6], [-3.2, GH + 1.6, GW + 6.4, 1.6], [-3.2, -3.2, 1.6, GH + 6.4], [GW + 1.6, -3.2, 1.6, GH + 6.4], [GW + 1.6, 15.2, 22, 2.2]];
export const OUTER_DASH = [[GW + 2.4, 16.3], [GW + 22, 16.3]];

export const GATE = { x: 42.6, y: 14.6, w: 1.2, d: 1, h: 30 * PX, openY0: 14.8, openY1: 17.6 };

export const HYDRANT = { x: 12.4, y: 13.7 };

// 나무 자리 [x, y]: 단지 가장자리 + 단지 밖 숲(2D 와 같은 시드)
const EDGE_TREES = [[1, 33], [4, 33], [8, 33], [12, 33], [18, 33], [22, 33], [30, 33], [34, 33], [38, 33], [42, 33], [45, 30], [45, 26], [45, 22], [45, 8], [45, 4]];
function outsideTrees() {
  let s = 7;
  const r = () => { s = (s * 9301 + 49297) % 233280; return s / 233280; };
  const out = [];
  for (let i = 0; i < 260; i++) {
    const x = -22 + r() * (GW + 44), y = -22 + r() * (GH + 44), q = r();
    if (x > -4 && x < GW + 4 && y > -4 && y < GH + 4) continue;
    if (q < .55) out.push([x, y]);
  }
  return out;
}
export const TREES = [...EDGE_TREES, ...outsideTrees()];

export const CENTER = { x: GW / 2, z: GH / 2 };
