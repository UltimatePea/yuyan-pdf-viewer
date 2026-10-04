'use strict';
process.env.YY_VIEWER_BACKGROUND='1';
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict');
const {pdf}=require('./夹具.cjs');const root=fs.mkdtempSync(path.join(os.tmpdir(),'阅卷 搜索 '));
process.env.YY_JUMP_POINTS_DIRECTORY=path.join(root,'points');
const file=path.join(root,'search.pdf'),other=path.join(root,'other.pdf');
fs.writeFileSync(file,pdf(['Alpha','Beta','Alpha']));fs.writeFileSync(other,pdf(['Alpha']));
let api,checks=0;const call=(id,op,args=[])=>api('window',[id,op,args]);
const state=id=>call(id,'inspect'),search=id=>call(id,'inspectSearch');
function check(value,label){assert.ok(value,label);checks++;console.log('PASS '+label);}
function* wait(fn,label){let start=Date.now();while(!fn()){if(Date.now()-start>10000)throw Error('Timeout '+label);yield;}}
function* scenario(){
 const one=api('inspectWindows')[0].id;yield* wait(()=>state(one).pages===3,'initial');
 let s=search(one);check(s.count===0&&!s.previousEnabled&&!s.nextEnabled,'search navigation is disabled before a query');
 call(one,'testSearch',['alpha']);s=search(one);
 check(s.count===64&&s.highlighted===64,'case-insensitive search highlights every occurrence');
 check(s.pages.filter(p=>p===0).length===32&&s.pages.filter(p=>p===2).length===32,'highlights cover matches on every matching page');
 check(s.index===0&&s.selection.toLowerCase()==='alpha','typing selects the first result');
 check(s.previousEnabled&&s.nextEnabled,'both search buttons are enabled for matches');
 check(s.previousY===s.nextY&&Math.abs(s.searchY-s.nextY)<=2,'search and both navigation buttons stay in the same toolbar row');
 call(one,'testSearchStep',[1]);s=search(one);check(s.index===1&&s.highlighted===64,'Next advances while keeping all matches highlighted');
 call(one,'testSearchStep',[-1]);check(search(one).index===0,'Previous returns to the preceding result');
 call(one,'testSearchStep',[-1]);s=search(one);check(s.index===63&&state(one).page===2,'Previous wraps from first to last match');
 call(one,'testSearchStep',[1]);check(search(one).index===0&&state(one).page===0,'Next wraps from last to first match');
 check(search(one).tooltip==='Match 1 of 64','search tooltip reports active result and total');
 call(one,'testSearch',['Alpha passage 10']);s=search(one);check(s.count===2&&s.highlighted===2&&s.index===0,'changing a query replaces all old highlights');
 call(one,'testSearchStep',[1]);check(search(one).index===1&&state(one).page===2,'Next reaches the result on a later page');
 call(one,'testSearch',['not found']);s=search(one);check(s.count===0&&s.highlighted===0&&!s.previousEnabled&&!s.nextEnabled,'no-result query clears highlights and disables navigation');
 check(s.selection===''&&s.tooltip==='0 matches','no-result query clears the old active selection');
 call(one,'testSearchStep',[1]);call(one,'testSearchStep',[-1]);check(search(one).index===-1,'no-result navigation is harmless');
 call(one,'testSearch',['Beta passage 4']);check(search(one).count===1,'single-result query finds the exact phrase');
 call(one,'testSearchStep',[1]);call(one,'testSearchStep',[-1]);check(search(one).index===0&&search(one).highlighted===1,'both buttons safely wrap a single match');
 call(one,'testSearch',['']);s=search(one);check(s.count===0&&s.highlighted===0&&s.selection==='','clearing the query clears all search highlights and selection');
 call(one,'testSearch',['Alpha']);const two=api('openNew',[other]);yield* wait(()=>state(two).pages===1,'second window');
 check(search(two).count===0&&search(one).count===64,'search state is independent between windows');
 call(two,'testSearch',['passage']);check(search(two).count===32&&search(one).query==='Alpha','typing in another window leaves the first search intact');
 fs.writeFileSync(file,pdf(['Alpha','Beta','Alpha','Alpha']));yield* wait(()=>state(one).pages===4,'refresh');
 check(search(one).query==='Alpha'&&search(one).highlighted===96,'refresh recomputes all highlights for the retained query');
 check(search(one).index===-1,'refresh does not automatically navigate away from the reading position');
 call(one,'testSearchStep',[1]);check(search(one).index===0,'Next starts from a valid result after refresh');
 call(one,'history',[0]);yield* wait(()=>state(one).versionIndex===0,'old version');
 check(search(one).count===64&&search(one).highlighted===64,'version changes rebuild highlights from the displayed historical PDF');
 call(one,'historyStep',[0]);yield* wait(()=>state(one).versionIndex===1,'latest');check(search(one).count===96,'returning to Latest restores current search results');
 call(one,'close');s=search(one);check(s.count===0&&s.highlighted===0&&!s.nextEnabled,'closing a document clears search results');
 call(one,'open',[other]);yield* wait(()=>state(one).pages===1,'replacement');check(search(one).count===32,'reopening a document recomputes search results without stale selections');
 const ui=call(one,'inspectUI');check(!ui.active&&!ui.visible&&!ui.canBecomeKey&&!ui.canBecomeMain,'search tests remain hidden and cannot take focus');
 api('quit');console.log(JSON.stringify({passed:checks,directory:root}));
}
let last=0,flow=scenario();try{require('../源码/宿主.cjs').run({pdf:file,hook:a=>{api=a;if(Date.now()-last<15)return;last=Date.now();flow.next();}});}catch(error){console.error(error);process.exitCode=1;if(api)api('quit');}
