// 단지 그리기: 투영·바닥·도로·건물·간판. 숫자는 S(서버 값)에서 읽는다.
const cv=document.getElementById('c'),g=cv.getContext('2d');
let DPR=1,Z=1,off={x:0,y:0},O={x:0,y:0};const TW=64,TH=32,U=36;
function fitCampus(){return Math.min(innerWidth*.98/((GW+GH)*TW/2),innerHeight*.96/((GW+GH)*TH/2+40));}
function resize(){DPR=Math.min(2,devicePixelRatio||1);cv.width=innerWidth*DPR;cv.height=innerHeight*DPR;cv.style.width=innerWidth+'px';cv.style.height=innerHeight+'px';
  Z=fitCampus();off.x=innerWidth/2-(GW/2-GH/2)*TW/2*Z;off.y=innerHeight/2-(GW/2+GH/2)*TH/2*Z+18*Z;}
addEventListener('resize',resize);resize();
const P=(x,y,h=0)=>[off.x+((x+O.x)-(y+O.y))*TW/2*Z, off.y+((x+O.x)+(y+O.y))*TH/2*Z-h*Z];
function poly(pts,fill,stroke,lw){g.beginPath();pts.forEach((p,i)=>i?g.lineTo(p[0],p[1]):g.moveTo(p[0],p[1]));g.closePath();if(fill){g.fillStyle=fill;g.fill();}if(stroke){g.strokeStyle=stroke;g.lineWidth=lw||1;g.stroke();}}
function shade(hex,k){const n=parseInt(hex.slice(1),16);const f=v=>Math.min(255,Math.round(v*k));return `rgb(${f(n>>16)},${f(n>>8&255)},${f(n&255)})`;}
function box(x,y,w,d,h,top,z=0,side){const b=[P(x,y,z),P(x+w,y,z),P(x+w,y+d,z),P(x,y+d,z)],t=[P(x,y,z+h),P(x+w,y,z+h),P(x+w,y+d,z+h),P(x,y+d,z+h)];
  poly([b[1],b[2],t[2],t[1]],side?shade(side,1):shade(top,.8));poly([b[3],b[2],t[2],t[3]],side?shade(side,.82):shade(top,.64));poly(t,top);return t;}
function plane(x,y,w,d,c){poly([P(x,y),P(x+w,y),P(x+w,y+d),P(x,y+d)],c);}
function onFloor(x,y,fn){const o=P(x,y);g.save();g.setTransform(DPR*32*Z/U,DPR*16*Z/U,DPR*-32*Z/U,DPR*16*Z/U,DPR*o[0],DPR*o[1]);fn();g.restore();}
function onWallY0(x,h,fn){const o=P(x,0,h);g.save();g.setTransform(DPR*32*Z/U,DPR*16*Z/U,0,DPR*Z,DPR*o[0],DPR*o[1]);fn();g.restore();}
function onWallX0(y,h,fn){const o=P(0,y,h);g.save();g.setTransform(DPR*32*Z/U,DPR*-16*Z/U,0,DPR*Z,DPR*o[0],DPR*o[1]);fn();g.restore();}
function inHall(fn){const s={...O};O.x=HALL.x;O.y=HALL.y;fn();O.x=s.x;O.y=s.y;}

// 단지 밖: 들판·외곽도로·숲 (화면 끝까지 채운다)
const OUT=[];(function(){let s=7;const r=()=>{s=(s*9301+49297)%233280;return s/233280;};
  for(let i=0;i<260;i++){const x=-22+r()*(GW+44),y=-22+r()*(GH+44);if(x>-4&&x<GW+4&&y>-4&&y<GH+4)continue;OUT.push([x,y,r()]);}})();
