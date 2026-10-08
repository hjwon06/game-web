// 이동 애니메이션: /api/campus moves 한 건 = 화물 하나가 출발 건물에서 도착 건물로(약 4초).
// 입고(receive)는 국도 트럭이 정문에 닿은 뒤 화물이 출발한다. 동시 화물은 최대 12개, 넘치면 ×N 으로 합친다.
const NODE={gate:[44.5,16.3],j1:[26.2,16.3],j2:[26.2,12.5],j3:[14,12.5],j4:[3.5,12.5],j5:[26.2,26.5],j6:[39,16.3],
  mat:[14,7.5],prod:[3.5,17.6],qc:[27.6,26.5],ship:[39,18.4],scrap:[35.6,26.5]};
const EDGE=[['gate','j6'],['j6','j1'],['j6','ship'],['j1','j2'],['j1','j5'],['j2','j3'],['j3','j4'],['j3','mat'],['j4','prod'],['j5','qc'],['qc','scrap']];
const PLACE={supplier:'gate',customer:'gate',receiving:'mat',raw_store:'mat',production:'prod',qc:'qc',fg_store:'ship',scrap:'scrap'};
const ADJ={};EDGE.forEach(([a,b])=>{(ADJ[a]=ADJ[a]||[]).push(b);(ADJ[b]=ADJ[b]||[]).push(a);});
const CARGO=[],QUEUE=[],TRUCKS=[];
const CAP=12,DUR=4000,GAP=250,TRUCK_MS=4000,QUEUE_MAX=60,DOCK_MS=60000;
let lastSpawn=0;

function route(a,b){ // 도로 그래프 위 최단 경로 → 좌표 목록
  if(a===b){const [x,y]=NODE[a];return[[x,y],[x+1.4,y]];} // 같은 건물 안 이동: 짧게 건물 쪽으로
  const prev={[a]:null},q=[a];
  while(q.length){const n=q.shift();if(n===b)break;(ADJ[n]||[]).forEach(m=>{if(!(m in prev)){prev[m]=n;q.push(m);}});}
  const path=[];for(let n=b;n!=null;n=prev[n])path.unshift(NODE[n]);
  return path;
}
const polyLen=pts=>pts.slice(1).reduce((s,p,i)=>s+Math.hypot(p[0]-pts[i][0],p[1]-pts[i][1]),0);
function along(pts,len,u){let d=u*len;for(let i=0;i<pts.length-1;i++){const a=pts[i],b=pts[i+1],l=Math.hypot(b[0]-a[0],b[1]-a[1]);if(d<=l&&l>0)return[a[0]+(b[0]-a[0])*d/l,a[1]+(b[1]-a[1])*d/l];d-=l;}return pts[pts.length-1];}

function enqueueMoves(ms){
  ms.forEach(mv=>{QUEUE.push(mv);if(mv.type==='ship')S.shipAt.push(performance.now());});
  while(QUEUE.length>QUEUE_MAX)QUEUE.shift();
}
function spawn(mv,t){
  const a=PLACE[mv.from_code],b=PLACE[mv.to_code];if(!a||!b)return;
  let t0=t;
  if(mv.type==='receive'){if(TRUCKS.length<3)TRUCKS.push({t0:t});t0=t+TRUCK_MS;}
  const key=a+'>'+b;
  if(CARGO.length>=CAP){ // 넘치면 같은 길의 화물에 합친다(없으면 가장 최근 화물)
    const hit=CARGO.slice().reverse().find(c=>c.key===key)||CARGO[CARGO.length-1];hit.n++;return;}
  const pts=route(a,b);
  CARGO.push({pts,len:polyLen(pts),t0,n:1,label:mv.ref||mv.product||'',key});
}
function tickFlow(t){
  if(QUEUE.length&&t-lastSpawn>=GAP){spawn(QUEUE.shift(),t);lastSpawn=t;}
  for(let i=CARGO.length-1;i>=0;i--)if(t-CARGO[i].t0>DUR)CARGO.splice(i,1);
  for(let i=TRUCKS.length-1;i>=0;i--)if(t-TRUCKS[i].t0>TRUCK_MS*1.2)TRUCKS.splice(i,1);
  while(S.shipAt.length&&t-S.shipAt[0]>DOCK_MS)S.shipAt.shift();
}
const inHallRect=(x,y)=>x>HALL.x&&x<HALL.x+HW&&y>HALL.y&&y<HALL.y+HH;
function drawCargo(t){
  CARGO.forEach(c=>{const u=(t-c.t0)/DUR;if(u<0||u>1)return;const [x,y]=along(c.pts,c.len,u);
    if(inHallRect(x,y))return; // 생산동 안은 벨트가 대신 보여준다
    box(x-.32,y-.25,.64,.5,12,'#0E7C86',1);box(x-.24,y-.18,.48,.36,8,'#C9A227',13);
    if(Z>.45){const l=c.n>1?`${c.label} ×${c.n}`:c.label;const p=P(x,y,30);g.font=`600 ${9.5*Math.max(1,Z/.5)}px Outfit`;const w=g.measureText(l).width+8;g.fillStyle='rgba(255,255,255,.92)';g.fillRect(p[0]-w/2,p[1]-10,w,13);g.fillStyle='#0E7C86';g.textAlign='center';g.fillText(l,p[0],p[1]);g.textAlign='left';}
  });
}
function drawInTrucks(t){ // 국도에서 정문으로 들어오는 입고 트럭
  TRUCKS.forEach(k=>{const u=Math.min(1,(t-k.t0)/TRUCK_MS),x=GW+21-u*(GW+21-45.2);
    box(x,15.5,1.6,.9,20,'#E5E7EB',0,'#B8BEC6');box(x-.7,15.55,.7,.8,16,'#2F6B4F',0);});
}
function trucksAtDock(){ // 출하 대기 트럭: 최근 60초 안에 본 출하 이동 수(최대 3)
  const n=Math.min(3,S.shipAt.length);for(let i=0;i<n;i++){const x=36+i*2.4,y=24.4;box(x,y,1.4,1.5,26,'#F4F5F7',0,'#C9CED6');box(x+.05,y+1.5,1.3,.8,22,'#1E3A5F',0);}
}
function drawScrap(){ // 품질검사동 옆 폐기 더미
  const [x,y]=NODE.scrap;[[0,0,10],[.5,.2,7],[-.2,.5,5]].forEach(([dx,dy,h])=>box(x+dx,y+dy-.3,.6,.5,h,'#7B8490',0));
}
