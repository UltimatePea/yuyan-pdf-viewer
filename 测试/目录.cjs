// 文言：纲目列于左栏，击之则至，随读而移，可隐可宽。汉语：目录栏回归。真实 Wasm-GC/PDFKit，后台运行不抢焦点。
'use strict';
process.env.YY_VIEWER_BACKGROUND='1';
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict');
const {layout}=require('./夹具.cjs');const root=fs.mkdtempSync(path.join(os.tmpdir(),'阅卷 目录 '));
process.env.YY_JUMP_POINTS_DIRECTORY=path.join(root,'points');const file=path.join(root,'paper.pdf');
// 文言：六页，页三十行。纲目三层，有汉字之题、整页之的、无的之条，末条近卷尾。
// 汉语：六页，每页三十行。目录三层：含非 ASCII 标题、以整页为目的地的条目（Appendix）、没有目的地的条目（Broken）、靠近文档末尾的条目。
const sheet=(p,word)=>Array.from({length:30},(_,i)=>[72,730-i*18,12,`Page ${p} line ${i} ${word} words here`]);
const pages=word=>[0,1,2,3,4,5].map(p=>sheet(p,word));
const tree=({proofs='Formal Proofs',extra=[]}={})=>[
 {title:'Introduction',page:0,y:760},
 {title:'Background',page:1,y:760,children:[{title:proofs,page:1,y:400},{title:'Logical Frameworks',page:2,y:600,children:[{title:'Deep Item',page:2,y:300}]}]},
 {title:'第三章 Results',page:3,y:760,children:[{title:'Evaluation',page:4,y:500}]},
 {title:'Appendix',page:5},{title:'Broken'},{title:'Closing Remarks',page:5,y:120},...extra];
