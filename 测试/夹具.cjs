// 文言：临时造卷以验。汉语：生成带文本或图形的自包含 PDF 测试夹具。
'use strict';
function pdf(pages,{image=false,revision=''}={}){
 let objs=['','<< /Type /Catalog /Pages 2 0 R >>','', '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'],kids=[];
 pages.forEach((name,p)=>{const index=objs.length;kids.push(index+' 0 R');objs.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents ${index+1} 0 R >>`);
 let data=image?'0.2 0.4 0.8 rg 72 500 350 140 re f':Array.from({length:32},(_,i)=>`BT /F1 12 Tf 72 ${740-i*18} Td (${name} passage ${i}: stable meaningful paragraph for anchoring ${i===0?revision:''}) Tj ET`).join('\n');objs.push(`<< /Length ${Buffer.byteLength(data)} >>\nstream\n${data}\nendstream`);});
 objs[2]=`<< /Type /Pages /Count ${pages.length} /Kids [${kids.join(' ')}] >>`;let text='%PDF-1.4\n',offsets=[0];for(let i=1;i<objs.length;i++){offsets.push(Buffer.byteLength(text));text+=`${i} 0 obj\n${objs[i]}\nendobj\n`;}
 let x=Buffer.byteLength(text);text+=`xref\n0 ${objs.length}\n0000000000 65535 f \n`+offsets.slice(1).map(n=>`${String(n).padStart(10,'0')} 00000 n \n`).join('')+`trailer\n<< /Size ${objs.length} /Root 1 0 R >>\nstartxref\n${x}\n%%EOF\n`;return Buffer.from(text);
}
// 文言：逐行置文，可设行号、页眉与页脚；亦可附纲目。汉语：按坐标逐行排版；每页为若干 [x, y, 字号, 文本]。
// outline 可选，是目录条目的树：{title, page, y, x, open, children}。page 为从 0 起的页序，省略则条目没有目的地；
// y 省略则目的地是整页（/Fit）；open 为真则该条目在 PDF 中标为展开。非 ASCII 标题写成 UTF-16BE。第 p 页的对象号是 4+2p。
function layout(pages,outline){
 let objs=['','<< /Type /Catalog /Pages 2 0 R >>','', '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'],kids=[];
 pages.forEach(lines=>{const index=objs.length;kids.push(index+' 0 R');objs.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents ${index+1} 0 R >>`);
 let data=lines.map(([x,y,size,text])=>`BT /F1 ${size} Tf ${x} ${y} Td (${text.replace(/[\\()]/g,'\\$&')}) Tj ET`).join('\n');objs.push(`<< /Length ${Buffer.byteLength(data)} >>\nstream\n${data}\nendstream`);});
 if(outline&&outline.length){
  const root=objs.length;objs.push('');
  const string=t=>/^[\x20-\x7e]*$/.test(t)?'('+t.replace(/[\\()]/g,'\\$&')+')':'<FEFF'+Buffer.from(t,'utf16le').swap16().toString('hex').toUpperCase()+'>';
  const total=items=>items.reduce((n,item)=>n+1+total(item.children||[]),0);
  const add=(items,parent)=>{const ids=items.map(()=>{objs.push('');return objs.length-1;});
   items.forEach((item,i)=>{const below=item.children&&item.children.length?add(item.children,ids[i]):null;
    objs[ids[i]]=`<< /Title ${string(item.title)} /Parent ${parent} 0 R`+(i?` /Prev ${ids[i-1]} 0 R`:'')+(i<items.length-1?` /Next ${ids[i+1]} 0 R`:'')
     +(below?` /First ${below[0]} 0 R /Last ${below.at(-1)} 0 R /Count ${(item.open?1:-1)*total(item.children)}`:'')
     +(item.page==null?'':` /Dest [${4+2*item.page} 0 R ${item.y==null?'/Fit':`/XYZ ${item.x??72} ${item.y} null`}]`)+' >>';});
   return ids;};
  const top=add(outline,root);objs[root]=`<< /Type /Outlines /First ${top[0]} 0 R /Last ${top.at(-1)} 0 R /Count ${outline.length} >>`;objs[1]=`<< /Type /Catalog /Pages 2 0 R /Outlines ${root} 0 R >>`;
 }
 objs[2]=`<< /Type /Pages /Count ${pages.length} /Kids [${kids.join(' ')}] >>`;let text='%PDF-1.4\n',offsets=[0];for(let i=1;i<objs.length;i++){offsets.push(Buffer.byteLength(text));text+=`${i} 0 obj\n${objs[i]}\nendobj\n`;}
 let x=Buffer.byteLength(text);text+=`xref\n0 ${objs.length}\n0000000000 65535 f \n`+offsets.slice(1).map(n=>`${String(n).padStart(10,'0')} 00000 n \n`).join('')+`trailer\n<< /Size ${objs.length} /Root 1 0 R >>\nstartxref\n${x}\n%%EOF\n`;return Buffer.from(text);
}
module.exports={pdf,layout};
