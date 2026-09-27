// 文言：存点、易卷、复启，皆验其所至。汉语：真实 Yuyan/Wasm-GC 与 PDFKit 跳点回归。
'use strict';
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict'),cp=require('node:child_process');
const {pdf}=require('./夹具.cjs');
const reopening=process.env.YY_JUMP_REOPEN_FILE;
const root=reopening?path.dirname(reopening):fs.mkdtempSync(path.join(os.tmpdir(),'阅卷 跳点 '));
const file=reopening||path.join(root,'document α.pdf');
process.env.YY_JUMP_POINTS_DIRECTORY ||= path.join(root,'saved-points');
if(!reopening)fs.writeFileSync(file,pdf(['Alpha','Beta','Gamma','Delta']));
let api,checks=0;const state=()=>api('inspect'),points=()=>api('inspectJumps');
function check(value,message){assert.ok(value,message);checks++;console.log('PASS '+message);}
function* wait(f,label,timeout=10000){const start=Date.now();while(!f()){if(Date.now()-start>timeout)throw Error('Timeout '+label+' '+JSON.stringify(state()));yield;}}
function* delay(ms){const t=Date.now();while(Date.now()-t<ms)yield;}
function* add(name){const count=points().length;api('addJump',[name]);yield* wait(()=>points().length===count+1,'set jump point');}
function* jump(id){api('jump',[id]);yield;yield* wait(()=>state().status.startsWith('Jumped to'),'jump request');}
function* replace(pages,options={}){const commits=state().commits;fs.writeFileSync(file,pdf(pages,options));yield* wait(()=>state().commits>commits,'rebuild');}
function* scenario(){
 yield* wait(()=>state().pages>0,'open');
 if(reopening){
   check(points().length===1&&points()[0].name==='A','jump point survives a fresh process');
   yield* jump(points()[0].id);check(state().anchor.text.includes('Gamma')&&state().page===3,'restored jump resolves against reopened PDF');api('quit');return;
 }
 check(points().length===0,'new document starts without jump points');
 api('testPosition',[2,1.3,500]);yield* delay(100);const original=state();yield* add('');let a=points()[0];
 check(a.name==='A'&&a.anchors[0].text===original.anchor.text,'blank name creates A at current passage');
 api('testPosition',[0,1.3,500]);yield* add('  Definition α  ');const named=points()[1];check(named.name==='Definition α','optional Unicode name is trimmed and retained');
 yield* add('   ');check(points()[2].name==='B','whitespace-only name creates B');
 yield* add('C');yield* add('');check(points().at(-1).name==='D','automatic labels skip an explicitly named C');
 while(!points().some(p=>p.name==='AB'))yield* add('');
 check(points().some(p=>p.name==='Z')&&points().some(p=>p.name==='AA')&&points().some(p=>p.name==='AB'),'alphabetical labels continue Z, AA, AB');
 for(const p of points().slice(2))api('removeJump',[p.id]);check(points().length===2,'each point can be removed independently');
 const location=state().anchor.text;
 yield* replace(['Inserted','Alpha','Beta','Gamma','Delta']);
 check(points().find(p=>p.id===a.id).page===3,'saved point follows insertion before its page');
 check(state().anchor.text===location,'remapping stored points does not move the reader');
 api('testPosition',[0,1.6,500]);yield* jump(a.id);
 check(state().page===3&&state().anchor.text===original.anchor.text,'Jump to returns to the same passage after rebuild');check(Math.abs(state().zoom-1.6)<.001,'jump preserves current zoom');
 api('testMode',[0]);api('testPosition',[1,1.6,500]);yield* jump(a.id);check(state().page===3&&state().mode===0,'jump works in single-page mode');api('testMode',[1]);
 yield* replace(['Alpha','Beta','Gamma','Delta']);check(points().find(p=>p.id===a.id).page===2,'saved point follows deletion before its page');
 // Change the exact anchored text; neighboring text must still locate the same region.
 const passage=points().find(p=>p.id===a.id).anchors[0].text.match(/passage(\d+):/)[1];let modified=pdf(['Alpha','Beta','Gamma','Delta']).toString().replace('Gamma passage '+passage+':','GAMMA passage '+passage+':');
 const commits=state().commits;fs.writeFileSync(file,modified);yield* wait(()=>state().commits>commits,'edit saved passage');api('testPosition',[0,1.3,500]);yield* jump(a.id);check(state().page===2,'changed target text uses a neighboring anchor');
 yield* replace(['Only']);api('testPosition',[0,1.3,500]);yield* jump(a.id);check(state().page===0&&state().status.includes('approximate'),'removed target falls back safely and reports approximation');
 yield* replace(['Inserted','Alpha','Beta','Gamma','Delta']);api('testPosition',[0,1.3,500]);yield* jump(a.id);check(state().page===3,'returning content recovers the original semantic anchor');
 const before=state().anchor.text;api('removeJump',[named.id]);check(points().length===1&&points()[0].id===a.id,'remove leaves other points intact');check(state().anchor.text===before,'removing a point never navigates');
 api('jump',[named.id]);yield* delay(100);check(state().anchor.text===before,'queued action for a removed point is harmless');
 const other=path.join(root,'image-only.pdf');fs.writeFileSync(other,pdf(['Image','Image'],{image:true}));api('open',[other]);yield* wait(()=>state().pages===2,'other document');check(points().length===0,'jump points are isolated by document');
 api('testPosition',[1,1.2,500]);yield* add('');const imagePoint=points()[0];api('testPosition',[0,1.2,500]);yield* jump(imagePoint.id);check(state().page===1&&state().status.includes('approximate'),'image-only jump preserves page coordinates');
 api('close');api('open',[file]);yield* wait(()=>state().pages===5,'reopen original');check(points().length===1&&points()[0].id===a.id,'closing and reopening retains saved points and removals');
 yield* jump(a.id);check(state().page===3,'reopened point jumps correctly');
 const child=cp.spawnSync(process.env.YY_TEST_NODE||'node',[__filename],{env:{...process.env,YY_JUMP_REOPEN_FILE:file},encoding:'utf8',timeout:30000});
 check(child.status===0,'fresh-process persistence test passes: '+child.stdout.trim());if(child.status!==0)console.error(child.stderr);
 api('quit');console.log(JSON.stringify({passed:checks,directory:root}));
}
let last=0,flow=scenario();
try{require('../源码/宿主.cjs').run({pdf:file,hook:a=>{api=a;if(Date.now()-last<15)return;last=Date.now();flow.next();}});}catch(e){console.error(e);process.exitCode=1;if(api)api('quit');}
