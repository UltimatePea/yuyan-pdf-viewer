// 文言：聚诸依赖于包中。汉语：递归收集本机动态库，改为包内相对路径并保留许可。
'use strict';
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process');
const root=__dirname,app=path.join(root,'构建/阅卷.app'),contents=path.join(app,'Contents'),frameworks=path.join(contents,'Frameworks'),licenses=path.join(contents,'Resources/ThirdPartyLicenses');
fs.mkdirSync(frameworks,{recursive:true});fs.mkdirSync(licenses,{recursive:true});
const command=(name,args)=>cp.execFileSync(name,args,{encoding:'utf8'}).trim();
const dependencies=file=>command('otool',['-L',file]).split('\n').slice(1).map(s=>s.trim().split(' (')[0]);
const copied=new Map(),names=new Map(),packages=new Map();
function resolveDependency(dep,source){
 if(dep.startsWith('@loader_path/'))return path.resolve(path.dirname(source),dep.slice(13));
 if(dep.startsWith('@rpath/')){for(const base of [path.dirname(source),'/opt/homebrew/lib']){const candidate=path.join(base,dep.slice(7));if(fs.existsSync(candidate))return candidate;}throw Error('Unresolved rpath '+dep+' in '+source);}
 return dep;
}
function collect(source){
 const real=fs.realpathSync(source),name=path.basename(source);
 if(copied.has(real))return copied.get(real);
 if(names.has(name)&&names.get(name)!==real)throw Error('Library name collision '+name);
 const dest=path.join(frameworks,name);names.set(name,real);copied.set(real,dest);fs.copyFileSync(real,dest);fs.chmodSync(dest,0o755);
 const parts=real.split('/');const cellar=parts.indexOf('Cellar');if(cellar>=0){const packageRoot=parts.slice(0,cellar+3).join('/');packages.set(parts[cellar+1],packageRoot);}
 const own=command('otool',['-D',source]).split('\n')[1];
 for(const dep of dependencies(source)){if(dep===own)continue;const resolved=resolveDependency(dep,source);if(resolved.startsWith('/opt/homebrew/')||resolved.startsWith('/usr/local/')){const linked=collect(resolved);command('install_name_tool',['-change',dep,'@loader_path/'+path.basename(linked),dest]);}else if(!dep.startsWith('/usr/lib/')&&!dep.startsWith('/System/Library/'))throw Error('Unresolved dependency '+dep+' in '+source);}
 command('install_name_tool',['-id','@rpath/'+name,dest]);return dest;
}
const executable=path.join(contents,'MacOS/yy阅卷');
for(const dep of dependencies(executable)){if(dep.startsWith('/opt/homebrew/')||dep.startsWith('/usr/local/')){const linked=collect(dep);command('install_name_tool',['-change',dep,'@executable_path/../Frameworks/'+path.basename(linked),executable]);}else if(dep.startsWith('@rpath/libnode')){const linked=collect('/opt/homebrew/lib/'+path.basename(dep));command('install_name_tool',['-change',dep,'@executable_path/../Frameworks/'+path.basename(linked),executable]);}else if(!dep.startsWith('/usr/lib/')&&!dep.startsWith('/System/Library/'))throw Error('Unresolved executable dependency '+dep);}
function copyNotices(folder,dest,depth=0){if(depth>3)return;for(const item of fs.readdirSync(folder,{withFileTypes:true})){if(item.isSymbolicLink())continue;const from=path.join(folder,item.name);if(item.isFile()&&/^(LICENSE|LICENCE|COPYING|COPYRIGHT|NOTICE)/i.test(item.name)){fs.mkdirSync(dest,{recursive:true});fs.copyFileSync(from,path.join(dest,item.name));}else if(item.isDirectory()&&['share','doc','licenses'].includes(item.name))copyNotices(from,path.join(dest,item.name),depth+1);}}
for(const [name,folder]of packages)copyNotices(folder,path.join(licenses,name));
if(packages.has('sqlite')){const dest=path.join(licenses,'sqlite');fs.mkdirSync(dest,{recursive:true});fs.writeFileSync(path.join(dest,'NOTICE'),fs.readFileSync(path.join(packages.get('sqlite'),'include/sqlite3.h'),'utf8').split('\n').slice(0,10).join('\n')+'\n');}
fs.copyFileSync(path.join(root,'LICENSE'),path.join(contents,'Resources/LICENSE'));
fs.copyFileSync(path.join(root,'第三方许可.txt'),path.join(contents,'Resources/第三方许可.txt'));
for(const file of [...copied.values(),executable]){
 const lines=command('otool',['-l',file]).split('\n');for(let i=0;i<lines.length;i++)if(lines[i].trim()==='cmd LC_RPATH'){const p=lines[i+2].trim().replace(/^path /,'').replace(/ \(offset.*$/,'');if(p.startsWith('/opt/')||p.startsWith('/usr/local/'))command('install_name_tool',['-delete_rpath',p,file]);}
 for(const dep of dependencies(file))if(dep.startsWith('/opt/')||dep.startsWith('/usr/local/'))throw Error('External dependency remains: '+dep);
 command('codesign',['--force','--sign','-',file]);
}
command('codesign',['--force','--sign','-',path.join(contents,'Resources/原生桥.node')]);
command('codesign',['--force','--sign','-',app]);command('codesign',['--verify','--deep','--strict',app]);
const manifest={architecture:command('uname',['-m']),libraries:[...copied.keys()],packages:[...packages.keys()]};
fs.writeFileSync(path.join(root,'构建/依赖清单.json'),JSON.stringify(manifest,null,2)+'\n');
console.log(`Bundled ${copied.size} libraries from ${packages.size} packages.`);