function drawOutside(){
  for(let i=-22;i<GW+22;i+=4)for(let j=-22;j<GH+22;j+=4){if(i>-5&&i<GW+4&&j>-5&&j<GH+4)continue;plane(i,j,3.8,3.8,((i+j)/4)%2?'#D6E0D3':'#DCE4D8');}
  plane(-3.2,-3.2,GW+6.4,1.6,'#C5CBD2');plane(-3.2,GH+1.6,GW+6.4,1.6,'#C5CBD2');plane(-3.2,-3.2,1.6,GH+6.4,'#C5CBD2');plane(GW+1.6,-3.2,1.6,GH+6.4,'#C5CBD2');
  plane(GW+1.6,15.2,22,2.2,'#BFC5CD');
  g.setLineDash([6*Z,7*Z]);g.strokeStyle='rgba(255,255,255,.8)';g.lineWidth=1.2*Z;g.beginPath();g.moveTo(...P(GW+2.4,16.3));g.lineTo(...P(GW+22,16.3));g.stroke();g.setLineDash([]);
}
function drawTrees(){OUT.forEach(([x,y,r])=>{if(r<.55)tree(x,y);});}
function drawGround(){
  drawOutside();
  box(-.5,-.5,GW+1,GH+1,18,'#E6EAE5',-18,'#C9CFC8');
  plane(0,0,GW,GH,'#E1E6E0');
  plane(1,1,42,31,'#E9ECEF'); // 포장 마당
  const road=(x,y,w,d)=>{plane(x,y,w,d,'#CDD2D9');};
  road(2.6,11.6,40,1.8);road(2.6,1.2,1.8,29);road(13.2,1.2,1.6,12);road(25.4,1.2,1.6,29);road(26,15.4,18.5,1.8);road(2.6,29,24,1.6);
  g.setLineDash([6*Z,7*Z]);[[ [3.5,12.5],[42,12.5] ],[ [26.2,2],[26.2,30] ],[ [26,16.3],[44,16.3] ]].forEach(([a,b])=>{g.strokeStyle='rgba(255,255,255,.8)';g.lineWidth=1.2*Z;g.beginPath();g.moveTo(...P(...a));g.lineTo(...P(...b));g.stroke();});g.setLineDash([]);
  for(let i=0;i<6;i++){const x=5.2+i*1.1;g.strokeStyle='rgba(255,255,255,.9)';g.lineWidth=1*Z;g.beginPath();g.moveTo(...P(x,10.2));g.lineTo(...P(x,11.4));g.stroke();if(i<5&&i!==2)box(x+.18,10.35,.74,.95,10,['#1E3A5F','#6B7280','#E5E7EB','#2F6B4F','#333A45'][i],0);}
  box(42.6,14.6,1.2,1,30,'#F4F5F7',0,'#C9CED6');poly([P(44,15.4,22),P(44,17.2,22),P(44,17.2,24),P(44,15.4,24)],'#1A1A2E'); // 정문 + 경비실
  g.strokeStyle='#B5BDB4';g.lineWidth=1.2*Z;g.beginPath();g.moveTo(...P(.4,.4,10));g.lineTo(...P(GW-.4,.4,10));g.lineTo(...P(GW-.4,14.8,10));g.moveTo(...P(GW-.4,17.6,10));g.lineTo(...P(GW-.4,GH-.4,10));g.lineTo(...P(.4,GH-.4,10));g.lineTo(...P(.4,.4,10));g.stroke();
  [[1,33],[4,33],[8,33],[12,33],[18,33],[22,33],[30,33],[34,33],[38,33],[42,33],[45,30],[45,26],[45,22],[45,8],[45,4]].forEach(([x,y])=>tree(x,y));
  box(12.4,13.7,.25,.25,10,'#C0392B'); // 소화전
}
function tree(x,y){box(x-.08,y-.08,.16,.16,10,'#8B5E3C');const c=P(x,y,24);g.fillStyle='#7FA48A';g.beginPath();g.arc(c[0],c[1],10*Z,0,7);g.fill();g.fillStyle='#93B59C';g.beginPath();g.arc(c[0]-3*Z,c[1]-3*Z,6*Z,0,7);g.fill();}
function building(b,t){
  poly([P(b.x+.3,b.y+b.d),P(b.x+b.w+.3,b.y+b.d),P(b.x+b.w+.6,b.y+b.d+.5),P(b.x+.6,b.y+b.d+.5)],'rgba(26,26,46,.08)');
  box(b.x,b.y,b.w,b.d,b.h,b.top,0,b.side);
  const floors=Math.max(1,Math.floor(b.h/30));
  for(let f=0;f<floors;f++){const h0=12+f*30,h1=h0+12;
    for(let i=.6;i<b.w-.4;i+=1.1){const lit=b.real&&((Math.floor(t/1800)+i*3+f)%5<2);poly([P(b.x+i,b.y+b.d,h0),P(b.x+i+.6,b.y+b.d,h0),P(b.x+i+.6,b.y+b.d,h1),P(b.x+i,b.y+b.d,h1)],lit?'#CFE3F2':'#A9B8C8');}
    for(let i=.6;i<b.d-.4;i+=1.1)poly([P(b.x+b.w,b.y+i,h0),P(b.x+b.w,b.y+i+.6,h0),P(b.x+b.w,b.y+i+.6,h1),P(b.x+b.w,b.y+i,h1)],'#B3C1D0');}
  if(b.id==='office'){box(b.x+1,b.y+1,1.2,1.2,12,'#C9CED6',b.h);box(b.x+4,b.y+3,1.6,1,8,'#C9CED6',b.h);}
  if(b.id==='mat'){for(let i=0;i<4;i++)poly([P(b.x,b.y+1.6*i+.4,b.h),P(b.x+b.w,b.y+1.6*i+.4,b.h),P(b.x+b.w,b.y+1.6*i+.9,b.h),P(b.x,b.y+1.6*i+.9,b.h)],'rgba(26,26,46,.06)');}
  if(b.id==='util'){box(b.x+1,b.y+1,.8,.8,60,'#B8BEC6',b.h);for(let i=0;i<3;i++){const ph=((t/2600)+i/3)%1,p=P(b.x+1.4,b.y+1.4,b.h+70+ph*50);g.fillStyle=`rgba(200,206,214,${.6*(1-ph)})`;g.beginPath();g.arc(p[0],p[1],(5+ph*10)*Z,0,7);g.fill();}
    for(let i=0;i<2;i++){const c2=P(b.x+3.2,b.y+1.2+i*1.8,b.h);g.fillStyle='#D5DAE1';g.beginPath();g.ellipse(c2[0],c2[1]-14*Z,14*Z,7*Z,0,0,7);g.fill();g.fillRect(c2[0]-14*Z,c2[1]-14*Z,28*Z,14*Z);g.fillStyle='#E9ECF0';g.beginPath();g.ellipse(c2[0],c2[1]-14*Z,14*Z,7*Z,0,0,7);g.fill();}}
  if(b.id==='maint'){poly([P(b.x+b.w,b.y+1,0),P(b.x+b.w,b.y+3.4,0),P(b.x+b.w,b.y+3.4,34),P(b.x+b.w,b.y+1,34)],'#8E99A8');}
  if(b.id==='qc'){const c=P(b.x+b.w/2,b.y+b.d/2,b.h);g.fillStyle='#D3E3E0';g.beginPath();g.ellipse(c[0],c[1],26*Z,13*Z,0,0,7);g.fill();}
  if(b.id==='ship'){for(let i=0;i<3;i++){poly([P(b.x+1.4+i*2.6,b.y+b.d,0),P(b.x+3.2+i*2.6,b.y+b.d,0),P(b.x+3.2+i*2.6,b.y+b.d,30),P(b.x+1.4+i*2.6,b.y+b.d,30)],'#8E99A8');}}
  b._sign=P(b.x+b.w/2,b.y+b.d/2,b.h+(b.id==='util'?70:16));b._c=P(b.x+b.w/2,b.y+b.d/2,b.h/2);
}
// 간판 둘째 줄: /api/campus buildings 값
function signLine(b){
  if(!b.real)return null;
  const d=S.c&&S.c.buildings[b.api];if(!d)return '불러오는 중';
  if(b.id==='office')return `수주 대기 ${d.orders.open} · 부분 ${d.orders.partial} · 완료 ${d.orders.done}`;
  if(b.id==='mat')return `입고대 ${d.receiving_qty.toLocaleString()} · 10분 트럭 ${d.received_trucks_10m}대`;
  if(b.id==='qc')return `불량률 ${d.defect_ratio_60m==null?'-':(d.defect_ratio_60m*100).toFixed(2)+'%'} (60분)`;
  if(b.id==='ship')return `60분 출하 ${d.shipped_60m.toLocaleString()}`;
  return null;
}
function sign(b){
  const [x,y]=b._sign;const k=Math.max(.75,Math.min(1.25,Z/0.42));
  const lines=[b.name],l2=signLine(b);if(l2)lines.push(l2);
  const w=Math.max(...lines.map((l,i)=>{g.font=i?`600 ${10.5*k}px Pretendard`:`800 ${12*k}px Pretendard`;return g.measureText(l).width;}))+18*k;
  const h=(lines.length>1?36:20)*k;
  g.fillStyle=b.real?'#1A1A2E':'rgba(255,255,255,.85)';g.fillRect(x-w/2,y-h,w,h);
  g.textAlign='center';g.fillStyle=b.real?'#fff':'#6B7280';g.font=`800 ${12*k}px Pretendard`;g.fillText(lines[0],x,y-h+14*k);
  if(lines[1]){g.fillStyle='#9FB6D3';g.font=`600 ${10.5*k}px Pretendard`;g.fillText(lines[1],x,y-h+29*k);}g.textAlign='left';
  if(b.real){g.fillStyle='#1A1A2E';g.beginPath();g.moveTo(x-5*k,y);g.lineTo(x+5*k,y);g.lineTo(x,y+6*k);g.fill();}
}
function drawFlow(){
  g.strokeStyle='rgba(14,124,134,.55)';g.lineWidth=3*Z;g.lineJoin='round';g.beginPath();FLOW.forEach((p,i)=>{const s=P(p[0],p[1],1);i?g.lineTo(...s):g.moveTo(...s);});g.stroke();
}
function hallSign(){if(Z>.75)return;const k=Math.max(.75,Math.min(1.25,Z/0.42));const p=P(HALL.x+HW/2,HALL.y+HH/2,150);
  const run=nState('running'),bad=nState('broken');
  const l1='생산동 LINE A',l2=dataReady()?`가동 ${run}/${M.length} · 고장 ${bad}`:'불러오는 중';g.font=`800 ${13*k}px Pretendard`;const w=Math.max(g.measureText(l1).width,110*k)+20*k;
  g.fillStyle='#1A1A2E';g.fillRect(p[0]-w/2,p[1]-38*k,w,38*k);g.textAlign='center';g.fillStyle='#fff';g.fillText(l1,p[0],p[1]-22*k);g.font=`600 ${11*k}px Pretendard`;g.fillStyle=bad?'#F2A49B':'#9FD3B0';g.fillText(l2,p[0],p[1]-7*k);g.textAlign='left';
  g.fillStyle='#1A1A2E';g.beginPath();g.moveTo(p[0]-5*k,p[1]);g.lineTo(p[0]+5*k,p[1]);g.lineTo(p[0],p[1]+6*k);g.fill();}
// 바닥 글씨: 둘째 줄이 sim_note
function floorText(){
  const note=(S.err?'연결 끊김 · 마지막 값 · ':'')+(S.note||(dataReady()?'':'불러오는 중'));
  onFloor(2.2,32.6,()=>{g.fillStyle='rgba(26,26,46,.4)';g.font='600 13px Pretendard';g.fillText('건물을 눌러 보기 · 생산동은 눌러서 들어가기 · 끌어서 이동',0,0);g.fillStyle='rgba(26,26,46,.3)';g.font='500 11px Pretendard';g.fillText(note,0,18);});
}
