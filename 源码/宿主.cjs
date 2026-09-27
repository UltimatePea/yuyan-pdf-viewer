// 文言：宿主传值而已，重载与寻锚皆由豫言。汉语：V8 GC 值转换及原生 API 适配。
'use strict';
const fs=require('node:fs'),path=require('node:path');
function run({directory=process.env.YY_VIEWER_RESOURCES||(fs.existsSync(path.join(__dirname,'阅卷.wasm'))?__dirname:path.resolve(__dirname,'../构建')),pdf=process.argv[2]||'',hook}={}) {
 const native=require(path.join(directory,'原生桥.node'));
 const api=(name,args=[])=>JSON.parse(native.invoke(name,JSON.stringify(args)));
 const bridge=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(path.join(directory,'值桥接.wasm')))).exports;
 function space(n){if(n>bridge.memory.buffer.byteLength)bridge.memory.grow(Math.ceil((n-bridge.memory.buffer.byteLength)/65536));}
 function decode(v){switch(bridge.kind(v)){case 0:return null;case 1:case 4:return Number(bridge.int(v));case 5:return bridge.float(v);case 2:{let n=bridge.bytes_len(v);space(n);bridge.bytes_out(v);return Buffer.from(new Uint8Array(bridge.memory.buffer,0,n)).toString('utf8');}case 3:return Array.from({length:bridge.tuple_len(v)},(_,i)=>decode(bridge.tuple_get(v,i)));default:throw Error('Unsupported GC value');}}
 function encode(v){if(v==null)return null;if(typeof v==='number'||typeof v==='boolean')return bridge.new_int(BigInt(v));if(typeof v==='string'){let b=Buffer.from(v);space(b.length);new Uint8Array(bridge.memory.buffer,0,b.length).set(b);return bridge.bytes_in(b.length);}if(Array.isArray(v)){let a=bridge.new_tuple(v.length);v.forEach((x,i)=>bridge.tuple_set(a,i,encode(x)));return a;}throw Error('Unsupported host value');}
 const operations={阅卷_完成匹配:(l,a)=>api('finishMatch',[l,a]),阅卷_准备跳点:i=>api('prepareJump',[i]),阅卷_准备所选跳点:()=>api('prepareSelectedJump'),阅卷_跳点名:()=>api('jumpName'),阅卷_名称已用:n=>api('jumpNameExists',[n]),阅卷_存跳点:n=>api('saveJump',[n]),阅卷_字母:i=>String.fromCharCode(65+i),阅卷_未变:()=>api('unchanged'),豫言_运行于Windows:()=>false,豫言_运行于MacOS:()=>true,豫言_运行于Linux:()=>false,阅卷_初始化:()=>api('init',[pdf]),阅卷_轮询:()=>{if(hook)hook(api);return api('poll');},阅卷_数:(k)=>api('number',[k]),阅卷_文本:i=>api('text',[i]),阅卷_旧文:i=>api('oldtext',[i]),阅卷_锚文:i=>api('anchor',[i]),阅卷_页码:i=>api('pageof',[i]),阅卷_锚页:i=>api('anchorpage',[i]),阅卷_读取:g=>api('begin',[g]),阅卷_捕获:()=>api('prepare'),阅卷_提交:(l,a)=>api('commit',[l,a]),阅卷_状态:s=>api('status',[s]),豫言_打印行:s=>{console.log(s);return null;},豫言_整数转字符串:n=>String(n)};
 const mod=new WebAssembly.Module(fs.readFileSync(path.join(directory,'阅卷.wasm')));
 const instance=new WebAssembly.Instance(mod,{'yuyan:gc-host/v1':{call:(name,args)=>{const n=decode(name);if(!operations[n])throw Error('Unimplemented host primitive: '+n);return encode(operations[n](...decode(args)));}}});
 instance.exports._start();return api;
}
module.exports={run};
if(require.main===module){
 const args=process.argv.slice(2),directory=fs.existsSync(path.join(__dirname,'阅卷.wasm'))?__dirname:path.resolve(__dirname,'../构建');
 if(args[0]==='--navigate'){
   if(args.length!==4||!Number.isInteger(Number(args[3]))||Number(args[3])<1){console.error('Usage: 运行.sh --navigate PDF SOURCE LINE (viewer must already have PDF open)');process.exitCode=2;}
   else {const native=require(path.join(directory,'原生桥.node'));native.invoke('notify',JSON.stringify([path.resolve(args[1]),path.resolve(args[2]),Number(args[3])]));}
 }else if(args[0]==='--help'){console.log('运行.sh [PDF]\n运行.sh --navigate PDF SOURCE LINE\nCmd-O open; Cmd-R reload; Cmd-F find; Cmd-0 fit width.');}
 else run({directory,pdf:args[0]?path.resolve(args[0]):''});
}
