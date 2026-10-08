// 단지 화면 데이터. 기계 이름·자리와 건물 크기는 그림용 배치이고, 상태·수치는 전부 서버 값이다.
// 3초마다 /api/campus?after_seq=… 와 /api/hud 를 ETag 로 읽는다(칸은 5초마다 include=bins). 401 이면 /login.
const M=[
 {id:1,code:'M1',name:'절단기',kind:'cut',x:3,row:0},
 {id:2,code:'M2',name:'조립기',kind:'asm',x:5,row:0},
 {id:3,code:'M3',name:'검사기',kind:'chk',x:7.4,row:0},
 {id:4,code:'M4',name:'가공기',kind:'mill',x:9.4,row:0},
 {id:5,code:'M5',name:'절단기 2',kind:'cut',x:11.4,row:0},
 {id:6,code:'M6',name:'가공기 2',kind:'mill',x:13.4,row:0},
 {id:7,code:'M7',name:'조립기 2',kind:'asm',x:15.4,row:0},
 {id:8,code:'M8',name:'검사기 2',kind:'chk',x:15.4,row:1},
 {id:9,code:'M9',name:'도장기 1',kind:'paint',x:13.2,row:1},
 {id:10,code:'M10',name:'도장기 2',kind:'paint',x:11,row:1},
 {id:11,code:'M11',name:'포장기 1',kind:'pack',x:7.2,row:1},
 {id:12,code:'M12',name:'포장기 2',kind:'pack',x:5,row:1},
];
const KIND={cut:{h:34,top:'#5C7FA8'},asm:{h:42,top:'#4E6E95'},chk:{h:30,top:'#3F8F98'},mill:{h:50,top:'#2F5D86'},paint:{h:38,top:'#2F7F6A'},pack:{h:30,top:'#7A8C62'}};
const STL={running:'가동',stopped:'멈춤',broken:'고장'}, STC={running:'#2F6B4F',stopped:'#6B7280',broken:'#C0392B'};
const KN={repair:'수리',start:'재가동',stop:'정지'};
const HW=19,HH=12, ROWY=[2.6,8.0], BX0=1.4,BX1=17.2;
const HALL={x:5,y:15}; // 생산동이 단지 안에 놓이는 자리
M.forEach(m=>{m.y=ROWY[m.row];m.st='stopped';m.wo=null;m.v=null;m.busy=false;}); // wo=[코드,품목,생산,목표] 또는 null

// 단지 건물: real=실데이터 장소(클릭 가능), api=/api/campus buildings 의 키
const B=[
 {id:'office',name:'수주 사무동',x:5,y:4,w:7,d:6,h:96,top:'#E9ECF1',side:'#B8C3D1',real:true,api:'office'},
 {id:'mat',name:'자재창고',x:15,y:3,w:8,d:7,h:64,top:'#E4E7EB',side:'#C9CED6',real:true,api:'material'},
 {id:'maint',name:'정비동',x:28,y:3,w:5,d:5,h:48,top:'#E4E7EB',side:'#C9CED6',real:false},
 {id:'util',name:'유틸리티',x:37,y:2,w:5,d:5,h:40,top:'#E4E7EB',side:'#C9CED6',real:false},
 {id:'qc',name:'품질검사동',x:28,y:23.5,w:6,d:6,h:58,top:'#E6EEEC',side:'#A9C4BF',real:true,api:'qc'},
 {id:'ship',name:'출하장',x:35,y:18.4,w:8,d:5.4,h:46,top:'#EBEDF0',side:'#BCC3CC',real:true,api:'shipping'},
];
const GW=46,GH=34;
// 흐름선: 사무동 → 생산동 → 품질검사동 → 출하장 → 정문
const FLOW=[[12.6,7],[14,7],[14,12.5],[3.5,12.5],[3.5,17.6],[HALL.x+1.4,17.6],[HALL.x+BX1,17.6],[HALL.x+BX1,HALL.y+8],[26.2,HALL.y+8],[26.2,26.5],[28,26.5],[26.2,26.5],[26.2,16.3],[39,16.3],[39,18.4],[39,16.3],[44.5,16.3]];

