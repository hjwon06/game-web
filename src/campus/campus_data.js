// 단지 화면 데이터. 기계 이름·자리와 건물 크기는 그림용 배치이고, 상태·수치는 전부 서버 값이다.
// 3초마다 /api/campus 와 /api/hud 를 ETag 로 읽는다. 401 이면 /login.
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
const S={c:null,hudOk:false,err:false,note:'',lastId:null,recent:[],shipAt:[]};
const V={selM:null,selB:null,zoomedIn:false};
const HOOK={};
const nState=st=>M.filter(m=>m.st===st).length;
const dataReady=()=>!!(S.c&&S.hudOk);

const POLL_MS=3000,TIMEOUT_MS=2500,etags={};
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
function applyCampus(c,same){
  if(!c||!c.buildings||!Array.isArray(c.moves))throw new Error('/api/campus 모양이 맞지 않음');
  S.c=c;S.note=c.sim_note||'';
  if(same)return; // 304: 이미 처리한 이동
  if(S.lastId!=null)enqueueMoves(c.moves); // 첫 응답은 지난 기록이라 움직이지 않는다
  S.recent=S.recent.concat(c.moves).slice(-30);
  S.lastId=c.last_move_id;
}
let busy=false;
async function poll(){
  if(busy)return;busy=true;
  try{
    const [c,h]=await Promise.all([getJ('/api/campus'+(S.lastId!=null?'?after_id='+S.lastId:'')),getJ('/api/hud')]);
    applyHud(h.body);applyCampus(c.body,c.same);S.err=false;
  }catch(e){S.err=true;}
  finally{busy=false;if(HOOK.change)HOOK.change();}
}
function startPolling(){poll();setInterval(poll,POLL_MS);}
