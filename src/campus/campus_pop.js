// 카드·조작·화면 루프. 건물 카드는 /api/campus 값, 설비 조작은 기존 POST /api/commands(src/commands.js 재사용).
import { sendCommand } from '../commands.js';
import { refreshNow, getState } from '../state.js';

let camT=null,last=performance.now();
const popEl=document.getElementById('pop');
const esc=s=>String(s==null?'':s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const row=(a,b)=>`<div class="row"><span>${esc(a)}</span><b>${esc(b)}</b></div>`;
const fmt=n=>Number(n).toLocaleString();
const clock=iso=>new Date(iso).toLocaleTimeString('ko-KR',{hour12:false});

// ===================== 갱신 =====================
function update(dt,t){
  updateHall(dt,t);tickFlow(t);
  if(camT){const k=Math.min(1,dt*4);Z+=(camT.z-Z)*k;
    const sx=off.x+(camT.wx-camT.wy)*TW/2*Z, sy=off.y+(camT.wx+camT.wy)*TH/2*Z;off.x+=(camT.sx-sx)*k;off.y+=(camT.sy-sy)*k;
    if(Math.abs(camT.z-Z)<.002)camT=null;}
}
function draw(t){
  const dt=Math.min(.05,(t-last)/1000);last=t;update(dt,t);
  g.setTransform(1,0,0,1,0,0);g.fillStyle='#D9E2D5';g.fillRect(0,0,cv.width,cv.height);g.setTransform(DPR,0,0,DPR,0,0);
  drawGround();drawTrees();drawFlow();
  const ents=B.map(b=>({d:b.x+b.w/2+b.y+b.d/2,f:()=>building(b,t)}));
  ents.push({d:HALL.x+HALL.y+10,f:()=>inHall(()=>drawHall(t))});
  ents.push({d:38+25.5,f:trucksAtDock});
  ents.sort((a,b)=>a.d-b.d).forEach(e=>e.f());
  drawScrap();drawInTrucks(t);drawCargo(t);
  inHall(()=>{if(Z>.75)M.forEach(m=>drawTag(m));M.filter(m=>m.st==='broken').forEach(m=>brokenMark(m,t));drawBubbles(t);});
  B.forEach(b=>sign(b));hallSign();
  if(Z<.75)floorText();
  placePop();requestAnimationFrame(draw);
}

// ===================== 설비 조작 =====================
async function send(m,k){
  m.busy=true;m.err=false;renderPop();
  try{
    await refreshNow(); // 서버 행 버전을 최신으로 (base_version)
    const st=getState(),sm=st&&st.machines.find(x=>x.id===m.code);
    if(!sm){bubble(m,'서버 버전을 읽지 못함 · 다시 시도','#C0392B',true);return;}
    const before=sm.version;m.v=before;
    const r=await sendCommand({id:m.code,version:before},k);
    if(r.status===401){location.href='/login';return;}
    if(r.machine)m.v=r.machine.version;
    if(r.status===200)bubble(m,`${KN[k]} 반영 · v${before}→v${m.v} · 200`,STC[(r.machine&&r.machine.state)||m.st]);
    else if(r.status===409)bubble(m,`${KN[k]} 거절 · 409 버전 충돌${r.machine?` (이미 v${r.machine.version})`:''}`,'#C0392B',true);
    else if(r.status===0)bubble(m,`${KN[k]} 실패 · 서버에 닿지 않음`,'#C0392B',true);
    else bubble(m,`${KN[k]} 거절 · ${r.status}`,'#C0392B',true);
  }catch(e){m.err=true;bubble(m,'연결 실패 — 상태를 다시 읽는 중','#C0392B',true);}
  finally{m.busy=false;renderPop();poll().then(()=>{if(!S.err)m.err=false;renderPop();});} // /api/hud 를 다시 읽어 카드를 맞춘다
}
function command(m,k){
  const ok={repair:'broken',start:'stopped',stop:'running'}[k];if(m.st!==ok||m.busy||workers.some(w=>w.job&&w.job.m===m))return;
  if(k==='repair'){const w=workers.filter(w=>!w.job).sort((a,b)=>Math.hypot(a.x-m.x,a.y-m.y)-Math.hypot(b.x-m.x,b.y-m.y))[0];
    if(w){w.job={m,phase:'walk'};bubble(m,'수리 요청 접수 · 작업자 이동 중','#1E3A5F');renderPop();return;}}
  send(m,k);
}
HOOK.repaired=m=>send(m,'repair'); // 작업자가 도착해 손본 뒤에 서버로 보낸다
HOOK.change=()=>renderPop();
async function loadVersion(m){
  try{await refreshNow();const st=getState(),sm=st&&st.machines.find(x=>x.id===m.code);if(sm&&m.v!==sm.version){m.v=sm.version;renderPop();}}
  catch(e){m.err=true;renderPop();}
  finally{poll().then(()=>{if(!S.err)m.err=false;renderPop();});}
}

// ===================== 입력 =====================
let drag=null;
cv.addEventListener('mousedown',e=>{drag={x:e.clientX,y:e.clientY,ox:off.x,oy:off.y,moved:false};cv.classList.add('drag');});
addEventListener('mouseup',e=>{cv.classList.remove('drag');if(drag&&!drag.moved&&e.target===cv)click(e.clientX,e.clientY);drag=null;});
addEventListener('mousemove',e=>{if(!drag)return;const dx=e.clientX-drag.x,dy=e.clientY-drag.y;if(Math.abs(dx)+Math.abs(dy)>4){drag.moved=true;camT=null;}off.x=drag.ox+dx;off.y=drag.oy+dy;});
cv.addEventListener('wheel',e=>{e.preventDefault();camT=null;const nz=Math.max(fitCampus()*.9,Math.min(2.4,Z*(e.deltaY<0?1.1:.9)));off.x=e.clientX-(e.clientX-off.x)*nz/Z;off.y=e.clientY-(e.clientY-off.y)*nz/Z;Z=nz;V.zoomedIn=Z>.75;},{passive:false});
addEventListener('keydown',e=>{if(e.key==='Escape')zoomOut();});
function toScreenTarget(wx,wy,z){camT={wx,wy,z,sx:innerWidth/2,sy:innerHeight/2+40};}
function zoomIn(){V.selB=null;renderPop();V.zoomedIn=true;toScreenTarget(HALL.x+HW/2,HALL.y+HH/2,Math.min(innerWidth*.9/((HW+HH)*TW/2),innerHeight*.8/((HW+HH)*TH/2+120)));}
function zoomOut(){V.selM=null;V.selB=null;renderPop();V.zoomedIn=false;toScreenTarget(GW/2,GH/2,fitCampus());}
function inside(px,py,poly4){let c=false;for(let i=0,j=3;i<4;j=i++){const a=poly4[i],b=poly4[j];if(((a[1]>py)!==(b[1]>py))&&(px<(b[0]-a[0])*(py-a[1])/(b[1]-a[1])+a[0]))c=!c;}return c;}
function click(x,y){
  if(V.zoomedIn){let best=null,bd=1e9;M.forEach(m=>{if(!m._top)return;const cy=(m._top[1]+m._base[1])/2;const d=Math.hypot(x-m._top[0],y-cy);if(d<38*Z&&d<bd){bd=d;best=m;}});
    if(best){V.selM=best.id;V.selB=null;renderPop();loadVersion(best);return;}
    const hp=[P(HALL.x,HALL.y),P(HALL.x+HW,HALL.y),P(HALL.x+HW,HALL.y+HH),P(HALL.x,HALL.y+HH)];if(!inside(x,y,hp)){zoomOut();return;}V.selM=null;renderPop();return;}
  const hp=[P(HALL.x,HALL.y,-20),P(HALL.x+HW,HALL.y,-20),P(HALL.x+HW,HALL.y+HH,0),P(HALL.x,HALL.y+HH,0)].map((p,i)=>i<2?[p[0],p[1]-120*Z]:p);
  if(inside(x,y,hp)){zoomIn();return;}
  const b=B.find(b=>b.real&&Math.hypot(x-b._c[0],y-b._c[1])<Math.max(b.w,b.d)*TW/3*Z);V.selB=b?b.id:null;V.selM=null;renderPop();
}

// ===================== 카드 =====================
function buildingCard(b){
  const d=S.c&&S.c.buildings[b.api];let rows='';
  if(!d)rows='<div class="note">불러오는 중</div>';
  else if(b.id==='office'){rows=row('대기 수주',d.orders.open)+row('부분 출하',d.orders.partial)+row('완료',d.orders.done)
    +d.recent.map(o=>row(`${o.so_no} · ${o.customer}`,o.status)).join('');}
  else if(b.id==='mat'){const n=d.received_trucks_10m; // 트럭 표시는 이 값 하나에서만 만든다(이동 기록과 섞지 않음)
    rows=d.raw_store.map(r=>row(`${r.name}`,fmt(r.qty))).join('')+row('입고대',fmt(d.receiving_qty))+row('10분 입고 트럭',`${n}대`)
      +row('최근 트럭',n>0?`10분 안에 ${n}대 입고`:'없음');}
  else if(b.id==='qc'){const r=d.defect_ratio_60m;rows=row('검사 대기',fmt(d.qty))+row('양품 (60분)',fmt(d.pass_60m))+row('불량 (60분)',fmt(d.fail_60m))+row('불량률',r==null?'-':(r*100).toFixed(2)+'%');}
  else if(b.id==='ship'){rows=d.fg_store.map(r=>row(`${r.name}`,fmt(r.qty))).join('')+row('출하 (60분)',fmt(d.shipped_60m))+row('부분 출하 수주',d.partial_orders);}
  return `<div class="hd"><span class="c">${esc(b.name)}</span><span class="tag">실데이터</span></div>${rows}<div class="note">${esc(S.note)}</div>`;
}
function machineCard(m){
  const working=workers.some(w=>w.job&&w.job.m===m),p=woPct(m);
  const prim=m.st==='broken'?'repair':m.st==='stopped'?'start':'stop',lock=working||m.busy;
  return `<div class="hd"><span class="c">${m.code} ${m.name}</span><span class="tag" style="color:${STC[m.st]}">${working?'수리 중':STL[m.st]}</span></div>
     ${m.wo?row(`${m.wo[0]} · ${m.wo[1]}`,(p*100).toFixed(1)+'%'):row('작업지시','없음')}${row('행 버전',m.v==null?'-':'v'+m.v)}
     <div class="btns">${['repair','start','stop'].map(k=>`<button class="${prim===k?'pri':''}" data-k="${k}" ${prim!==k||lock?'disabled':''}>${KN[k]}</button>`).join('')}</div>${m.err?'<div class="note">연결 실패 — 상태를 다시 읽는 중</div>':''}`;
}
function renderPop(){
  let html=null,m=null;
  if(V.selM){m=M.find(x=>x.id===V.selM);html=machineCard(m);}
  else if(V.selB)html=buildingCard(B.find(x=>x.id===V.selB));
  if(html==null){popEl.classList.add('hide');popEl._h=null;return;}
  if(popEl._h!==html){popEl.innerHTML=html;popEl._h=html;if(m)popEl.querySelectorAll('button').forEach(b=>b.onclick=()=>command(m,b.dataset.k));} // 내용이 같으면 다시 그리지 않아 클릭이 끊기지 않는다
  popEl.classList.remove('hide');
}
function placePop(){let p=null;
  if(V.selM){const m=M.find(x=>x.id===V.selM);p=m._top?[m._top[0]+34*Z,m._top[1]-34*Z]:null;}
  if(V.selB){const b=B.find(x=>x.id===V.selB);p=b._sign?[b._sign[0]+30,b._sign[1]-20]:null;}
  if(p){popEl.style.left=Math.min(innerWidth-264,p[0])+'px';popEl.style.top=Math.max(10,Math.min(innerHeight-200,p[1]))+'px';}}

startPolling();
requestAnimationFrame(draw);
