// 도로 그래프: 건물 사이 길과 경로 계산. 화물·트럭은 campus_haul.js 가 작업(tasks)에서 만든다.
const NODE={gate:[44.5,16.3],j1:[26.2,16.3],j2:[26.2,12.5],j3:[14,12.5],j4:[3.5,12.5],j5:[26.2,26.5],j6:[39,16.3],
  mat:[14,7.5],prod:[3.5,17.6],qc:[27.6,26.5],ship:[39,18.4],scrap:[35.6,26.5],office:[12.6,7]};
const EDGE=[['gate','j6'],['j6','j1'],['j6','ship'],['j1','j2'],['j1','j5'],['j2','j3'],['j3','j4'],['j3','mat'],['j4','prod'],['j5','qc'],['qc','scrap'],['j3','office']];
const ADJ={};EDGE.forEach(([a,b])=>{(ADJ[a]=ADJ[a]||[]).push(b);(ADJ[b]=ADJ[b]||[]).push(a);});

function route(a,b){ // 도로 그래프 위 최단 경로 → 좌표 목록
  if(a===b){const [x,y]=NODE[a];return[[x,y]];}
  const prev={[a]:null},q=[a];
  while(q.length){const n=q.shift();if(n===b)break;(ADJ[n]||[]).forEach(m=>{if(!(m in prev)){prev[m]=n;q.push(m);}});}
  const path=[];for(let n=b;n!=null;n=prev[n])path.unshift(NODE[n]);
  return path;
}
const polyLen=pts=>pts.slice(1).reduce((s,p,i)=>s+Math.hypot(p[0]-pts[i][0],p[1]-pts[i][1]),0);
function along(pts,len,u){let d=Math.max(0,Math.min(1,u))*len;for(let i=0;i<pts.length-1;i++){const a=pts[i],b=pts[i+1],l=Math.hypot(b[0]-a[0],b[1]-a[1]);if(d<=l&&l>0)return[a[0]+(b[0]-a[0])*d/l,a[1]+(b[1]-a[1])*d/l];d-=l;}return pts[pts.length-1];}
function drawScrap(){ // 품질검사동 옆 폐기 더미
  const [x,y]=NODE.scrap;[[0,0,10],[.5,.2,7],[-.2,.5,5]].forEach(([dx,dy,h])=>box(x+dx,y+dy-.3,.6,.5,h,'#7B8490',0));
}
