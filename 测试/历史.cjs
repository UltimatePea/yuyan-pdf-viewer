// 文言：诸版留存，览旧不扰，原卷不改。汉语：真实 Wasm-GC/PDFKit 内存版本历史回归。
'use strict';
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {pdf}=require('./夹具.cjs');const root=fs.mkdtempSync(path.join(os.tmpdir(),'阅卷 历史 ')),file=path.join(root,'paper α.pdf');
process.env.YY_JUMP_POINTS_DIRECTORY=path.join(root,'points');
const a=pdf(['Alpha','Beta','Gamma']),b=pdf(['Inserted','Alpha','Beta','Gamma']),c=pdf(['New','Inserted','Alpha','Beta','Gamma']);
const hash=data=>crypto.createHash('sha256').update(data).digest('hex');fs.writeFileSync(file,a);
let api,checks=0;const state=()=>api('inspect'),versions=()=>api('inspectVersions');
function check(value,message){assert.ok(value,message);checks++;console.log('PASS '+message);}
function* wait(f,label,timeout=10000){const start=Date.now();while(!f()){if(Date.now()-start>timeout)throw Error('Timeout '+label+' '+JSON.stringify(state()));yield;}}
function* delay(ms){const t=Date.now();while(Date.now()-t<ms)yield;}
function* select(index){api('history',[index]);yield* wait(()=>state().versionIndex===index,'history selection');}
function* write(data){const count=versions().length;fs.writeFileSync(file,data);yield* wait(()=>versions().length===count+1,'new version');}
function* scenario(){
 yield* wait(()=>state().pages===3,'open');check(versions().length===1&&state().versionIndex===0,'initial PDF becomes version one');
 check(versions()[0].bytes===a.length&&versions()[0].digest===hash(a),'initial snapshot retains the exact PDF bytes');
 api('testPosition',[2,1.3,500]);const anchor=state().anchor.text,firstTime=state().lastUpdatedMs;
 yield* write(b);check(versions().length===2&&state().versionIndex===1&&state().pages===4,'successful refresh adds and displays the next version');
 api('addJump',['Gamma']);yield* wait(()=>api('inspectJumps').length===1,'bookmark');const point=api('inspectJumps')[0],savedPoint=JSON.stringify(point);
 api('historyStep',[-1]);yield* wait(()=>state().versionIndex===0,'previous');
 check(state().digest===hash(a)&&state().pages===3,'Previous restores old content from memory');
 check(state().anchor.text===anchor&&state().page===2,'switching versions preserves the reading passage');
 check(Math.abs(state().zoom-1.3)<.001&&state().lastUpdatedMs===firstTime,'history preserves zoom and original update timestamp');
 check(state().status.includes('Viewing version 1/2'),'status identifies a historical version');
 api('jump',[point.id]);yield* delay(100);check(JSON.stringify(api('inspectJumps')[0])===savedPoint,'historical viewing does not rewrite persisted jump anchors');
 yield* write(c);check(state().versionIndex===0&&state().digest===hash(a)&&versions().length===3,'new refresh is retained without interrupting history browsing');
 api('historyStep',[1]);yield* wait(()=>state().versionIndex===1,'next');check(state().digest===hash(b),'Next restores the intervening version');
 api('historyStep',[0]);yield* wait(()=>state().versionIndex===2,'latest');check(state().digest===hash(c)&&state().page===4,'Latest restores newest content and reading passage');
 yield* select(0);const before=versions().length,loads=state().loads;fs.writeFileSync(file,c);
 yield* wait(()=>state().loads>loads&&state().status.includes('Updated at'),'identical snapshot');yield* delay(200);
 check(versions().length===before&&state().versionIndex===0,'unchanged latest bytes do not duplicate history or exit an old version');
 fs.writeFileSync(file,'%PDF-1.4\npartial');yield* delay(450);check(versions().length===before&&state().digest===hash(a),'invalid refresh adds no version and keeps the selected snapshot');
 fs.unlinkSync(file);yield* delay(200);yield* select(1);check(state().digest===hash(b),'history works while the watched file is deleted');
 fs.writeFileSync(file,c);yield* delay(400);check(versions().length===before,'recreating the same latest content adds no duplicate');
 yield* write(a);check(versions().length===4&&versions()[3].digest===hash(a),'disk revert is recorded as a new chronological version');
 const changed=pdf(['Newest'],{revision:'after live'});api('historyStep',[0]);yield* wait(()=>state().versionIndex===3,'return live');yield* write(changed);
 check(state().versionIndex===4&&state().pages===1,'returning to latest resumes automatic live refresh');
 yield* select(0);api('testFollow',[1]);
 for(let i=0;i<8;i++)yield* write(pdf(['Build '+i],{revision:String(i)}));
 check(versions().length===13&&state().versionIndex===0,'all captured versions are retained without eviction, even with Follow Edits enabled');
 yield* select(1);check(state().digest===hash(b),'early snapshots remain intact after many later rebuilds');
 const entries=versions();for(let i=0;i<entries.length;i++){yield* select(i);check(state().digest===entries[i].digest&&state().lastUpdatedMs===entries[i].time,'snapshot '+(i+1)+' restores its own bytes and timestamp');}
 check(versions().length===entries.length,'browsing history never creates new versions');
 api('historyStep',[1]);yield* delay(80);check(state().versionIndex===entries.length-1,'next at latest is harmless');yield* select(0);api('historyStep',[-1]);yield* delay(80);check(state().versionIndex===0,'previous at first is harmless');
 const diskBefore=fs.readFileSync(file);check(hash(diskBefore)===entries.at(-1).digest,'browsing history never rewrites the watched PDF');
 const other=path.join(root,'other.pdf');fs.writeFileSync(other,pdf(['Other']));api('open',[other]);yield* wait(()=>state().pages===1&&state().versionCount===1,'other document');check(versions().length===1,'different documents have independent histories');
 api('close');api('open',[file]);yield* wait(()=>state().versionCount===entries.length&&state().versionIndex===entries.length-1,'reopen history');check(versions().length===entries.length,'history survives close/reopen within the app session');yield* select(0);check(state().digest===hash(a),'reopened document can still access its earliest snapshot');
 api('quit');console.log(JSON.stringify({passed:checks,directory:root}));
}
let last=0,flow=scenario();try{require('../源码/宿主.cjs').run({pdf:file,hook:a=>{api=a;if(Date.now()-last<15)return;last=Date.now();flow.next();}});}catch(error){console.error(error);process.exitCode=1;if(api)api('quit');}
