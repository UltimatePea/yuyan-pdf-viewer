'use strict';
const file=process.argv[2];
if(!file)throw Error('Usage: node 测试/示例只读.cjs /path/to/paper.pdf');
const start=Date.now();let done=false;
require('../源码/宿主.cjs').run({pdf:file,hook:api=>{if(done)return;const s=api('inspect');if(s.pages){console.log(JSON.stringify({pages:s.pages,loadMs:Date.now()-start,watchers:s.watchers,path:s.path}));api('quit');done=true;}else if(Date.now()-start>30000)throw Error('Representative PDF failed to load');}});
