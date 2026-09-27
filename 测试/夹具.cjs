// 文言：临时造卷以验。汉语：生成带文本或图形的自包含 PDF 测试夹具。
'use strict';
function pdf(pages,{image=false,revision=''}={}){
 let objs=['','<< /Type /Catalog /Pages 2 0 R >>','', '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'],kids=[];
 pages.forEach((name,p)=>{const index=objs.length;kids.push(index+' 0 R');objs.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents ${index+1} 0 R >>`);
 let data=image?'0.2 0.4 0.8 rg 72 500 350 140 re f':Array.from({length:32},(_,i)=>`BT /F1 12 Tf 72 ${740-i*18} Td (${name} passage ${i}: stable meaningful paragraph for anchoring ${i===0?revision:''}) Tj ET`).join('\n');objs.push(`<< /Length ${Buffer.byteLength(data)} >>\nstream\n${data}\nendstream`);});
 objs[2]=`<< /Type /Pages /Count ${pages.length} /Kids [${kids.join(' ')}] >>`;let text='%PDF-1.4\n',offsets=[0];for(let i=1;i<objs.length;i++){offsets.push(Buffer.byteLength(text));text+=`${i} 0 obj\n${objs[i]}\nendobj\n`;}
 let x=Buffer.byteLength(text);text+=`xref\n0 ${objs.length}\n0000000000 65535 f \n`+offsets.slice(1).map(n=>`${String(n).padStart(10,'0')} 00000 n \n`).join('')+`trailer\n<< /Size ${objs.length} /Root 1 0 R >>\nstartxref\n${x}\n%%EOF\n`;return Buffer.from(text);
}
module.exports={pdf};
