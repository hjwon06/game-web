// 자재창고 안쪽: 랙 4개 × 칸 6개 아이소 선반. 칸마다 팔레트 블록 = ceil(qty/500), 품목 색.
// 칸 값은 S.shown(= 그 칸으로 가는 작업이 끝나고 지게차가 닿은 뒤에만 바뀌는 값)에서 읽는다.
const VX0=15,VY0=3,VW=8,VD=7,VZ=4,PALLET_QTY=500;
let VL={src:null,items:[],map:new Map()};
function vaultLayout(){ // 서버 칸 목록 → 랙·칸 배치(원료 칸만)
  if(!S.bins||VL.src===S.bins)return VL;
  let list=S.bins.filter(b=>/^RAW/i.test(b.code));if(!list.length)list=S.bins.slice(0,24);
  const racks=new Map();list.forEach(b=>{const k=b.rack||b.code.split('-').slice(0,2).join('-');(racks.get(k)||racks.set(k,[]).get(k)).push(b);});
  const items=[],map=new Map();
  [...racks.keys()].sort().forEach((key,k)=>{const bs=racks.get(key).sort((a,b)=>a.code<b.code?-1:1),step=Math.min(.9,5.6/bs.length);
    bs.forEach((b,j)=>{const e={code:b.code,rack:key,k,j,x:16+k*1.9,y:3.8+j*step,w:1,d:step-.05,xa:16+k*1.9+1.45};e.cy=e.y+e.d/2;items.push(e);map.set(b.code,e);});});
  VL={src:S.bins,items,map};return VL;
}
const vaultBin=code=>{const e=vaultLayout().map.get(code);return e?{...e,...(S.shown.get(code)||{product:'',qty:0,cap:0,color:'#C9A227'})}:null;};
const blocksOf=qty=>Math.ceil((Number(qty)||0)/PALLET_QTY);
function drawSlot(e,t){
  const d=S.shown.get(e.code)||{qty:0,cap:0,color:'#C9A227'},n=blocksOf(d.qty),fill=d.cap>0?d.qty/d.cap:0;
  const post=(x,y)=>box(x-.03,y-.03,.06,.06,30,'#8793A3',VZ);
  post(e.x,e.y);post(e.x+e.w,e.y);
  poly([P(e.x,e.y,VZ),P(e.x+e.w,e.y,VZ),P(e.x+e.w,e.y+e.d,VZ),P(e.x,e.y+e.d,VZ)],fill>.85?'#E6D5AE':'#D5DBE3',V.selBin===e.code?'#1A1A2E':'#B8C0CB',V.selBin===e.code?2.5*Z:1);
  const layers=Math.ceil(n/4),bh=Math.min(8,24/Math.max(1,layers));
  for(let i=0;i<n;i++){const l=Math.floor(i/4),p=i%4,ix=p%2,iy=p>>1;
    box(e.x+.07+ix*.44,e.y+.04+iy*(e.d-.1)/2,.4,(e.d-.1)/2-.02,bh-.6,d.color,VZ+1+l*bh);}
  post(e.x,e.y+e.d);post(e.x+e.w,e.y+e.d);
  e._poly=[P(e.x,e.y,VZ),P(e.x+e.w,e.y,VZ),P(e.x+e.w,e.y+e.d,VZ),P(e.x,e.y+e.d,VZ)];e._p=P(e.x+e.w/2,e.cy,VZ+14);
}
function drawVault(t){
  const b=B.find(x=>x.id==='mat'),WH=70;
  box(VX0-.2,VY0-.2,VW+.4,VD+.4,VZ,'#F4F5F7',0,'#C9CED6');
  plane3(VX0,VY0,VW,VD,'#E9ECEF');
  poly([P(VX0,VY0,VZ),P(VX0+VW,VY0,VZ),P(VX0+VW,VY0,WH),P(VX0,VY0,WH)],'#C9D0D9');poly([P(VX0,VY0,VZ),P(VX0,VY0+VD,VZ),P(VX0,VY0+VD,WH),P(VX0,VY0,WH)],'#B9C1CC');
  poly([P(VX0,VY0,WH),P(VX0+VW,VY0,WH),P(VX0+VW,VY0-.25,WH+2),P(VX0-.25,VY0-.25,WH+2),P(VX0-.25,VY0+VD,WH+2),P(VX0,VY0+VD,WH)],'#A9B2BE');
  const L=vaultLayout();
  if(!L.items.length)onFloor(VX0+1,VY0+3.4,()=>{g.fillStyle='rgba(26,26,46,.45)';g.font='700 12px Pretendard';g.fillText(S.bins?'칸 정보 없음':'칸 불러오는 중',0,0);});
  const racks=[];L.items.forEach(e=>{(racks[e.k]=racks[e.k]||[]).push(e);});
  racks.forEach(r=>{const x=r[0].x,y1=r[r.length-1].y+r[r.length-1].d;
    box(x-.06,3.7,1.12,y1-3.7+.1,2,'#9AA5B3',VZ); // 랙 바닥틀
    r.forEach(e=>drawSlot(e,t));
    onFloor(x+.05,9.5,()=>{g.fillStyle='rgba(26,26,46,.5)';g.font='700 9px Outfit';g.fillText(r[0].rack,0,0);});});
  b._sign=P(VX0+VW/2,VY0+VD/2,WH+6);b._c=P(VX0+VW/2,VY0+VD/2,30);
}
const plane3=(x,y,w,d,c)=>poly([P(x,y,VZ),P(x+w,y,VZ),P(x+w,y+d,VZ),P(x,y+d,VZ)],c);
function inPoly(px,py,pts){let c=false;for(let i=0,j=pts.length-1;i<pts.length;j=i++){const a=pts[i],b=pts[j];if(((a[1]>py)!==(b[1]>py))&&(px<(b[0]-a[0])*(py-a[1])/(b[1]-a[1])+a[0]))c=!c;}return c;}
function vaultHit(x,y){ // 가까운(앞쪽) 칸부터: 바닥 면 또는 그 위 블록 높이까지
  const items=vaultLayout().items.slice().reverse();
  const hit=items.find(e=>e._poly&&[0,10,20].some(dy=>inPoly(x,y+dy*Z,e._poly)));return hit?hit.code:null;
}
const inVaultRect=(x,y)=>inPoly(x,y,[P(VX0,VY0+VD,70),P(VX0,VY0,70),P(VX0+VW,VY0,70),P(VX0+VW,VY0,VZ),P(VX0+VW,VY0+VD,VZ),P(VX0,VY0+VD,VZ)]); // 벽 높이까지 포함한 육각형