// 화면 공유 상태. S=서버에서 읽은 값, V=선택·확대, HOOK=파일 사이 연결(캠퍼스 팝업이 채운다)
// S.tasks=작업 id→정규화한 작업, S.res=자원 목록, S.off=서버시각-내시각(ms), S.bins=서버 칸 값,
// S.shown=화면에 보이는 칸 값(그 칸으로 가는 지게차가 닿은 순간에만 바뀐다), S.arrived=닿은 작업 id
const S={c:null,hudOk:false,err:false,note:'',seq:null,tasks:new Map(),res:[],off:0,offSet:false,bins:null,binsAt:0,shown:new Map(),arrived:new Set()};
const V={selM:null,selB:null,zoomedIn:false,vault:false,selBin:null};
const HOOK={};
const nState=st=>M.filter(m=>m.st===st).length;
const dataReady=()=>!!(S.c&&S.hudOk);
const srvNow=()=>Date.now()+S.off; // 서버 시계 기준 지금(ms)

// ---- 작업·자원·칸 정규화: 서버 필드 이름 몇 가지를 모두 받는다 ----
const BKEY={material:'mat',mat:'mat',warehouse:'mat',production:'prod',prod:'prod',hall:'prod',qc:'qc',shipping:'ship',ship:'ship',office:'office',gate:'gate'};
const BPREFIX=[[/^(RAW|RECV|REC|MAT|DOCK-?IN|IN)\b/i,'mat'],[/^(PROD|WIP|LINE|MFG)/i,'prod'],[/^(QC|INSP)/i,'qc'],[/^(FG|SHIP|DOCK-?OUT|OUT)/i,'ship'],[/^(SUP|CUST|GATE|ROAD)/i,'gate']];
function bKeyOf(code,b){const k=b&&BKEY[String(b).toLowerCase()];if(k)return k;const hit=BPREFIX.find(([re])=>re.test(code||''));return hit?hit[1]:null;}
const tsOf=v=>{if(!v)return null;const s=String(v),ms=Date.parse(/(Z|[+-]\d\d:?\d\d)$/.test(s)?s:s+'Z');return isNaN(ms)?null:ms;};
const PAL=['#C9A227','#0E7C86','#B5532D','#6A7FC1','#7A8C62','#A0577C','#4E8F5F','#8B6F47'];
function itemColor(key){let h=0;String(key||'').split('').forEach(c=>{h=(h*31+c.charCodeAt(0))>>>0;});return PAL[h%PAL.length];}
function sideOf(t,k){const o=t[k]||t[k+'_location']||{};const code=t[k+'_code']||o.code||'';return{code,b:bKeyOf(code,t[k+'_building']||o.building)};}
function normTask(t){
  const pr=t.product,pn=typeof pr==='string'?pr:(pr&&pr.name)||t.product_name||'',pc=(pr&&pr.code)||t.product_code||pn;
  return{id:t.id,seq:t.seq,kind:t.kind,status:t.status==='finished'?'done':t.status,rid:t.resource_id==null?(t.resource&&t.resource.id):t.resource_id,
    rcode:t.resource_code||(t.resource&&t.resource.code)||null,product:pn,color:t.product_color||itemColor(pc),qty:Number(t.qty),
    from:sideOf(t,'from'),to:sideOf(t,'to'),planned:tsOf(t.planned_at),t0:tsOf(t.started_at),t1:tsOf(t.expected_finish_at),tf:tsOf(t.finished_at)};
}
const resById=id=>S.res.find(r=>r.id===id);
const resCode=t=>t.rcode||(resById(t.rid)||{}).code||null;
// 칸 표시 동기화: 그 칸에 걸린 putaway·feed·pick 이 아직 지게차에 닿지 않았으면 옛 값을 붙든다
const pendingBin=code=>{for(const t of S.tasks.values())if(['putaway','feed','pick'].includes(t.kind)&&(t.from.code===code||t.to.code===code)&&(t.status==='started'||(t.status==='done'&&!S.arrived.has(t.id))))return true;return false;};
function syncBins(){if(!S.bins)return;S.bins.forEach(b=>{if(S.shown.has(b.code)&&pendingBin(b.code))return;
  const p=b.product,pn=typeof p==='string'?p:(p&&p.name)||b.product_name||'';
  S.shown.set(b.code,{product:pn,qty:Number(b.qty)||0,cap:Number(b.capacity==null?b.capacity_units:b.capacity)||0,color:itemColor((p&&p.code)||b.product_code||pn)});});}
