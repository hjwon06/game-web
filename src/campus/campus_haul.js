// 운반 주체: 지게차 2대(상시) · 트럭 최대 2대 · 검사 작업자 1명 = 동시에 최대 5. 화물은 지게차에 실려서만 움직인다.
// 위치는 작업(tasks)에서 나온다: started_at~expected_finish_at 을 서버 시계(srvNow)로 보간. 이벤트를 받은 즉시 쏘지 않는다.
const VIS_MIN=4000,VIS_MAX=10000,FORK_N=2,TRUCK_MAX=2,CHASE=14,ENTER_MS=5000,LEAVE_MS=4000,HOLD_MS=2000,PRUNE_MS=30000;
const FORKS=[],TRUCKS=[],FORK_KINDS=['putaway','pick','feed'];
const NODEB={mat:'mat',prod:'prod',qc:'qc',ship:'ship',gate:'gate',office:'office'};
const BNAME={mat:'자재창고',prod:'생산동',qc:'품질검사동',ship:'출하장',gate:'정문',office:'수주 사무동'};
const ROLE={forklift:'지게차',dock_in:'트럭',dock_out:'트럭',worker:'작업자'};
const WORKER_AT=[31,30.2],APRON=[14.2,10.4];
const byCode=(a,b)=>a.code<b.code?-1:1;