const many=Array.from({length:60},(_,i)=>({title:'Extra '+i,page:5,y:60}));
const plain=layout(pages('steady')),first=layout(pages('steady'),tree()),second=layout(pages('second'),tree()),third=layout(pages('third'),tree({proofs:'Formal Verification',extra:[{title:'Index',page:5,y:60}]}));
const long=layout(pages('long'),tree({extra:many})),longer=layout(pages('longer'),tree({extra:many}));
// 默认栏宽 W；其右缘 6 点为可拖动的分隔线，概览条宽 14 点。
const W=260,panel=[0,30,W-6,738],edge=[W-6,30,6,738],strip=[W,30,14,738],body=[W+14,30,966-W,738];
let api,checks=0;const json=JSON.stringify,state=()=>api('inspect'),outline=()=>api('inspectOutline'),rect=s=>(s.match(/-?[\d.]+/g)||[]).map(Number);
const titles=()=>outline().rows.map(r=>r.title),row=title=>titles().indexOf(title),chosen=()=>{const o=outline();return o.selected<0?null:o.rows[o.selected].title;};
function check(value,message){const o=outline();assert.ok(value,message+' '+json({selected:o.selected,rows:o.rows.map(r=>r.title),top:[o.topPage,Math.round(o.topY)],pdf:o.pdf,frame:o.frame,zoom:state().zoom,page:state().page}));checks++;console.log('PASS '+message);}
function* wait(f,label,timeout=10000){const start=Date.now();while(!f()){if(Date.now()-start>timeout)throw Error('Timeout '+label+' '+json(state()));yield;}}
function* write(data){const count=api('inspectVersions').length;fs.writeFileSync(file,data);yield* wait(()=>api('inspectVersions').length===count+1&&state().versionIndex===count,'new version');}
const click=title=>api('testOutlineClick',[row(title)]),isOpen=title=>outline().rows[row(title)].expanded;
// 文言：击其钮以开阖。汉语：通过真正的展开三角按钮展开或折叠，与用户操作相同。
const expand=(title,open)=>{if(isOpen(title)!==open)assert.equal(api('testOutlineDisclosure',[row(title)]),1,'disclosure button of '+title);};
function* scenario(){
 yield* wait(()=>state().pages===6,'open');let o=outline();const wide=state().zoom;
 check(o.shown&&o.menuOn&&!o.visible&&o.edgeHidden&&!o.rows.length&&!o.menuEnabled&&json(rect(o.pdf))===json([14,30,966,738]),'a PDF without an outline shows no panel, and View → Outline is disabled');
 yield* write(first);o=outline();
 check(o.visible&&!o.edgeHidden&&o.menuEnabled&&o.menuOn&&o.key==='s'&&o.entries===9,'the panel appears when a version of the PDF has an outline');
 check(json(rect(o.frame))===json(panel)&&json(rect(o.edge))===json(edge)&&json(rect(o.strip))===json(strip)&&json(rect(o.pdf))===json(body),'from the left edge: the outline, its edge, the change bar, the PDF');
 const narrow=wide*(966-W-28)/(966-28);check(Math.abs(state().zoom-narrow)<.002,'fit-to-width follows the narrower PDF area');
 check(json(o.rows.map(r=>[r.title,r.page,r.level]))===json([['Introduction','1',0],['Background','2',0],['Formal Proofs','2',1],['Logical Frameworks','3',1],['第三章 Results','4',0],['Evaluation','5',1],['Appendix','6',0],['Broken','',0],['Closing Remarks','6',0]]),'rows show titles and page numbers; an entry without a destination has no page number');
 check(o.rows[1].expanded&&o.rows[4].expanded&&o.rows[3].expandable&&!o.rows[3].expanded&&!o.rows[0].expandable,'top-level entries start expanded and deeper ones closed, as this PDF marks them');
 click('Formal Proofs');o=outline();
 check(state().page===1&&o.topPage===1&&Math.abs(o.topY-400)<1.5&&chosen()==='Formal Proofs'&&!o.focused,'clicking a row puts its place at the top of the view and selects it; the outline does not take the keyboard');
 const zoom=state().zoom,at=(page,y)=>api('testPosition',[page,zoom,y]);
 at(2,500);check(chosen()==='Formal Proofs','while the next heading is still below the top of the view, the earlier entry stays selected');
 at(2,330);check(chosen()==='Logical Frameworks','scrolling past a heading selects its entry');
 at(2,20);check(chosen()==='Logical Frameworks'&&row('Deep Item')<0,'a place inside a closed entry selects that entry');
 expand('Logical Frameworks',true);check(chosen()==='Deep Item'&&outline().rows[row('Logical Frameworks')].expanded,'opening the entry selects the exact section');
 check(api('testOutlineMouse',[row('第三章 Results')])===1,'a row takes a real mouse click');o=outline();
 check(state().page===3&&o.topPage===3&&Math.abs(o.topY-760)<1.5&&chosen()==='第三章 Results'&&!o.focused,'the mouse click jumps to the place of that row, here one with a title outside ASCII, and leaves the keyboard with the PDF');
 click('Appendix');o=outline();check(state().page===5&&o.topPage===5&&o.topY>780&&chosen()==='Appendix','an entry that points at a whole page goes to the top of that page');
 const before=json([state().page,outline().topPage,outline().topY]);click('Broken');check(json([state().page,outline().topPage,outline().topY])===before&&chosen()==='Appendix','an entry without a destination does not move the view or take the selection');
 click('Closing Remarks');o=outline();check(o.topPage===5&&o.topY>200&&chosen()==='Closing Remarks','an entry near the end stays selected although the document cannot scroll that far');
 at(5,400);check(chosen()==='Appendix','after scrolling, the selection follows the reading place again');
 click('Formal Proofs');expand('Background',false);
 check(json(titles())===json(['Introduction','Background','第三章 Results','Evaluation','Appendix','Broken','Closing Remarks'])&&chosen()==='Background','closing an entry hides its children and selects it when the reading place is inside');
 yield* write(second);
 check(json(titles())===json(['Introduction','Background','第三章 Results','Evaluation','Appendix','Broken','Closing Remarks'])&&chosen()==='Background'&&state().page===1,'a rebuild keeps which entries are open and the selected entry');
 expand('Background',true);check(json(titles().slice(1,5))===json(['Background','Formal Proofs','Logical Frameworks','Deep Item'])&&chosen()==='Formal Proofs','opening an entry again restores what was open beneath it');
 api('testOutlineExpand',[row('Background'),false,true]);expand('Background',true);
 check(json(titles().slice(1,4))===json(['Background','Formal Proofs','Logical Frameworks'])&&!isOpen('Logical Frameworks')&&chosen()==='Formal Proofs','closing an entry together with everything beneath it (Option-click) is remembered too');
 expand('Logical Frameworks',true);
 api('testFit');const anchor=state().anchor.text;check(Math.abs(state().zoom-narrow)<.002&&anchor.length>12,'the PDF fits the area beside the outline');
 check(api('testOutlineMenu')===1,'View → Outline is available');o=outline();
 check(!o.shown&&!o.menuOn&&!o.visible&&o.edgeHidden&&json(rect(o.pdf))===json([14,30,966,738])&&json(rect(o.strip))===json([0,30,14,738]),'the menu item hides the panel and gives its width back to the PDF');
 check(Math.abs(state().zoom-wide)<.002&&state().anchor.text===anchor&&state().page===1,'hiding refits the PDF and keeps the reading passage');
 check(api('testOutlineShortcut')===true,'the menu bar handles ⌃⌘S');o=outline();
 check(o.shown&&o.menuOn&&o.visible&&json(rect(o.pdf))===json(body)&&Math.abs(state().zoom-narrow)<.002&&state().anchor.text===anchor,'the shortcut shows the panel again, with the same passage');
 check(chosen()==='Formal Proofs'&&json(titles().slice(1,5))===json(['Background','Formal Proofs','Logical Frameworks','Deep Item']),'the panel returns with its entries and selection as they were');
 api('testOutlineWidth',[300,false]);o=outline();
 check(o.width===300&&json(rect(o.frame))===json([0,30,294,738])&&json(rect(o.pdf))===json([314,30,666,738])&&Math.abs(state().zoom-wide*(666-28)/(966-28))<.002&&state().anchor.text===anchor,'dragging the edge resizes the panel, refits the PDF and keeps the passage');
 api('testOutlineWidth',[50,false]);check(outline().width===140&&rect(outline().pdf)[0]===154,'the panel is not narrower than 140 points');
 api('testOutlineWidth',[2000,false]);check(outline().width===480&&rect(outline().pdf)[0]===494,'nor wider than 480 points');
 api('testSize',[760,820]);o=outline();check(rect(o.frame)[2]===394&&rect(o.pdf)[0]===414&&rect(o.pdf)[2]===346&&o.width===480,'in a narrow window the panel yields room to the PDF');
 api('testSize',[980,820]);api('testOutlineWidth',[W,true]);check(json(rect(outline().pdf))===json(body),'the width returns when the window is wide again');
 api('testDiff',[0]);o=outline();check(json(rect(o.pdf))===json([W,30,980-W,738])&&o.visible,'without the change bar the PDF starts at the edge of the outline');
 const z=state().zoom;api('testPosition',[2,z,330]);check(chosen()==='Logical Frameworks','the selection still follows scrolling while the change bar is hidden');
 api('testDiff',[1]);
 api('history',[0]);yield* wait(()=>state().versionIndex===0,'first version');o=outline();
 check(!o.visible&&!o.rows.length&&!o.menuEnabled&&o.shown&&json(rect(o.pdf))===json([14,30,966,738]),'an older version without an outline shows no panel');
 api('historyStep',[0]);yield* wait(()=>state().versionIndex===2,'latest');
 check(outline().visible&&json(titles().slice(1,5))===json(['Background','Formal Proofs','Logical Frameworks','Deep Item'])&&json(rect(outline().pdf))===json(body),'returning to a version with an outline shows it as it was left');
 expand('第三章 Results',false);yield* write(third);
 check(json(titles())===json(['Introduction','Background','Formal Verification','Logical Frameworks','Deep Item','第三章 Results','Appendix','Broken','Closing Remarks','Index'])&&outline().entries===10,'a rebuild with a changed outline shows the new titles and entries, and keeps the other entries as they were');
 api('testMode',[0]);click('Deep Item');o=outline();check(state().page===2&&state().mode===0&&chosen()==='Deep Item','rows work in single-page display');
 click('Index');check(state().page===5&&chosen()==='Index','single-page display shows the page of the clicked entry');api('testMode',[1]);
 yield* write(long);o=outline();const all=o.rows.length;api('testOutlineScroll',[500]);const scrolled=outline().scrollY;
 check(all===69&&scrolled===500,'a long outline scrolls inside the panel');
 yield* write(longer);check(outline().scrollY===scrolled&&outline().rows.length===all,'a rebuild does not scroll the outline back to the top');
 api('close');o=outline();check(!o.visible&&!o.rows.length&&!o.menuEnabled&&o.entries===0,'closing the document clears and hides the panel');
 // 文言：二窗同隐同显。汉语：显隐对所有窗口生效。有两个窗口后，每次调用都要指明窗口。
 const call=(id,op,args=[])=>api('window',[id,op,args]),one=api('inspectWindows')[0].id,other=path.join(root,'other.pdf');fs.writeFileSync(other,first);
 call(one,'open',[file]);const two=api('openNew',[other]);yield* wait(()=>call(one,'inspect').pages===6&&call(two,'inspect').pages===6,'two windows');
 check(call(one,'inspectOutline').visible&&call(two,'inspectOutline').visible&&call(two,'inspectOutline').rows.length===9&&call(one,'inspectOutline').rows.length===69,'each window shows the outline of its own document');
 call(two,'testOutlineMenu');check(!call(one,'inspectOutline').visible&&!call(two,'inspectOutline').visible&&!call(one,'inspectOutline').menuOn&&!call(two,'inspectOutline').menuOn,'hiding the outline applies to every window');
 call(one,'testOutlineMenu');check(call(one,'inspectOutline').visible&&call(two,'inspectOutline').visible&&call(two,'inspectOutline').menuOn,'and so does showing it');
 const ui=api('inspectUI');check(!ui.active&&!ui.visible&&!ui.canBecomeKey&&!ui.canBecomeMain,'outline tests remain hidden and cannot take focus');
 api('quit');console.log(json({passed:checks,directory:root}));
}
fs.writeFileSync(file,plain);
let last=0,flow=scenario();try{require('../源码/宿主.cjs').run({pdf:file,hook:a=>{api=a;if(Date.now()-last<15)return;last=Date.now();flow.next();}});}catch(error){console.error(error);process.exitCode=1;if(api)api('quit');}
