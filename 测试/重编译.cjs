// 文言：实编 LaTeX，验寻锚与源卷互通。汉语：真实 latexmk/SyncTeX 集成测试，所有文件均在临时目录。
'use strict';
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),cp=require('node:child_process'),assert=require('node:assert/strict');
const dir=fs.mkdtempSync(path.join(os.tmpdir(),'阅卷 LaTeX '));const tex=path.join(dir,'paper.tex'),pdf=path.join(dir,'paper.pdf');
function source(insert=false,edit=false){let sections=['Alpha','Beta','Gamma','Delta'];if(insert)sections.unshift('Inserted');return '\\documentclass{article}\n\\usepackage[margin=1in]{geometry}\n\\begin{document}\n'+sections.map(name=>'\\section*{'+name+'}\n'+Array.from({length:20},(_,i)=>`${name} paragraph ${i}: This is a stable passage to identify reading position in our compiled paper. ${edit&&name==='Gamma'&&i===6?'The equation has now changed.':''}\\par\n\\medskip`).join('\n')+'\n\\newpage\n').join('')+'\\end{document}\n';}
function build(s){fs.writeFileSync(tex,s);const r=cp.spawnSync('/opt/homebrew/bin/latexmk',['-pdf','-synctex=1','-interaction=nonstopmode','-halt-on-error','paper.tex'],{cwd:dir,encoding:'utf8'});assert.equal(r.status,0,r.stdout+r.stderr);}
build(source());
let api,checks=0;const state=()=>api('inspect');function check(v,m){assert.ok(v,m);checks++;console.log('PASS '+m);}
function* wait(f,label,timeout=10000){let start=Date.now();while(!f()){if(Date.now()-start>timeout)throw Error('Timeout '+label+' '+JSON.stringify(state()));yield;}}
function* delay(ms){const s=Date.now();while(Date.now()-s<ms)yield;}
function* scenario(){
 yield* wait(()=>state().pages===4,'initial latex PDF');api('testPosition',[2,1.25,500]);yield* delay(150);let before=state();check(before.anchor.text.includes('Gamma'),'real LaTeX visible passage captured');
 build(source(true));yield* wait(()=>state().pages===5,'latexmk insertion');let after=state();check(after.anchor.text===before.anchor.text,'latexmk page insertion preserves text');check(after.anchor.page===before.anchor.page+1,'latexmk anchor follows page insertion');check(Math.abs(after.zoom-before.zoom)<.001,'latexmk preserves zoom');
 let c=after.commits;build(source(false,true));yield* wait(()=>state().commits>c,'latexmk deletion and edit');check(state().anchor.page===2,'latexmk deletion and paragraph edit preserve region');
 const line=fs.readFileSync(tex,'utf8').split('\n').findIndex(s=>s.includes('Delta paragraph 4:'))+1;
 // Request through the actual separate-process command-line interface.
 const command=cp.spawnSync(path.resolve(__dirname,'../运行.sh'),['--navigate',pdf,tex,String(line)],{encoding:'utf8'});assert.equal(command.status,0,command.stderr);
 yield* wait(()=>state().status.startsWith('SyncTeX ·'),'CLI SyncTeX navigation');check(state().page===3,'CLI source line navigates to correct PDF page');
 fs.unlinkSync(path.join(dir,'paper.synctex.gz'));api('navigate',[tex,line]);yield* wait(()=>state().status.includes('unavailable'),'missing synctex');check(state().pages===4,'missing SyncTeX never prevents viewing');
 api('quit');console.log(JSON.stringify({passed:checks,directory:dir}));
}
const flow=scenario();let last=0;
try{require('../源码/宿主.cjs').run({pdf,hook:a=>{api=a;if(Date.now()-last<15)return;last=Date.now();flow.next();}});}catch(e){console.error(e);process.exitCode=1;if(api)api('quit');}
