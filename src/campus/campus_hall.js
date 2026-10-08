// 생산동 안쪽: 설비·작업자·지게차·벨트·말풍선. 설비 상태와 작업지시는 /api/hud 값(M)이다.
const workers=[{x:6,y:5.3,tx:6,ty:5.3,c:'#C9A227',job:null},{x:12,y:5.2,tx:12,ty:5.2,c:'#2563EB',job:null},{x:9,y:10.4,tx:9,ty:10.4,c:'#C9A227',job:null},{x:3,y:4.8,tx:3,ty:4.8,c:'#0E7C86',job:null}];
const bubbles=[];
function bubble(m,text,color,shake){bubbles.push({m,text,color,t0:performance.now(),shake});}
const loop=[[BX0,ROWY[0]],[BX1,ROWY[0]],[BX1,ROWY[1]],[BX0,ROWY[1]]];
const woPct=m=>m.wo&&m.wo[3]>0?Math.min(1,m.wo[2]/m.wo[3]):0;
function drawHall(t){
  box(-.2,-.2,HW+.4,HH+.4,6,'#F4F5F7',0,'#C9CED6');
  for(let y=0;y<HH;y++)for(let x=0;x<HW;x++)poly([P(x,y,6),P(x+1,y,6),P(x+1,y+1,6),P(x,y+1,6)],(x+y)%2?'#ECEFF3':'#E8EBF0');
  [[1,1.2,5.4,2.9,'#DCE3EC','입고'],[6.4,1.2,11.6,2.9,'#D3DCE7','가공'],[9.6,6.6,8.4,2.9,'#D4E3E1','검사 · 도장'],[1,6.6,8.6,2.9,'#DDE5D6','포장']].forEach(([x,y,w,d,c])=>{poly([P(x,y,6),P(x+w,y,6),P(x+w,y+d,6),P(x,y+d,6)],c);});
  const WH=120;
  poly([P(0,0,6),P(HW,0,6),P(HW,0,WH),P(0,0,WH)],'#C9D0D9');poly([P(0,0,6),P(0,HH,6),P(0,HH,WH),P(0,0,WH)],'#B9C1CC');
  poly([P(0,0,WH),P(HW,0,WH),P(HW,-.3,WH+2),P(-.3,-.3,WH+2),P(-.3,HH,WH+2),P(0,HH,WH)],'#A9B2BE');
  for(let x=13.2;x<18.5;x+=2.3)poly([P(x,0,104),P(x+1.8,0,104),P(x+1.8,0,74),P(x,0,74)],'#A9C3DD');
  // 벽 현황판·전광판
  const run=nState('running'),bad=nState('broken'),act=M.filter(m=>m.wo).length;
  onWallX0(11.2,108,()=>{g.fillStyle='#1A1A2E';g.fillRect(0,0,200,82);g.fillStyle='#8FA3BF';g.font='700 10px Pretendard';g.fillText('LINE A 지금 가동',12,18);g.fillStyle='#fff';g.font='800 44px Outfit';g.fillText(String(run),10,62);const w=g.measureText(String(run)).width;g.fillStyle='#6B7A90';g.font='600 18px Outfit';g.fillText('/'+M.length,14+w,62);g.fillStyle='#E5483A';g.font='700 11px Pretendard';g.fillText(`고장 ${bad}`,130,40);M.forEach((m,i)=>{g.fillStyle=m.st==='running'?'#3FAE6A':m.st==='broken'?'#E5483A':'#5B6475';g.fillRect(12+i*15,70,11,5);});});
  onWallY0(2.2,110,()=>{g.fillStyle='#1A1A2E';g.fillRect(0,0,320,90);g.fillStyle='#8FA3BF';g.font='700 10px Pretendard';g.fillText(`작업지시 · 진행 ${act}`,12,18);
    M.filter(m=>m.wo).slice(0,4).forEach((m,i)=>{const y=36+i*14,p=woPct(m);g.font='600 10px Outfit';g.fillStyle='#C9D3E0';g.fillText(m.wo[0],12,y);g.font='600 10px Pretendard';g.fillText(`${m.code} ${m.wo[1]}`,70,y);g.fillStyle='#333A45';g.fillRect(160,y-7,110,6);g.fillStyle=m.st==='broken'?'#E5483A':'#3FAE6A';g.fillRect(160,y-7,110*p,6);g.fillStyle='#fff';g.fillText((p*100).toFixed(1)+'%',276,y);});});
  // 벨트
  for(let i=0;i<3;i++){const a=loop[i],b=loop[i+1];const x0=Math.min(a[0],b[0])-.34,x1=Math.max(a[0],b[0])+.34,y0=Math.min(a[1],b[1])-.34,y1=Math.max(a[1],b[1])+.34;box(x0,y0,x1-x0,y1-y0,5,'#7C8796',6);}
  const r=run/M.length;for(let i=0;i<30;i++){const u=(i/30+(t/50000)*r)%1;const [x,y]=beltAt(u);box(x-.1,y-.1,.2,.2,8,['#C9A227','#D7DCE3','#8B5E3C'][i%3],11);}
  for(let i=0;i<3;i++)box(2+i*1.05,10.4,.85,.85,10+((i*7)%3)*6,'#A8794F',6); // 팔레트
  const ents=[];M.forEach(m=>ents.push({d:m.x+m.y,f:()=>drawMachine(m,t)}));workers.forEach(w=>{if(V.zoomedIn||w.job)ents.push({d:w.x+w.y,f:()=>person(w,t)});}); // 단지 전체 화면에선 수리 중인 사람만(운반 주체 수 상한)
  ents.sort((a,b)=>a.d-b.d).forEach(e=>e.f());
}
function beltAt(u){let L=0;const s=[];for(let i=0;i<3;i++){const a=loop[i],b=loop[i+1],l=Math.hypot(b[0]-a[0],b[1]-a[1]);s.push([a,b,l]);L+=l;}let d=u*L;for(const [a,b,l] of s){if(d<=l)return[a[0]+(b[0]-a[0])*d/l,a[1]+(b[1]-a[1])*d/l];d-=l;}return loop[3];}
function drawMachine(m,t){
  const k=KIND[m.kind],bx=m.x-.44,by=m.y-.44,F=6,H=F+12+k.h;
  const top=m.st==='running'?k.top:m.st==='broken'?'#8E949D':'#A3A9B2';const bob=m.st==='running'?Math.sin(t/220+m.id)*1.6:0;
  box(bx-.05,by-.05,.98,.98,7,'#5F6A78',F+5);box(bx,by,.88,.88,k.h,top,F+12);
  const cx=bx+.44,cy=by+.44;
  if(m.kind==='mill')box(cx-.19,cy-.19,.38,.38,11+bob,shade(top,1.15),H);
  if(m.kind==='cut')box(bx+.1,cy-.06,.68,.12,6,shade(top,1.25),H);
  if(m.kind==='paint')box(cx-.1,cy-.1,.2,.2,24,shade(top,.9),H);
  if(m.kind==='asm'){box(bx+.08,by+.08,.32,.32,8+bob,shade(top,1.18),H);box(bx+.48,by+.48,.32,.32,8-bob,shade(top,1.18),H);}
  if(m.kind==='chk'){const c=P(cx,cy,H+4);g.fillStyle=shade(top,1.3);g.beginPath();g.ellipse(c[0],c[1],13*Z,6.5*Z,0,0,7);g.fill();}
  if(m.kind==='pack')box(bx+.12,by+.12,.64,.64,6,'#B89A6E',H);
  if(m.st==='broken')for(let i=0;i<5;i++){const ph=((t/1500)+i/5)%1,p=P(cx,cy,H+22+ph*70);g.fillStyle=`rgba(80,86,98,${.38*(1-ph)})`;g.beginPath();g.arc(p[0]+Math.sin(ph*6+i)*7*Z,p[1],(6+ph*13)*Z,0,7);g.fill();}
  m._top=P(cx,cy,H+(m.kind==='paint'?24:12));m._base=P(cx,cy,F+12);
  if(V.selM===m.id)poly([P(bx-.2,by-.2,F),P(bx+1.08,by-.2,F),P(bx+1.08,by+1.08,F),P(bx-.2,by+1.08,F)],null,'#1A1A2E',2.5*Z);
}
function drawTag(m){
  const [x,y0]=m._top;const y=y0-22*Z;const p=woPct(m);
  g.font=`800 ${11*Z}px Outfit`;const W=Math.max(g.measureText(m.code).width+16*Z,48*Z);
  g.fillStyle=m.st==='broken'?'#C0392B':'#1A1A2E';g.fillRect(x-W/2,y-9*Z,W,17*Z);g.fillStyle='#fff';g.textAlign='center';g.fillText(m.code,x,y+3.5*Z);g.textAlign='left';
  g.fillStyle='rgba(26,26,46,.18)';g.fillRect(x-W/2,y+9*Z,W,4*Z);g.fillStyle=STC[m.st];g.fillRect(x-W/2,y+9*Z,W*p,4*Z);
}
function brokenMark(m,t){const [x,y0]=m._top;const s=Math.max(Z,.6);const b=Math.sin(t/170)*3*s;g.fillStyle='#C0392B';g.beginPath();g.arc(x,y0-46*Z+b,10*s,0,7);g.fill();g.fillStyle='#fff';g.font=`900 ${14*s}px Outfit`;g.textAlign='center';g.fillText('!',x,y0-41*Z+b);g.textAlign='left';}
function person(w,t){const [x,y]=P(w.x,w.y,6);const walk=w.moving?Math.sin(t/90)*2*Z:0;
  g.fillStyle='rgba(26,26,46,.2)';g.beginPath();g.ellipse(x,y,7*Z,3.5*Z,0,0,7);g.fill();g.fillStyle='#333A45';g.fillRect(x-4*Z,y-10*Z+walk*.3,3*Z,10*Z);g.fillRect(x+1*Z,y-10*Z-walk*.3,3*Z,10*Z);
  g.fillStyle='#4A6FB5';g.fillRect(x-5*Z,y-22*Z,10*Z,13*Z);g.fillStyle='#F1C9A5';g.beginPath();g.arc(x,y-26*Z,4.5*Z,0,7);g.fill();g.fillStyle=w.c;g.beginPath();g.arc(x,y-28*Z,5*Z,Math.PI,0);g.fill();
  if(w.job&&w.job.phase==='fix'){g.fillStyle='#FFE45C';for(let i=0;i<3;i++)g.fillRect(x+6*Z+Math.random()*8*Z,y-24*Z+Math.random()*10*Z,3*Z,3*Z);}}