function visWin(t){ // 화면에 보이는 운반 구간(서버 ms). 길이를 4~10초로 맞춘다
  if(t.t0==null)return null;
  const end=Math.max(t.t1||0,t.tf||0)||t.t0+VIS_MIN,dur=end-t.t0;
  return dur>VIS_MAX?[end-VIS_MAX,end]:dur<VIS_MIN?[t.t0,t.t0+VIS_MIN]:[t.t0,end];
}
function taskPts(t){ // 작업의 길 좌표. 자재창고 확대 중이면 칸 앞 통로까지 들어간다
  const key=V.vault?'v':'c';if(t._rk===key)return t._r;
  const fb=t.from.b||'mat',tb=t.to.b||'mat',fbin=V.vault&&vaultBin(t.from.code),tbin=V.vault&&vaultBin(t.to.code);
  const end=(b,bin)=>bin?[[bin.xa,bin.cy],[bin.xa,10.4],APRON]:V.vault&&b==='mat'?[APRON]:[];
  let pts=end(fb,fbin).slice(); // 칸 → 통로 → 앞마당 순서
  if(!(V.vault&&fb==='mat'&&tb==='mat'))pts=pts.concat(route(NODEB[fb]||'mat',NODEB[tb]||'mat'));
  pts=pts.concat(end(tb,tbin).reverse());
  if(polyLen(pts)<.01)pts=[pts[0],[pts[0][0]+1.4,pts[0][1]]];
  t._rk=key;t._r={pts,len:polyLen(pts)};return t._r;
}
function homeOf(f){const r=f.res||{},b=bKeyOf(r.home_location_code||(r.home_location&&r.home_location.code)||'',r.home_building)||'mat',n=NODE[NODEB[b]||'mat'];return[n[0],n[1]+.4+f.i*1.1];}
function activeTask(f){
  let best=null;
  S.tasks.forEach(t=>{if(!FORK_KINDS.includes(t.kind)||t.t0==null||resCode(t)!==f.code)return;
    if(t.status!=='started'&&!(t.status==='done'&&!S.arrived.has(t.id)))return;
    if(!best||(t.status==='started'&&best.status!=='started')||(t.status===best.status&&t.t0>best.t0))best=t;});
  return best;
}
function ensureForks(){
  const rs=S.res.filter(r=>r.kind==='forklift').sort(byCode);
  for(let i=0;i<FORK_N;i++){const r=rs[i];let f=FORKS[i];if(!f)f=FORKS[i]={i,code:'F-0'+(i+1),p:null,dir:[1,0],load:null,moving:false};
    if(r){f.code=r.code;f.res=r;}if(!f.p)f.p=homeOf(f).slice();}
}
function stepFork(f,dt,now){
  const act=activeTask(f);let tgt,u=0,tan=null;
  if(act){const w=visWin(act),r=taskPts(act);u=w?Math.max(0,Math.min(1,(now-w[0])/(w[1]-w[0]))):0;tgt=along(r.pts,r.len,u);const a=along(r.pts,r.len,u+.02);tan=[a[0]-tgt[0],a[1]-tgt[1]];}
  else tgt=homeOf(f);
  const dx=tgt[0]-f.p[0],dy=tgt[1]-f.p[1],d=Math.hypot(dx,dy),joined=!!act&&d<=2.2;
  if(joined)f.p=tgt.slice();else if(d>0){const s=Math.min(d,CHASE*dt);f.p=[f.p[0]+dx/d*s,f.p[1]+dy/d*s];}
  const tl=tan&&Math.hypot(tan[0],tan[1]);
  if(joined&&tl>.001)f.dir=[tan[0]/tl,tan[1]/tl];else if(d>.03)f.dir=[dx/d,dy/d];
  f.moving=d>.03||(joined&&u>0&&u<1);f.load=joined?act:null;
}
function wantTrucks(now){ // 지금 트럭이 서 있어야 하는 도크: 시작했거나 곧 시작할 unload·load 가 있는 자원
  const want=new Map();
  S.tasks.forEach(t=>{if(t.kind!=='unload'&&t.kind!=='load')return;
    if(!(t.status==='started'||(t.status==='planned'&&t.planned!=null&&t.planned<=now+15000)))return;
    want.set(t.rid!=null?'r'+t.rid:'c'+t.kind,{inb:t.kind==='unload',rid:t.rid});});
  return want;
}
function truckPath(inb,slot){
  const road=[[GW+21,16.3],[44.5,16.3]];
  return inb?road.concat([[39,16.3],[26.2,16.3],[26.2,12.5],[17.2+slot*2.8,12.5],[17.2+slot*2.8,10.9]])
    :road.concat([[44.3,16.3],[44.3,25.6],[36.9+slot*2.4,25.6],[36.9+slot*2.4,25.1]]);
}
function tickTrucks(t,now){
  const want=wantTrucks(now);
  want.forEach((w,key)=>{const k=TRUCKS.find(x=>x.key===key);
    if(k){k.last=t;return;}
    if(TRUCKS.length>=TRUCK_MAX)return;
    const slot=[0,1,2].find(s=>!TRUCKS.some(x=>x.inb===w.inb&&x.slot===s));
    const pts=truckPath(w.inb,slot);TRUCKS.push({key,inb:w.inb,slot,pts,len:polyLen(pts),st:'enter',t0:t,last:t,code:(resById(w.rid)||{}).code||''});});
  for(let i=TRUCKS.length-1;i>=0;i--){const k=TRUCKS[i];
    if(k.st==='enter'&&t-k.t0>=ENTER_MS){k.st='stand';k.t0=t;}
    if(k.st==='stand'&&t-k.last>HOLD_MS){k.st='leave';k.t0=t;}
    if(k.st==='leave'&&t-k.t0>=LEAVE_MS)TRUCKS.splice(i,1);}
}
function truckAt(k,t){ // 위치와 진행 방향
  const u=k.st==='enter'?Math.min(1,(t-k.t0)/ENTER_MS):k.st==='stand'?1:1-Math.min(1,(t-k.t0)/LEAVE_MS);
  const p=along(k.pts,k.len,u),q=along(k.pts,k.len,u+(k.st==='leave'?-.02:.02)); // q = 진행 쪽 앞점
  let dx=q[0]-p[0],dy=q[1]-p[1];if(Math.hypot(dx,dy)<.001){const n=k.pts.length;dx=k.pts[n-1][0]-k.pts[n-2][0];dy=k.pts[n-1][1]-k.pts[n-2][1];}
  return{p,dx,dy};
}
function tickHaul(t,dt){
  ensureForks();const now=srvNow();
  S.tasks.forEach((k,id)=>{
    if(k.status==='done'&&!S.arrived.has(id)){const w=visWin(k);if(!w||now>=w[1])arrive(k);} // 지게차가 닿은 순간 = 운반 구간이 끝난 순간
    const old=k.tf||k.t1||k.planned||now;
    if((k.status==='done'&&S.arrived.has(id)||k.status==='cancelled')&&now-old>PRUNE_MS){S.tasks.delete(id);S.arrived.delete(id);}});
  FORKS.forEach(f=>stepFork(f,dt,now));
  tickTrucks(t,now);
}
const inspecting=()=>{for(const t of S.tasks.values())if(t.kind==='inspect'&&t.status==='started')return t;return null;};

