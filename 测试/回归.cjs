// 文言：造临时卷以验，不动用户之文。汉语：端到端运行真实 Yuyan Wasm-GC、V8、PDFKit 和 vnode 监听。
'use strict';
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict');
const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'阅卷 回归 ')),file=path.join(tmp,'论文 空格 α.pdf');
function pdf(pages,{image=false,revision=''}={}){
 let objs=['','<< /Type /Catalog /Pages 2 0 R >>','', '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'],kids=[];
 pages.forEach((name,p)=>{const index=objs.length;kids.push(index+' 0 R');objs.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents ${index+1} 0 R >>`);
 let data=image?'0.2 0.4 0.8 rg 72 500 350 140 re f':Array.from({length:32},(_,i)=>`BT /F1 12 Tf 72 ${740-i*18} Td (${name} passage ${i}: stable meaningful paragraph for anchoring ${i===0?revision:''}) Tj ET`).join('\n');objs.push(`<< /Length ${Buffer.byteLength(data)} >>\nstream\n${data}\nendstream`);});
 objs[2]=`<< /Type /Pages /Count ${pages.length} /Kids [${kids.join(' ')}] >>`;let text='%PDF-1.4\n',offsets=[0];for(let i=1;i<objs.length;i++){offsets.push(Buffer.byteLength(text));text+=`${i} 0 obj\n${objs[i]}\nendobj\n`;}
 let x=Buffer.byteLength(text);text+=`xref\n0 ${objs.length}\n0000000000 65535 f \n`+offsets.slice(1).map(n=>`${String(n).padStart(10,'0')} 00000 n \n`).join('')+`trailer\n<< /Size ${objs.length} /Root 1 0 R >>\nstartxref\n${x}\n%%EOF\n`;return Buffer.from(text);
}
fs.writeFileSync(file,pdf(['Alpha','Beta','Gamma','Delta']));
let api,checks=0;
function check(ok,message){assert.ok(ok,message);checks++;console.log('PASS '+message);}
function* wait(test,label,timeout=6000){let start=Date.now();while(!test()){if(Date.now()-start>timeout)throw Error('Timeout: '+label+' '+JSON.stringify(api('inspect')));yield;}}
function* delay(ms){let start=Date.now();while(Date.now()-start<ms)yield;}
const state=()=>api('inspect');
function* scenario(){
 yield* wait(()=>state().pages===4,'initial open');check(state().watchers===2,'file and parent watchers installed');
 let descriptors=fs.readdirSync('/dev/fd').length;
 api('testPosition',[2,1.3,500]);yield* delay(150);let original=state();console.log('POSITION',JSON.stringify(original));check(original.anchor.text.includes('Gamma'),'read Gamma passage');
 let c=original.commits;fs.writeFileSync(file,pdf(['Inserted','Alpha','Beta','Gamma','Delta']));yield* wait(()=>state().commits>c,'in-place insertion');let s=state();console.log('INSERT',s);check(s.anchor.text===original.anchor.text,'inserted page keeps same passage');check(s.anchor.page===original.anchor.page+1,'anchor follows pagination');check(Math.abs(s.zoom-original.zoom)<.001,'zoom preserved');
 function pos(a){return Number(a.offset.match(/[-\d.]+/g)[1]);}check(Math.abs(pos(s.anchor)-pos(original.anchor))<3,'anchor viewport offset preserved');
 for(let i=0;i<3;i++){c=state().commits;fs.writeFileSync(file,pdf(['Inserted','Alpha','Beta','Gamma','Delta'],{revision:String(i)}));yield* wait(()=>state().commits>c,'rewrite '+i);}check(true,'repeated in-place rewrites');
 c=state().commits;const oldino=fs.statSync(file).ino;fs.writeFileSync(file+'.new',pdf(['Alpha','Beta','Gamma','Delta']));fs.renameSync(file+'.new',file);yield* wait(()=>state().commits>c,'atomic replacement');check(fs.statSync(file).ino!==oldino,'replacement changes inode');check(state().anchor.text===original.anchor.text,'page deletion preserves passage');
 c=state().commits;const digest=state().digest;fs.unlinkSync(file);yield* delay(450);check(state().digest===digest&&state().pages===4,'delete keeps last valid document');fs.writeFileSync(file,pdf(['Alpha','Beta','Gamma','Delta'],{revision:'recreated'}));yield* wait(()=>state().commits>c,'recreate');check(state().watchers===2,'file watcher rearmed after recreation');
 c=state().commits;const before=state().digest;fs.writeFileSync(file,'%PDF-1.4\npartial');yield* delay(450);check(state().digest===before,'partial write keeps last valid PDF');fs.writeFileSync(file,pdf(['Alpha','Beta','Gamma','Delta'],{revision:'complete'}));yield* wait(()=>state().commits>c,'complete after partial');check(true,'invalid-to-valid retry succeeds');
 c=state().commits;for(let i=0;i<12;i++)fs.writeFileSync(file,pdf(['Alpha','Beta','Gamma','Delta'],{revision:'burst '+i}));yield* wait(()=>state().commits>c,'rapid builds');yield* delay(600);check(state().commits===c+1,'rapid burst coalesces into one commit');
 api('testDelay',[.65]);c=state().commits;let loads=state().loads;
 fs.writeFileSync(file,pdf(['Old async result'],{revision:'old'}));yield* wait(()=>state().loads>loads,'asynchronous read started');yield* delay(100);
 const latest=pdf(['Alpha','Beta','Gamma','Delta'],{revision:'latest wins'});fs.writeFileSync(file,latest);
 yield* wait(()=>state().commits>c,'latest async read');check(state().pages===4,'stale asynchronous result cannot replace the current PDF');
 check(state().digest===require('node:crypto').createHash('sha256').update(latest).digest('hex'),'latest bytes are rendered');api('testDelay',[0]);
 // Change the visible line, retaining its neighboring passage.
 console.log('BEFOREMODE',state());api('testMode',[0]);console.log('AFTERMODE',state());
 let prev=state();const text=pdf(['Alpha','Beta','Gamma','Delta'],{revision:'changed paragraph'}).toString();const match=prev.anchor.text.match(/passage(\d+):/);let changed=pdf(['Alpha','Beta','Gamma','Delta'],{revision:'paragraph '+match?.[1]});
 // Equal-length content replacement keeps the fixture xref offsets valid.
 if(match)changed=Buffer.from(changed.toString().replace('Gamma passage '+match[1]+':','GAMMA passage '+match[1]+':'));
 c=prev.commits;fs.writeFileSync(file,changed);yield* wait(()=>state().commits>c,'visible paragraph change');console.log('AFTEREDIT',state());check(state().anchor.page===2,'changed paragraph remains on relevant page');check(state().mode===0,'single-page display mode survives reload');api('testMode',[1]);
 api('testPosition',[3,1.1,450]);c=state().commits;fs.writeFileSync(file,pdf(['Only']));yield* wait(()=>state().commits>c,'page count shrinks');check(state().page===0,'final-page removal clamps safely');
 c=state().commits;fs.writeFileSync(file,pdf(['one','two'],{image:true}));yield* wait(()=>state().commits>c,'image-only PDF');api('testPosition',[1,1.15,500]);let image=state();c=image.commits;fs.writeFileSync(file,pdf(['one','two','three'],{image:true,revision:'x'}));yield* wait(()=>state().commits>c,'image-only update');check(state().page===image.page&&Math.abs(state().zoom-image.zoom)<.001,'image-only coordinate fallback');
 yield* delay(150);descriptors=fs.readdirSync('/dev/fd').length;for(let i=0;i<8;i++){api('close');check(state().watchers===0,'close releases watchers '+i);api('open',[file]);yield* wait(()=>state().pages===3,'reopen '+i);check(state().watchers===2,'reopen has exactly two watchers '+i);}
 yield* delay(150);console.log('FD',descriptors,fs.readdirSync('/dev/fd').length);check(fs.readdirSync('/dev/fd').length<=descriptors+3,'repeated open/close does not leak file descriptors');
 check(true,'Unicode and spaced paths supported');
 api('testFollow',[1]);c=state().commits;fs.writeFileSync(file,pdf(['Changed at beginning','two','three']));yield* wait(()=>state().commits>c,'follow edits');check(state().page===0,'explicit follow mode goes to first changed region');api('testFollow',[0]);
 // Test watcher recovery when even the containing directory disappears.
 const moved=tmp+' moved';c=state().commits;fs.renameSync(tmp,moved);yield* delay(300);fs.mkdirSync(tmp);fs.writeFileSync(file,pdf(['Restored directory']));yield* wait(()=>state().commits>c,'parent directory recreated');console.log('RECOVERY',state());check(state().watchers===2&&state().pages===1,'directory and file watches recover');
 api('quit');console.log(JSON.stringify({passed:checks,temporaryDirectory:tmp,engine:process.versions.v8}));
}
let flow=scenario(),last=0;
try{require('../源码/宿主.cjs').run({pdf:file,hook:a=>{api=a;if(Date.now()-last<15)return;last=Date.now();flow.next();}});}catch(e){console.error(e);process.exitCode=1;if(api)api('quit');}
module.exports={pdf};