function drawBubbles(t){for(let i=bubbles.length-1;i>=0;i--){const b=bubbles[i],age=(t-b.t0)/2600;if(age>1){bubbles.splice(i,1);continue;}if(!b.m._top)continue;
  const [x,y]=b.m._top;const s=Math.max(Z,.7);const yy=y-62*Z-age*28*s;const sx=b.shake&&age<.3?Math.sin(age*90)*4*s:0;
  g.globalAlpha=age<.1?age*10:age>.75?(1-age)*4:1;g.font=`700 ${11*s}px Pretendard`;const w=g.measureText(b.text).width+16*s;
  g.fillStyle='#fff';g.fillRect(x-w/2+sx,yy-12*s,w,20*s);g.fillStyle=b.color;g.fillRect(x-w/2+sx,yy-12*s,3*s,20*s);g.fillStyle='#1A1A2E';g.textAlign='center';g.fillText(b.text,x+sx+2*s,yy+2*s);g.textAlign='left';g.globalAlpha=1;}}
// 작업자·지게차 움직임. 수리 작업이 끝나면 HOOK.repaired 로 서버에 수리 명령을 보낸다.
function updateHall(dt,t){
  workers.forEach((w,i)=>{if(w.job){const m=w.job.m;w.tx=m.x;w.ty=m.row===0?m.y+1.05:m.y-1.05;}
    const dx=w.tx-w.x,dy=w.ty-w.y,d=Math.hypot(dx,dy);w.moving=d>.05;
    if(w.moving){const s=Math.min(d,dt*1.6);w.x+=dx/d*s;w.y+=dy/d*s;}
    else if(w.job){if(w.job.phase==='walk'){w.job.phase='fix';w.job.until=t+1600;}else if(t>w.job.until){const m=w.job.m;w.job=null;if(HOOK.repaired)HOOK.repaired(m);}}
    else if(Math.random()<dt*.35){w.tx=2.5+Math.random()*14;w.ty=i===2?9.9+Math.random()*.9:4.6+Math.random()*1.5;}});
}