// ---- 그리기 ----
function tag(text,x,y,color){if(Z<.45)return;g.font=`700 ${9.5*Math.max(1,Z/.5)}px Outfit`;const w=g.measureText(text).width+8;g.fillStyle='rgba(255,255,255,.92)';g.fillRect(x-w/2,y-10,w,13);g.fillStyle=color;g.textAlign='center';g.fillText(text,x,y);g.textAlign='left';}
function drawLift(f){
  const [x,y]=f.p,[dx,dy]=f.dir,h=Math.abs(dx)>=Math.abs(dy),s=(h?dx:dy)>=0?1:-1;
  box(x-.3,y-.3,.6,.6,12,'#C9A227',3);
  if(h)box(x+(s>0?.3:-.54),y-.28,.24,.56,26,'#333A45',3);else box(x-.28,y+(s>0?.3:-.54),.56,.24,26,'#333A45',3);
  if(f.load){const cx=h?x+s*.78:x,cy=h?y:y+s*.78;box(cx-.3,cy-.3,.6,.6,3,'#A8794F',5);box(cx-.22,cy-.22,.44,.44,9,f.load.color,8);}
  const p=P(x,y,40);tag(f.code,p[0],p[1],'#8A6D0B');
}
function drawTruck(k,t){
  const {p,dx,dy}=truckAt(k,t),h=Math.abs(dx)>=Math.abs(dy),s=(h?dx:dy)>=0?1:-1,[x,y]=p,L=1.6,W=.9;
  const w=h?L:W,d=h?W:L;box(x-w/2,y-d/2,w,d,20,'#F4F5F7',0,'#C9CED6');
  const cab=k.inb?'#2F6B4F':'#1E3A5F';
  if(h)box(x+(s>0?w/2:-w/2-.7),y-.4,.7,.8,16,cab,0);else box(x-.4,y+(s>0?d/2:-d/2-.7),.8,.7,16,cab,0);
  const q=P(x,y,34);tag((k.inb?'입고 ':'출하 ')+k.code,q[0],q[1],cab);
}
function drawWorker(t,job){
  const [wx,wy]=WORKER_AT,[x,y]=P(wx,wy,0),sw=Math.sin(t/110)*5*Z; // 손 움직임
  g.fillStyle='rgba(26,26,46,.2)';g.beginPath();g.ellipse(x,y,7*Z,3.5*Z,0,0,7);g.fill();
  g.fillStyle='#333A45';g.fillRect(x-4*Z,y-10*Z,3*Z,10*Z);g.fillRect(x+1*Z,y-10*Z,3*Z,10*Z);
  g.fillStyle='#4A6FB5';g.fillRect(x-5*Z,y-22*Z,10*Z,13*Z);
  g.strokeStyle='#4A6FB5';g.lineWidth=3*Z;g.lineCap='round';g.beginPath();g.moveTo(x+5*Z,y-20*Z);g.lineTo(x+11*Z,y-14*Z+sw);g.stroke();g.beginPath();g.moveTo(x-5*Z,y-20*Z);g.lineTo(x-11*Z,y-14*Z-sw);g.stroke();g.lineCap='butt';
  g.fillStyle='#F1C9A5';g.beginPath();g.arc(x,y-26*Z,4.5*Z,0,7);g.fill();g.fillStyle='#0E7C86';g.beginPath();g.arc(x,y-28*Z,5*Z,Math.PI,0);g.fill();
  tag('검사 '+(resCode(job)||''),x,y-38*Z,'#0E7C86');
}
function drawHaul(t){
  const ents=[],job=inspecting();
  TRUCKS.forEach(k=>{const {p}=truckAt(k,t);ents.push({d:p[0]+p[1],f:()=>drawTruck(k,t)});});
  FORKS.forEach(f=>ents.push({d:f.p[0]+f.p[1],f:()=>drawLift(f)}));
  if(job)ents.push({d:WORKER_AT[0]+WORKER_AT[1],f:()=>drawWorker(t,job)});
  ents.sort((a,b)=>a.d-b.d).forEach(e=>e.f());
}

// ---- 건물 카드·간판의 "지금 하는 일" (건물마다 started 작업 1건) ----
const taskBuilding=t=>({unload:'mat',putaway:'mat',pick:'mat',feed:'mat',inspect:'qc',load:'ship'}[t.kind]);
function doText(t){
  const r=resById(t.rid),kind=r?r.kind:({unload:'dock_in',load:'dock_out',inspect:'worker'}[t.kind]||'forklift'),who=`${ROLE[kind]||''} ${resCode(t)||''}`.trim();
  const qty=(Number(t.qty)||0).toLocaleString(),c=t.to.code;
  if(t.kind==='inspect')return `${who} · ${t.product} ${qty} 검사`;
  return `${who} · ${t.product} ${qty} → ${S.shown.has(c)||/-\d\d-\d\d$/.test(c)?'칸 '+c:BNAME[t.to.b]||c}`;
}
function nowDoing(bk){let best=null;S.tasks.forEach(t=>{if(t.status==='started'&&taskBuilding(t)===bk&&(!best||t.t0>best.t0))best=t;});return best?doText(best):null;}

// 관찰용(루미 AC): 동시에 보이는 주체·움직이는 주체·화물을 실은 지게차 수
window.campusHaul={state:()=>({visible:FORKS.length+TRUCKS.length+(inspecting()?1:0),
  moving:FORKS.filter(f=>f.moving).length+TRUCKS.filter(k=>k.st!=='stand').length+(inspecting()?1:0),
  forks:FORKS.map(f=>({code:f.code,p:f.p,load:f.load&&f.load.id,moving:f.moving})),trucks:TRUCKS.map(k=>({code:k.code,st:k.st,inb:k.inb}))})};
