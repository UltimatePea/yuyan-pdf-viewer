// 文言：左条示全卷之改，上下二钮逐处而览。汉语：真实 Wasm-GC/PDFKit 概览条与“上一处/下一处”回归，后台运行不抢焦点。
'use strict';
process.env.YY_VIEWER_BACKGROUND='1';
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict');
const {layout}=require('./夹具.cjs');const root=fs.mkdtempSync(path.join(os.tmpdir(),'阅卷 改处 '));
process.env.YY_JUMP_POINTS_DIRECTORY=path.join(root,'points');const file=path.join(root,'paper.pdf');
// 文言：六页，页三十行；改其四处。汉语：六页，每页三十行；第二版改动四处：第 2 页一处，第 4 页两处（其一跨相邻两行），第 6 页靠近页末一处。
const sheet=(p,changed={})=>Array.from({length:30},(_,i)=>[72,730-i*18,12,`Page ${p} line ${i} ${changed[i]||'steady'} words here`]);
const one=layout([0,1,2,3,4,5].map(p=>sheet(p)));
const two=layout([sheet(0),sheet(1,{5:'altered'}),sheet(2),sheet(3,{3:'altered',4:'altered',20:'altered'}),sheet(4),sheet(5,{28:'altered'})]);
let api,checks=0;const state=()=>api('inspect'),changes=()=>api('inspectChanges'),rect=s=>(s.match(/-?[\d.]+/g)||[]).map(Number);
function check(value,message){assert.ok(value,message+' '+JSON.stringify({...changes(),marks:changes().marks.length,page:state().page}));checks++;console.log('PASS '+message);}
function same(actual,expected,message){assert.deepEqual(actual,expected,message);checks++;console.log('PASS '+message);}
function* wait(f,label,timeout=10000){const start=Date.now();while(!f()){if(Date.now()-start>timeout)throw Error('Timeout '+label+' '+JSON.stringify(state()));yield;}}
const step=n=>{api('testChangeStep',[n]);return changes();},at=c=>[c.index,state().page],placed=c=>Math.abs(c.line-.3)<.03;
function* scenario(){
 yield* wait(()=>state().pages===6,'open');let c=changes();
 check(!c.sets.length&&!c.marks.length&&!c.enabled&&c.buttonsHidden&&!c.menuEnabled,'a document with one version has no changes to visit and hides the two buttons');
 check(!c.stripHidden&&rect(c.strip)[0]===0&&rect(c.strip)[2]===14&&rect(c.pdf)[0]===14,'the overview strip stands at the left edge beside the PDF');
 step(1);check(changes().index===-1&&state().page===0,'Next does nothing while there are no changes');
 const count=api('inspectVersions').length;fs.writeFileSync(file,two);yield* wait(()=>api('inspectVersions').length===count+1&&state().versionIndex===1,'second version');c=changes();
 same(c.sets.map(s=>[s.page,s.added,s.deleted]),[[1,1,0],[3,2,0],[3,1,0],[5,1,0]],'changes are grouped into four sets in reading order; two changed lines next to each other are one set');
 check(c.marks.length===5&&c.marks.every(m=>!m[2]&&m[0]<m[1])&&c.enabled&&!c.buttonsHidden&&c.menuEnabled,'the strip marks every added range and the buttons become available');
 check(c.marks.every((m,i)=>i===0||c.marks[i-1][0]<m[0])&&c.marks[0][0]>1/6&&c.marks[4][1]<1,'marks lie at the position of their page and line in the document');
 check(c.visible[0]<c.visible[1]&&c.visible[0]>=0&&c.visible[1]<=1,'the strip shows the visible part of the document');
 const tool=api('inspectToolbar');check(tool.frames.length===16,'the toolbar reports the two change buttons beside the version controls');
 c=step(1);same(at(c),[0,1],'Next goes to the first change at or below the top of the view');
 check(placed(c)&&state().status.includes(' · Change 1/4 ·'),'the change is placed three tenths below the top of the view and the status counts it');
 check(c.current[0]>0&&c.current[0]<c.current[1]&&c.current[0]>=c.visible[0]&&c.current[1]<=c.visible[1],'the strip outlines the set just visited inside the visible part');
 c=step(1);same(at(c),[1,3],'Next goes on to the following set');check(placed(c),'each visited set is placed at the same height');
 c=step(1);same(at(c),[2,3],'two sets on one page are visited separately');
 c=step(1);same(at(c),[3,5],'Next reaches the last set near the end of the document');check(c.line>.25&&c.line<.95,'the last set is visible where the document cannot scroll further');
 c=step(1);same(at(c),[0,1],'Next wraps from the last set to the first');
 c=step(-1);same(at(c),[3,5],'Previous wraps from the first set to the last');
 c=step(-1);same(at(c),[2,3],'Previous goes back one set');
 const zoom=state().zoom;api('testPosition',[4,zoom,700]);c=step(1);same(at(c),[3,5],'after scrolling away, Next starts from what is in view');
 api('testPosition',[4,zoom,700]);c=step(-1);same(at(c),[2,3],'after scrolling away, Previous takes the last change above the view');
 api('testStripClick',[.02]);api('testPosition',[3,zoom,560]);c=step(1);same(at(c),[1,3],'a change that is already in view is visited first');
 api('testPosition',[3,zoom,600]);c=step(1);same(at(c),[2,3],'after a small scroll that keeps the visited set in view, Next goes on to the following set');
 api('testPosition',[0,zoom,700]);api('testChangeMenu',[1]);same(at(changes()),[0,1],'the Next Change menu item does the same');
 api('testChangeMenu',[-1]);same(at(changes()),[3,5],'the Previous Change menu item does the same');
 check(api('testChangeShortcut',[1])&&at(changes()).join()==='0,1','the menu bar handles ⌥⌘↓ as Next Change');
 check(api('testChangeShortcut',[-1])&&at(changes()).join()==='3,5','the menu bar handles ⌥⌘↑ as Previous Change');
 api('testPosition',[2,zoom*2.2,500]);const x=changes().scrollX;c=step(1);
 check(x>1&&Math.abs(c.scrollX-x)<1&&at(c).join()==='1,3','going to a change keeps the horizontal scroll position when zoomed in');
 api('testStripClick',[c.sets[2].fraction+.0005]);same(at(changes()),[2,3],'clicking a mark on the strip goes to that set');
 api('testStripClick',[.02]);c=changes();check(c.index===-1&&state().page===0&&c.current[1]===0&&!state().status.includes('Change'),'clicking the strip elsewhere goes to that place in the document');
 api('testStripClick',[.999]);check(state().page===5,'clicking the bottom of the strip goes to the end');
 api('testMode',[0]);api('testPosition',[0,zoom,700]);c=step(1);same(at(c),[0,1],'Next works in single-page display');c=step(1);same(at(c),[1,3],'single-page display shows the page of each set');c=step(-1);same(at(c),[0,1],'Previous works in single-page display');api('testMode',[1]);
 api('historyStep',[-1]);yield* wait(()=>state().versionIndex===0,'previous version');c=changes();
 same(c.sets.map(s=>[s.page,s.added,s.deleted]),[[1,0,1],[3,0,2],[3,0,1],[5,0,1]],'an older version lists the sets that the next version deletes');
 check(c.marks.length===5&&c.marks.every(m=>m[2])&&c.index===-1,'its marks are deletions and no set is current after a version change');
 api('testPosition',[0,zoom,700]);c=step(1);same(at(c),[0,1],'Next visits deletions in an older version');
 api('testDiff',[0]);c=changes();
 check(c.stripHidden&&c.buttonsHidden&&!c.sets.length&&!c.marks.length&&!c.menuEnabled&&rect(c.pdf)[0]===0&&rect(c.pdf)[2]===rect(api('inspectToolbar').bounds)[2],'turning highlights off removes the strip and the buttons and gives the PDF the full width');
 step(1);api('testChangeMenu',[1]);api('testChangeShortcut',[1]);check(changes().index===-1&&state().page===1,'the buttons, the menu items and the shortcuts do nothing while highlights are off');
 api('testDiff',[1]);c=changes();check(!c.stripHidden&&!c.buttonsHidden&&c.sets.length===4&&c.marks.length===5&&rect(c.pdf)[0]===14,'turning highlights on restores the strip, the buttons and the sets');
 api('close');c=changes();check(!c.sets.length&&!c.marks.length&&!c.enabled&&c.buttonsHidden,'closing the document clears the strip and hides the buttons');
 const ui=api('inspectUI');check(!ui.active&&!ui.visible&&!ui.canBecomeKey&&!ui.canBecomeMain,'change navigation tests remain hidden and cannot take focus');
 api('quit');console.log(JSON.stringify({passed:checks,directory:root}));
}
fs.writeFileSync(file,one);
let last=0,flow=scenario();try{require('../源码/宿主.cjs').run({pdf:file,hook:a=>{api=a;if(Date.now()-last<15)return;last=Date.now();flow.next();}});}catch(error){console.error(error);process.exitCode=1;if(api)api('quit');}
