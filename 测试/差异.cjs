// 文言：增者绿，将删者红；行号、断词、越页之移不为异。汉语：真实 Wasm-GC/PDFKit 版本差异提示回归，后台运行不抢焦点。
'use strict';
process.env.YY_VIEWER_BACKGROUND='1';
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict');
const {layout}=require('./夹具.cjs');const root=fs.mkdtempSync(path.join(os.tmpdir(),'阅卷 差异 '));
process.env.YY_JUMP_POINTS_DIRECTORY=path.join(root,'points');
const file=path.join(root,'paper.pdf'),other=path.join(root,'pages.pdf');
// 文言：每行左缘置小字行号，页末置页码。汉语：模拟 lineno 的页边行号、页眉页脚和页码。
function sheet(texts,{first=1,header,footer,number}={}){
 const lines=[];if(header)lines.push([72,762,9,header]);
 texts.forEach((text,i)=>{const y=730-i*18;lines.push([40,y,6,String(first+i)]);lines.push([72,y,12,text]);});
 if(footer)lines.push([72,58,9,footer]);if(number)lines.push([300,40,10,String(number)]);return lines;
}
const one=layout([sheet(['Alpha begins the first paragraph here','Beta continues with stable words today','Gamma holds an obsolete remark inside','Delta closes the opening well-known section now'],{number:1})]);
const two=layout([sheet(['Alpha begins the first paragraph here','Fresh sentence inserted between lines','Beta continues with steady words today','Gamma holds remark inside','Delta closes the opening well-known section now'],{number:1})]);
const three=layout([sheet(['Alpha begins the first paragraph here','Fresh sentence inserted between lines','Beta continues with steady words today','Gamma holds remark inside','Delta closes the well-known section now indeed'],{number:1})]);
const rebroken=layout([sheet(['Alpha begins the first para-','graph here Fresh sentence in-','serted between lines Beta continues','with steady words today Gamma holds','remark inside Delta closes the well-','known section now indeed'],{first:41,number:1})]);
const body=['Alpha line one of the body','Beta line two of the body','Gamma line three of the body','Delta line four of the body','Epsilon line five of the body','Zeta line six of the body','Eta line seven of the body'];
const furniture={header:'Running Header Title',footer:'Footer note of the paper'};
const paged=layout([sheet(body.slice(0,5),{...furniture,number:1}),sheet(body.slice(5),{...furniture,first:6,number:2})]);
const shifted=layout([sheet([body[0],'Brand new line appears',...body.slice(1,4)],{...furniture,number:1}),sheet(body.slice(4),{...furniture,first:6,number:2})]);
// 文言：奇偶页眉相间，增一页则其后诸页页眉皆易。汉语：奇偶页交替的页眉；插入一页后其后每页的页眉都不同。
const third=path.join(root,'headers.pdf'),titles=['Alpha','Beta','Gamma','Delta','Epsilon','Zeta'];
const leaf=(text,index)=>sheet([text+' paragraph opens page','then '+text+' closes it'],{header:index%2?'Author Names Here':'Paper Title Here',footer:'Conference footer line',first:1+2*index,number:index+1});
const alternating=layout(titles.map(leaf)),inserted=layout(['Alpha','Entirely fresh',...titles.slice(1)].map(leaf));
let api,checks=0;const state=()=>api('inspect'),versions=()=>api('inspectVersions'),diff=()=>api('inspectDiff');
const texts=list=>list.map(item=>item.text.replace(/\s+/g,' ').trim());
function check(value,message){assert.ok(value,message+' '+JSON.stringify(diff()));checks++;console.log('PASS '+message);}
function same(actual,expected,message){assert.deepEqual(actual,expected,message);checks++;console.log('PASS '+message);}
function* wait(f,label,timeout=10000){const start=Date.now();while(!f()){if(Date.now()-start>timeout)throw Error('Timeout '+label+' '+JSON.stringify(state()));yield;}}
function* select(index){api('history',[index]);yield* wait(()=>state().versionIndex===index,'history selection');}
function* write(target,data){const count=versions().length;fs.writeFileSync(target,data);yield* wait(()=>versions().length===count+1,'new version');}
function* scenario(){
 yield* wait(()=>state().pages===1,'open');
 check(diff().enabled&&diff().menu,'change highlights are on by default and the menu item is checked');
 check(!diff().added.length&&!diff().deleted.length&&!state().status.includes(' +'),'the first version has no change highlights');
 yield* write(file,two);
 same(texts(diff().added),['Fresh sentence inserted between lines','steady'],'the latest version highlights the inserted line and the replaced word');
 check(diff().addedWords===6&&!diff().deleted.length&&diff().shown===2,'additions are counted in words and shown in the PDF view');
 check(state().status.includes(' · +6 ·')&&!state().status.includes('−'),'the status reports the added words');
 api('historyStep',[-1]);yield* wait(()=>state().versionIndex===0,'previous');
 same(texts(diff().deleted),['stable','an obsolete'],'the previous version highlights the words the next version deletes');
 check(!diff().added.length&&diff().deletedWords===3&&state().status.includes(' · −3 ·'),'the first version has deletions only and the status reports them');
 yield* write(file,three);check(state().versionIndex===0,'a new build does not leave the version being read');
 same(texts(diff().deleted),['stable','an obsolete'],'deletions still compare with the next version, not the newest');
 yield* select(1);
 same([texts(diff().added),texts(diff().deleted)],[['Fresh sentence inserted between lines','steady'],['opening']],'a middle version shows its additions and its forward deletions together');
 check(state().status.includes(' · +6 −1 ·')&&diff().shown===3,'the status reports both counts for a middle version');
 yield* select(2);same([texts(diff().added),texts(diff().deleted)],[['indeed'],[]],'the newest version shows only its additions');
 api('testSearch',['the']);const matches=api('inspectSearch');
 check(matches.count===2&&matches.highlighted===2&&diff().shown===1,'search highlights and change highlights are shown together');
 api('testDiffMenu');
 check(!diff().enabled&&!diff().menu&&!diff().added.length&&diff().shown===0,'the menu item turns change highlights off');
 check(api('inspectSearch').highlighted===2&&!state().status.includes(' +'),'turning highlights off keeps search highlights and clears the status counts');
 yield* select(1);check(!diff().added.length&&!diff().deleted.length,'no highlights appear on other versions while turned off');
 api('testDiffMenu');
 same([texts(diff().added),texts(diff().deleted)],[['Fresh sentence inserted between lines','steady'],['opening']],'turning highlights on restores them for the version being read');
 api('testSearch',['']);yield* select(2);
 yield* write(file,rebroken);
 same(texts(diff().added),['indeed'],'a rebuild that only renumbers, rebreaks and rehyphenates lines adds no words and keeps the highlights of the last change');
 check(diff().addedWords===1&&state().status.includes(' · +1 ·')&&!diff().deleted.length,'the status still counts the last change after such a rebuild');
 yield* select(2);check(!diff().deleted.length&&texts(diff().added).join()==='indeed','renumbered lines and rebroken words are not deletions');
 yield* select(1);same(texts(diff().deleted),['opening'],'deletions compare with the next version whose words differ');
 api('close');api('open',[file]);yield* wait(()=>state().versionCount===4&&state().versionIndex===3,'reopen');
 same(texts(diff().added),['indeed'],'reopening rebuilds the highlights of the newest version');
 yield* select(1);same(texts(diff().added),['Fresh sentence inserted between lines','steady'],'highlights are rebuilt from history after reopening');
 fs.writeFileSync(other,paged);const second=api('openNew',[other]);const call=(op,args=[])=>api('window',[second,op,args]);
 yield* wait(()=>call('inspect').pages===2,'second window');
 fs.writeFileSync(other,shifted);yield* wait(()=>call('inspect').versionCount===2,'second version');
 same(texts(call('inspectDiff').added),['Brand new line appears'],'a line pushed past the footer and header onto the next page is not an addition');
 call('historyStep',[-1]);yield* wait(()=>call('inspect').versionIndex===0,'second previous');
 check(!call('inspectDiff').deleted.length,'a line pushed onto the next page is not a deletion');
 call('testDiff',[0]);
 check(!api('window',[api('inspectWindows')[0].id,'inspectDiff',[]]).menu&&!call('inspectDiff').menu,'the setting applies to every window');
 call('testDiff',[1]);call('historyStep',[1]);yield* wait(()=>call('inspect').versionIndex===1,'second latest');
 same(texts(call('inspectDiff').added),['Brand new line appears'],'turning the setting back on restores highlights in every window');
 fs.writeFileSync(third,alternating);call('open',[third]);yield* wait(()=>call('inspect').pages===6&&call('inspect').versionCount===1,'alternating headers');
 fs.writeFileSync(third,inserted);yield* wait(()=>call('inspect').versionCount===2&&call('inspect').pages===7,'inserted page');
 same(texts(call('inspectDiff').added),['Entirely fresh paragraph opens page','then Entirely fresh closes it'],'after an inserted page, alternating running headers and footers are not marked');
 call('historyStep',[-1]);yield* wait(()=>call('inspect').versionIndex===0,'headers previous');
 check(!call('inspectDiff').deleted.length,'the shifted pages of the older version have no deletions');
 const ui=call('inspectUI');check(!ui.active&&!ui.visible&&!ui.canBecomeKey&&!ui.canBecomeMain,'change highlight tests remain hidden and cannot take focus');
 api('quit');console.log(JSON.stringify({passed:checks,directory:root}));
}
fs.writeFileSync(file,one);
let last=0,flow=scenario();try{require('../源码/宿主.cjs').run({pdf:file,hook:a=>{api=a;if(Date.now()-last<15)return;last=Date.now();flow.next();}});}catch(error){console.error(error);process.exitCode=1;if(api)api('quit');}
