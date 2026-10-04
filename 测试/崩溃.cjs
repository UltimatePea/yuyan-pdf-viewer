'use strict';
process.env.YY_VIEWER_BACKGROUND='1';
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict');
const source=process.env.YY_CRASH_PDF;
if(!source){console.log('SKIP private crash PDF: set YY_CRASH_PDF to a test copy');process.exit(0);}
const root=fs.mkdtempSync(path.join(os.tmpdir(),'阅卷 崩溃 ')),file=path.join(root,'crash-copy.pdf');fs.copyFileSync(source,file);
process.env.YY_JUMP_POINTS_DIRECTORY=path.join(root,'points');
const {pdf}=require('./夹具.cjs');let api,checks=0;const state=()=>api('inspect');
function check(value,label){assert.ok(value,label);checks++;console.log('PASS '+label);}
function* wait(fn,label){let start=Date.now();while(!fn()){if(Date.now()-start>30000)throw Error('Timeout '+label+' '+JSON.stringify(state()));yield;}}
function* delay(ms){let start=Date.now();while(Date.now()-start<ms)yield;}
function* scenario(){
 yield* wait(()=>state().pages>0,'open copied crash PDF');
 check(state().skippedTextLines>0,'malformed PDFKit line ranges are skipped without crashing');
 check(state().textLines>100,'valid text remains available for reading anchors');
 const pages=state().pages,digest=state().digest;console.log(JSON.stringify({pages,skipped:state().skippedTextLines,textLines:state().textLines}));
 for(let i=0;i<pages;i++) {api('testPosition',[i,1,500]);check(state().page===i,'page '+(i+1)+' remains navigable');}
 api('testSearch',['the']);const search=api('inspectSearch');check(search.count>0&&search.highlighted===search.count,'search finds and highlights matches in the crash PDF');
 api('testSearchStep',[1]);api('testSearchStep',[-1]);check(api('inspectSearch').count===search.count,'search navigation on the crash PDF is safe');
 api('testSearch',['']);api('testPosition',[20,1.2,500]);api('addJump',['Crash page']);yield* wait(()=>api('inspectJumps').length===1,'save jump');
 const id=api('inspectJumps')[0].id;api('testPosition',[0,1.2,500]);api('jump',[id]);yield* wait(()=>state().page===20,'jump');check(api('inspectJumps')[0].name==='Crash page','page 21 supports saved jump points');
 const loads=state().loads;fs.writeFileSync(file,fs.readFileSync(source));yield* wait(()=>state().loads>loads,'reload');yield* delay(350);check(state().digest===digest&&state().versionCount===1,'identical crash PDF reload adds no history and stays open');
 fs.writeFileSync(file,pdf(['Temporary build']));yield* wait(()=>state().pages===1,'normal build');check(state().skippedTextLines===0,'normal refresh clears the skipped-line count');
 api('history',[0]);yield* wait(()=>state().pages===pages,'history');check(state().skippedTextLines>0&&state().digest===digest,'history restores the crash PDF safely with its extraction metadata');
 api('close');api('open',[file]);yield* wait(()=>state().pages===1,'reopen latest');check(state().versionCount===2,'close/reopen retains both snapshots');
 api('history',[0]);yield* wait(()=>state().pages===pages,'old snapshot reopened');check(state().skippedTextLines>0,'reopened historical snapshot is still safe');
 const ui=api('inspectUI');check(!ui.active&&!ui.visible&&!ui.canBecomeKey&&!ui.canBecomeMain,'crash regression does not take focus');
 api('quit');console.log(JSON.stringify({passed:checks,directory:root}));
}
let last=0,flow=scenario();try{require('../源码/宿主.cjs').run({pdf:file,hook:a=>{api=a;if(Date.now()-last<15)return;last=Date.now();flow.next();}});}catch(error){console.error(error);process.exitCode=1;if(api)api('quit');}
