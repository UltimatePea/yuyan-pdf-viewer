// 文言：诸版存盘，复启犹在；可去其一，以较其前后。汉语：版本库与删除版本回归。真实 Wasm-GC/PDFKit，分五个进程验证重启前后的状态，后台运行不抢焦点。
// 一：记录并写入；二：重启后恢复、惰性读入、确认后删除版本；三：删除已持久化，缓存缺损可重建；四：PDF 损坏的版本；五：版本库无法写入。
'use strict';
process.env.YY_VIEWER_BACKGROUND='1';
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto'),cp=require('node:child_process');
const {layout}=require('./夹具.cjs');
const phase=Number(process.env.YY_STORE_PHASE||1),root=phase>1?process.env.YY_STORE_ROOT:fs.mkdtempSync(path.join(os.tmpdir(),'阅卷 存版 '));
const file=path.join(root,phase===5?'unsaved.pdf':'paper α.pdf'),notes=path.join(root,'notes.json'),base=path.join(root,'versions');
process.env.YY_JUMP_POINTS_DIRECTORY=path.join(root,'points');
process.env.YY_VERSIONS_DIRECTORY=phase===5?path.join(root,'blocked','versions'):base;
// 文言：四页，页三十行。乙为误改，丙复其旧而别有所改，丁又改一处。
// 汉语：B 在 A 上做了一处不想要的改动；C 把它改回去，并在同一页另做一处真正的改动；D 在 C 上再改一处。
const sheet=(p,changed={})=>Array.from({length:30},(_,i)=>[72,730-i*18,12,`Page ${p} line ${i} ${changed[i]||'steady'} words here`]);
const make=changes=>layout([0,1,2,3].map(p=>sheet(p,changes[p])));
const A=make({}),B=make({1:{5:'unwanted'}}),C=make({1:{20:'wanted'}}),D=make({1:{20:'wanted'},3:{9:'fourth'}}),E=make({0:{2:'extra'}});
const hash=data=>crypto.createHash('sha256').update(data).digest('hex'),json=JSON.stringify,fake='f'.repeat(64),empty='00000000000001-'+'a'.repeat(64)+'.pdf';
let api,checks=0;
const state=()=>api('inspect'),versions=()=>api('inspectVersions'),diff=()=>api('inspectDiff'),menu=()=>api('inspectVersionMenu'),entry=title=>menu().find(i=>i.title===title);
const stored=()=>api('inspectStore').files,folder=()=>api('inspectStore').folder,digests=()=>versions().map(v=>v.digest),times=()=>versions().map(v=>v.time);
const alert=()=>api('inspectAlert'),answer=(button,again=false)=>api('testAlert',[button,again]),undone=' will be deleted from memory and from disk. This cannot be undone.';
const words=list=>list.map(w=>w.text).sort().join(' '),removeTitle=n=>entry('Remove Version').items.find(i=>i.title.startsWith(`Version ${n} — `)).title;
// 版本库里每个版本的文件名（不含扩展名）；三个文件不齐则为 null。
const complete=()=>{const names=stored(),stems=names.filter(n=>/^\d{14}-[0-9a-f]{64}\.pdf$/.test(n)&&n!==empty).map(n=>n.slice(0,-4));return stems.every(s=>names.includes(s+'.words')&&names.includes(s+'.lines'))?stems:null;};
const onDisk=()=>{const d=path.join(base,fs.readdirSync(base)[0]);return [d,fs.readdirSync(d).filter(n=>/^\d{14}-[0-9a-f]{64}\.pdf$/.test(n)&&n!==empty).sort().map(n=>n.slice(0,-4))];};
function check(value,message){assert.ok(value,message+' '+json({versions:versions().length,index:state().versionIndex,status:state().status,files:stored().length}));checks++;console.log('PASS '+message);}
function* wait(f,label,timeout=10000){const start=Date.now();while(!f()){if(Date.now()-start>timeout)throw Error('Timeout '+label+' '+json(state()));yield;}}
function* delay(ms){const t=Date.now();while(Date.now()-t<ms)yield;}
function* write(data){const count=versions().length;fs.writeFileSync(file,data);yield* wait(()=>versions().length===count+1,'new version');}
function* select(index){api('history',[index]);yield* wait(()=>state().versionIndex===index,'select '+index);}
function* first(){
 yield* wait(()=>state().pages===4,'open');const info=api('inspectStore');
 check(info.enabled&&path.dirname(info.folder)===base&&path.basename(info.folder)===hash(Buffer.from(state().path)),'the store keeps one folder for each PDF, named by the hash of its path');
 let stems=complete();
 check(stems&&stems.length===1&&stored().length===4&&stems[0].endsWith('-'+hash(A)),'the first version is stored as a PDF named by time and content hash, with its word and line caches');
 check(hash(fs.readFileSync(path.join(info.folder,stems[0]+'.pdf')))===hash(A)&&fs.readFileSync(path.join(info.folder,'source-path.txt'),'utf8')===state().path,'the stored PDF holds the exact bytes, and a note names the PDF the folder belongs to');
 check(versions()[0].stored&&!state().status.includes('not saved'),'the version is reported as stored');
 yield* write(B);yield* write(C);stems=complete();const list=versions();
 check(stems&&stems.length===3&&stored().length===10&&list.every(v=>v.stored),'every new version is stored when it is recorded');
 check(list[0].time<list[1].time&&list[1].time<list[2].time&&stems.every((s,i)=>s===String(Math.round(list[i].time)).padStart(14,'0')+'-'+list[i].digest),'file names sort in the order of the versions');
 const m=menu();
 check(json(m.slice(0,8).map(i=>i.title))===json(['Previous Version','Next Version','Latest Version','-','Remove This Version','Remove Version','Remove Earlier Versions…','-']),'the Versions menu offers three ways to remove versions');
 check(m.slice(4,7).every(i=>i.enabled&&i.key==='')&&m[5].items.length===3&&m[5].items[0].title.endsWith('(Latest)')&&m[5].items[0].on,'they are enabled with several versions, have no shortcuts, and the submenu lists every version');
 check(m.length===13&&m[11].title==='-'&&m[12].title.startsWith('Stored on disk: 3 of 3 · ')&&!m[12].enabled,'the menu ends with what is stored on disk');
 check(words(diff().added)==='steady wanted','the latest version is compared with the unwanted edit before it');
 fs.writeFileSync(notes,json({times:times(),digests:digests()}));api('close');
 for(const next of [2,3,4,5]){
  const child=cp.spawnSync(process.env.YY_TEST_NODE||'node',[__filename],{env:{...process.env,YY_STORE_PHASE:String(next),YY_STORE_ROOT:root},encoding:'utf8',timeout:60000});
  process.stdout.write(child.stdout);if(child.status!==0)console.error(child.stderr);
  check(child.status===0,'part '+next+' passes in a new process');checks+=(child.stdout.match(/^PASS /mg)||[]).length;
 }
 api('quit');console.log(json({passed:checks,directory:root}));
}
function* second(){
 const saved=JSON.parse(fs.readFileSync(notes,'utf8')),begin=state();
 check(begin.versionCount===3&&begin.versionIndex===2&&begin.digest===hash(C)&&begin.pages===4&&begin.loads===0,'after a restart the stored versions are back, and the latest is on screen before the file is read');
 check(json(digests())===json(saved.digests)&&json(times())===json(saved.times)&&begin.lastUpdatedMs===saved.times[2]&&begin.status.includes(' · Version 3/3'),'restored versions keep their content hashes and timestamps');
 let list=versions();
 check(!list[0].document&&list[1].words&&!list[1].lines&&list[2].lines,'only what is needed is read: the version on screen in full, the one before it for the comparison');
 check(words(diff().added)==='steady wanted'&&diff().shown===2,'change highlights are back after the restart');
 yield* wait(()=>state().loads>=1,'live read');yield* delay(400);
 check(versions().length===3&&state().versionIndex===2&&stored().length===10,'reading the unchanged file adds no version');
 api('testPosition',[2,1.3,500]);const anchor=state().anchor.text;
 api('historyStep',[-1]);yield* wait(()=>state().versionIndex===1,'previous');
 check(state().digest===hash(B)&&state().lastUpdatedMs===saved.times[1]&&state().status.includes('Viewing version 2/3'),'Previous shows a stored version with its own timestamp');
 check(state().anchor.text===anchor&&state().page===2&&Math.abs(state().zoom-1.3)<.001,'switching to a stored version preserves the reading passage and the zoom');
 check(words(diff().added)==='unwanted'&&words(diff().deleted)==='steady unwanted','a stored version shows what it added and what the next version deletes');
 yield* select(0);check(state().digest===hash(A)&&versions().every(v=>v.lines),'the earliest stored version opens as well');
 api('historyStep',[0]);yield* wait(()=>state().versionIndex===2,'latest');
 yield* write(D);check(state().versionIndex===3&&complete().length===4&&stored().length===13,'new versions are appended to the restored history and stored');
 // 文言：去其误改之版，乃见真改。汉语：用户的场景——删掉中间那次不想要的改动。
 let commits=state().commits,stem=complete()[1];
 check(api('testVersionMenu',['Remove Version',removeTitle(2)])===1&&versions().length===4&&stored().length===13,'choosing a version under Versions → Remove Version asks first and removes nothing yet');
 let asked=alert();
 check(asked.pending&&asked.message==='Remove version 2?'&&asked.info.startsWith('Version 2 of paper α.pdf (')&&asked.info.endsWith(')'+undone),'the confirmation names the version and says that removal cannot be undone');
 check(json(asked.buttons)===json(['Remove','Cancel'])&&asked.destructive&&asked.suppression&&asked.box==='Do not ask again'&&asked.asks,'it offers Remove and Cancel, and a box to stop asking');
 check(answer(1)===1&&!alert().pending&&versions().length===4&&stored().length===13,'Cancel keeps every version');
 api('testVersionMenu',['Remove Version',removeTitle(2)]);answer(0);
 check(json(digests())===json([hash(A),hash(C),hash(D)])&&alert().asks,'Remove removes the chosen version and renumbers the rest, and asks again next time');
 check(state().versionIndex===2&&state().digest===hash(D)&&state().commits===commits&&state().status.includes(' · Version 3/3'),'removing another version leaves the view alone');
 check(!stored().some(n=>n.startsWith(stem))&&complete().length===3&&stored().length===10,'its three files are deleted from the store and the others stay');
 yield* select(1);
 check(words(diff().added)==='wanted'&&diff().addedWords===1&&words(diff().deleted)==='steady','with the middle version gone its neighbours are compared directly, so only the real change is marked');
 api('testPosition',[2,1.3,500]);const passage=state().anchor.text;stem=complete()[1];
 check(api('testVersionMenu',['Remove This Version'])===1&&alert().message==='Remove version 2?'&&versions().length===3,'Versions → Remove This Version asks about the version on screen');
 answer(0,true);
 yield* wait(()=>state().versionCount===2&&state().versionIndex===1,'switch after removal');
 check(state().digest===hash(D)&&state().status.includes(' · Version 2/2')&&!stored().some(n=>n.startsWith(stem)),'removing the version on screen shows the one after it');
 check(state().anchor.text===passage&&state().page===2&&Math.abs(state().zoom-1.3)<.001&&words(diff().added)==='fourth wanted','that switch keeps the reading passage and compares with the remaining earlier version');
 check(!alert().asks&&api('testVersionMenu',['Remove This Version'])===1&&!alert().pending,'after ticking the box, single versions are removed without asking');
 yield* wait(()=>state().versionCount===1&&state().versionIndex===0,'fall back');
 check(state().digest===hash(A)&&state().status.includes(' · Version 1/1')&&diff().addedWords===0&&diff().deletedWords===0,'removing the latest version on screen shows the one before it');
 check(!entry('Remove This Version').enabled&&!entry('Remove Version').enabled&&!entry('Remove Earlier Versions…').enabled&&api('testVersionMenu',['Remove This Version'])===0,'the only version cannot be removed: the three items are disabled');
 api('removeVersion',[0]);api('removeVersion',[7]);check(versions().length===1&&state().pages===4&&stored().length===4,'removing the only version or a version that does not exist does nothing');
 yield* write(D);check(state().versionIndex===1&&state().digest===hash(D)&&words(diff().added)==='fourth wanted','the file on disk comes back as a new version the next time it is read');
 yield* write(B);yield* write(C);yield* select(2);commits=state().commits;
 check(entry('Remove Earlier Versions…').enabled&&api('testVersionMenu',['Remove Earlier Versions…'])===1&&versions().length===4,'Remove Earlier Versions asks even after the box was ticked');
 asked=alert();
 check(asked.pending&&asked.message==='Remove the 2 earlier versions?'&&asked.info.startsWith('Every version of paper α.pdf before the one on screen (')&&asked.info.endsWith(')'+undone)&&!asked.suppression&&asked.destructive,'its confirmation counts the versions and has no box to stop asking');
 check(answer(1)===1&&versions().length===4,'Cancel keeps the earlier versions');
 api('testVersionMenu',['Remove Earlier Versions…']);yield* write(E);
 check(versions().length===5&&state().versionIndex===2&&alert().pending,'a build that arrives while the confirmation is open is collected as usual');
 answer(0);
 check(json(digests())===json([hash(B),hash(C),hash(E)]),'Remove then drops exactly the versions that were asked about, not the positions they had');
 check(state().versionIndex===0&&state().digest===hash(B)&&state().commits===commits&&state().status.includes('Viewing version 1/3')&&!entry('Remove Earlier Versions…').enabled,'the version on screen stays and becomes the first');
 api('removeVersion',[2]);const loads=state().loads;fs.writeFileSync(file,C);yield* wait(()=>state().loads>loads,'read C');yield* delay(400);
 check(json(digests())===json([hash(B),hash(C)])&&state().versionIndex===0,'a later version can be removed while an older one is on screen');
 const size=complete().reduce((n,s)=>n+['pdf','words','lines'].reduce((k,e)=>k+fs.statSync(path.join(folder(),s+'.'+e)).size,0),0);
 check(complete().length===2&&stored().length===7&&versions().reduce((n,v)=>n+v.disk,0)===size&&menu().at(-1).title.startsWith('Stored on disk: 2 of 2 · '),'the store holds exactly the remaining versions and the menu reports their size');
 const ui=api('inspectUI');check(!ui.active&&!ui.visible&&!ui.canBecomeKey&&!ui.canBecomeMain,'version store tests remain hidden and cannot take focus');
 fs.writeFileSync(notes,json({times:times(),digests:digests()}));api('quit');
}
function* third(stems){
 const saved=JSON.parse(fs.readFileSync(notes,'utf8')),begin=state();
 check(begin.versionCount===2&&begin.versionIndex===1&&begin.digest===hash(C)&&begin.loads===0&&json(digests())===json(saved.digests)&&json(times())===json(saved.times),'removals persist: a restart finds exactly the versions that were kept');
 check(words(diff().added)==='steady wanted'&&stored().includes(stems[1]+'.words'),'a missing word cache is rebuilt from the stored PDF');
 check(alert().asks&&!alert().pending,'background tests do not keep the choice to stop asking');
 yield* select(0);
 check(state().digest===hash(B)&&state().textLines===120&&fs.statSync(path.join(folder(),stems[0]+'.lines')).size>7,'a damaged line cache is rebuilt as well');
 check(['stray.txt','123-short.pdf',empty].every(n=>stored().includes(n))&&versions().length===2,'files that are not versions, and empty files, are ignored and left alone');
 api('quit');
}
function* fourth(){
 const begin=state();
 check(begin.versionCount===3&&begin.pages===0&&begin.versionIndex===-1&&begin.status.includes('Version 3 cannot be read from disk'),'a stored PDF whose bytes do not match its hash is not shown');
 yield* wait(()=>state().versionCount===4&&state().versionIndex===3,'live file');
 check(state().digest===hash(C)&&state().pages===4&&diff().addedWords===0,'the file on disk is then read and shown as a new version, and nothing is compared across the unreadable one');
 api('history',[2]);yield* delay(200);
 check(state().versionIndex===3&&state().status.includes('Version 3 cannot be read from disk'),'selecting the unreadable version reports the problem and keeps the view');
 check(api('testVersionMenu',['Remove Version',removeTitle(3)])===1&&alert().message==='Remove version 3?'&&answer(0)===1&&versions().length===3&&!stored().some(n=>n.includes(fake)),'it can be removed like any other version');
 check(state().versionIndex===2&&words(diff().added)==='steady wanted','the comparison then reaches back past an identical copy to the last real change');
 api('quit');
}
function* fifth(){
 yield* wait(()=>state().pages===4,'open');
 check(api('inspectStore').enabled&&!versions()[0].stored&&state().status.includes(' · not saved to disk'),'when the store cannot be written the version is kept for this session and the status says so');
 yield* write(B);
 check(state().versionIndex===1&&words(diff().added)==='unwanted'&&menu().at(-1).title.startsWith('Stored on disk: 0 of 2 · '),'history and comparison still work in memory');
 api('testVersionMenu',['Remove Version',removeTitle(1)]);api('close');api('open',[file]);yield* wait(()=>state().pages===4&&state().versionCount===2,'reopen');
 check(answer(0)===1&&versions().length===2,'a confirmation answered after its document was closed removes nothing');
 api('removeVersion',[0]);check(versions().length===1&&state().versionIndex===0&&state().digest===hash(B),'versions that were not stored can be removed too');
 api('quit');
}
let flow;
if(phase===1){fs.writeFileSync(file,A);flow=first();}
if(phase===2)flow=second();
if(phase===3){const [d,[b,c]]=onDisk();fs.unlinkSync(path.join(d,c+'.words'));fs.writeFileSync(path.join(d,b+'.lines'),'garbage');
 fs.writeFileSync(path.join(d,'stray.txt'),'keep');fs.writeFileSync(path.join(d,empty),'');fs.writeFileSync(path.join(d,'123-short.pdf'),'x');flow=third([b,c]);}
if(phase===4){const [d,stems]=onDisk();fs.writeFileSync(path.join(d,String(Number(stems.at(-1).slice(0,14))+1000).padStart(14,'0')+'-'+fake+'.pdf'),C);flow=fourth();}
if(phase===5){fs.writeFileSync(path.join(root,'blocked'),'a file where the store folder should be');fs.writeFileSync(file,A);flow=fifth();}
let last=0;try{require('../源码/宿主.cjs').run({pdf:file,hook:a=>{api=a;if(Date.now()-last<15)return;last=Date.now();flow.next();}});}catch(error){console.error(error);process.exitCode=1;if(api)api('quit');}
