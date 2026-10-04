'use strict';process.env.YY_VIEWER_BACKGROUND='1';
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict');const {pdf}=require('./夹具.cjs');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'阅卷 工具栏 ')),file=path.join(root,'paper.pdf');fs.writeFileSync(file,pdf(['Alpha','Beta']));process.env.YY_JUMP_POINTS_DIRECTORY=path.join(root,'points');
let api,checks=0;function check(v,s){assert.ok(v,s);checks++;console.log('PASS '+s);}
function* wait(fn){let t=Date.now();while(!fn()){if(Date.now()-t>10000)throw Error('Timeout');yield;}}
const rect=s=>(s.match(/-?[\d.]+/g)||[]).map(Number),layout=()=>api('inspectToolbar');
function verify(s,label){let bounds=rect(s.bounds),p=rect(s.pdf);for(let f of s.frames){let r=rect(f);assert.ok(r[0]>=0&&r[1]>=0&&r[0]+r[2]<=bounds[2]+.1&&r[1]+r[3]<=bounds[3]+.1,'control bounds '+f);assert.ok(r[1]>=p[1]+p[3],'PDF overlaps '+f);}check(s.searchWidth>=180,label+' keeps search readable and all controls inside the toolbar');}
function* scenario(){
 yield* wait(()=>api('inspect').pages===2);api('testSize',[760,420]);check(!layout().overflow,'empty toolbar remains one row at minimum window width');verify(layout(),'narrow empty toolbar');
 for(let i=0;i<8;i++)api('addJump',['Important checkpoint '+i]);yield* wait(()=>api('inspectJumps').length===8);
 let s=layout();check(s.overflow,'saved points overflow to a second row');verify(s,'narrow overflowing toolbar');check(s.pointHeight>=32&&s.scrollHeight>=36,'point buttons have enough vertical space without clipping');
 api('testPointScroll');check(layout().scrollX>0,'overflow points remain reachable by horizontal scrolling');
 api('testSearch',['Alpha']);api('testSearchStep',[1]);check(api('inspectSearch').index===1,'search buttons work in overflow layout');
 fs.writeFileSync(file,pdf(['Inserted','Alpha','Beta']));yield* wait(()=>api('inspect').pages===3);s=layout();check(s.overflow,'history and jump points share the overflow row');verify(s,'overflow toolbar with history');
 api('testSize',[2100,700]);check(!layout().overflow,'wide windows return all controls to one row');verify(layout(),'wide toolbar');
 api('testSize',[980,700]);check(layout().overflow,'shrinking restores the second row');verify(layout(),'resized toolbar');
 for(let p of api('inspectJumps'))api('removeJump',[p.id]);check(!layout().overflow,'removing points collapses the extra row when it is unnecessary');
 api('testSize',[760,420]);check(layout().overflow,'history moves down when even the history group cannot fit beside search');verify(layout(),'minimum-size history toolbar');
 api('close');check(!layout().overflow,'closing the document clears the overflow row');
 const ui=api('inspectUI');check(!ui.active&&!ui.visible&&!ui.canBecomeKey,'toolbar tests stay hidden and cannot take focus');api('quit');console.log(JSON.stringify({passed:checks,directory:root}));
}
let last=0,flow=scenario();try{require('../源码/宿主.cjs').run({pdf:file,hook:a=>{api=a;if(Date.now()-last<15)return;last=Date.now();flow.next();}});}catch(e){console.error(e);process.exitCode=1;if(api)api('quit');}