function arrive(t){S.arrived.add(t.id);syncBins();}

const POLL_MS=3000,TIMEOUT_MS=2500,BINS_MS=5000,etags={};
async function getJ(url){
  const path=url.split('?')[0],hit=etags[path],h={Accept:'application/json'};
  if(hit&&hit.url===url)h['If-None-Match']=hit.tag;
  const ctrl=new AbortController(),to=setTimeout(()=>ctrl.abort(),TIMEOUT_MS);
  try{
    const r=await fetch(url,{headers:h,cache:'no-store',signal:ctrl.signal});
    if(r.status===401){location.href='/login';throw new Error('HTTP 401');}
    if(r.status===304&&hit&&hit.url===url)return{body:hit.body,same:true};
    if(!r.ok)throw new Error('HTTP '+r.status);
    const body=await r.json(),tag=r.headers.get('ETag');
    if(tag)etags[path]={url,tag,body};else delete etags[path];
    return{body,same:false};
  }finally{clearTimeout(to);}
}
function applyHud(hud){
  if(!hud||!Array.isArray(hud.machines))throw new Error('/api/hud 모양이 맞지 않음');
  const by=new Map(hud.machines.map(x=>[x.code,x]));
  M.forEach(m=>{const s=by.get(m.code);if(!s)return;const w=s.work_order,old=m.wo;
    m.st=s.state;m.wo=w?[w.code,w.product,w.produced_qty,w.target_qty]:null;
    if(V.zoomedIn&&old&&w&&old[0]===w.code&&w.produced_qty>old[2])bubble(m,`+${w.produced_qty-old[2]} ${w.product}`,'#2F6B4F');});
  S.hudOk=true;
}
function applyCampus(c,same,withBins){
  if(!c||!c.buildings)throw new Error('/api/campus 모양이 맞지 않음');
  S.c=c;S.note=c.sim_note||'';
  if(same)return; // 304: 이미 처리한 응답
  const hm=c.buildings.hall&&c.buildings.hall.machines; // 자재 대기: 기계 상태와 별개 표시(m.short = 대기 시작 시각 ms 또는 null)
  if(Array.isArray(hm)){const by=new Map(hm.map(x=>[x.code,x]));M.forEach(m=>{const h=by.get(m.code);m.short=h&&h.material_short?tsOf(h.since):null;});}
  const st=tsOf(c.server_time),o=st==null?null:st-Date.now(); // 서버 시각 오프셋(급변은 완만히)
  if(o!=null){S.off=S.offSet?S.off*.7+o*.3:o;S.offSet=true;}
  if(Array.isArray(c.resources))S.res=c.resources;
  (c.tasks||[]).forEach(t=>{S.tasks.set(t.id,normTask(t));if(typeof t.seq==='number')S.seq=Math.max(S.seq==null?0:S.seq,t.seq);});
  if(typeof c.last_seq==='number')S.seq=Math.max(S.seq==null?0:S.seq,c.last_seq); // 단조 증가만
  // 서버(④)는 bins 를 {raw:[…], fg:[…]} 로 준다. 배열로 펴서 쓴다(배열로 와도 그대로).
  const bins=Array.isArray(c.bins)?c.bins:(c.bins&&typeof c.bins==='object'?[].concat(c.bins.raw||[],c.bins.fg||[]):null);
  if(withBins&&bins){S.bins=bins;S.binsAt=Date.now();}
  syncBins();
}
let busy=false;
async function poll(){
  if(busy)return;busy=true;
  try{
    const wantBins=Date.now()-S.binsAt>=BINS_MS-300,q=[];
    if(S.seq!=null)q.push('after_seq='+S.seq);
    if(wantBins)q.push('include=bins');
    const [c,h]=await Promise.all([getJ('/api/campus'+(q.length?'?'+q.join('&'):'')),getJ('/api/hud')]);
    applyHud(h.body);applyCampus(c.body,c.same,wantBins);S.err=false;
  }catch(e){S.err=true;}
  finally{busy=false;if(HOOK.change)HOOK.change();}
}
function startPolling(){poll();setInterval(poll,POLL_MS);}
