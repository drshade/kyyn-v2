// Installed event connector configuration/login and Web contract links.
// Uses synthetic adapters in a disposable KB; no provider or credential access.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn, spawnSync} from 'node:child_process';
const executable=fs.realpathSync(process.argv[2]);
const repo=path.resolve(import.meta.dirname,'..');
let web;
const temporary=fs.mkdtempSync(path.join(os.tmpdir(),'kyyn-event-registration-')),kb=path.join(temporary,'kb');
const env={...process.env,GIT_CONFIG_NOSYSTEM:'1',GIT_CONFIG_GLOBAL:'/dev/null',GIT_AUTHOR_NAME:'Fixture',GIT_AUTHOR_EMAIL:'fixture@example.invalid',GIT_COMMITTER_NAME:'Fixture',GIT_COMMITTER_EMAIL:'fixture@example.invalid'};
function cli(args,status=0){console.error(args.join(' '));const r=spawnSync(executable,['--kb',kb,'--json',...args],{cwd:temporary,env,encoding:'utf8',timeout:600000,maxBuffer:16*1024*1024});assert.equal(r.status,status,r.stdout+r.stderr);return JSON.parse(r.stdout);}
try {
 cli(['kb','init']);
 const draft=cli(['evolution','new','events']).result;
 const config=cli(['plugin','install','--evolution',draft.id,'--from',path.join(repo,'tools/fixtures/captured-plugin')]).result.configuration;
 fs.writeFileSync(path.join(kb,config.path),'[ { name = "updates", binding = "updates", connector = < Files : Integer | Options : Integer | State : Integer | StateOptions : Integer | Updates : Integer | Writer : Integer >.Updates +10 } ]');
 cli(config.schemaCommand.slice('kyyn-v2 '.length).split(' '));
 cli(config.checkCommand.slice('kyyn-v2 '.length).split(' '));
 cli(['evolution','ready',draft.id]);
 cli(['evolution','accept',draft.id]);
 cli(['plugin','connector','login','local-file','updates']);
 const refused=cli(['evidence','fetch','local-file','updates'],1);
 assert.match(JSON.stringify(refused),/source connector/);
 web=spawn(executable,['--kb',kb,'web','serve','--port','0'],{cwd:temporary,env});
 let errors='';web.stderr.on('data',x=>errors+=x);
 const base=await new Promise((resolve,reject)=>{let out='';web.stdout.on('data',x=>{out+=x;const m=out.match(/Serving (http:\/\/127\.0\.0\.1:\d+)/);if(m)resolve(m[1]);});web.on('exit',()=>reject(Error(errors)));});
 const response=await fetch(base+'/plugins/local-file');assert.equal(response.status,200);
 const html=await response.text();assert.match(html,/Event connector/);assert.match(html,/Binding: updates/);
 const links=[...html.matchAll(/href="([^"]+)"/g)].map(x=>x[1]).filter(x=>decodeURIComponent(x).includes('/types/Updates/event:'));
 assert.equal(new Set(links).size,6,'Each event request, reply and cursor has a type link');
 for(const link of new Set(links)){const page=await fetch(base+link.replaceAll('&amp;','&'));assert.equal(page.status,200,link);assert.doesNotMatch(await page.text(),/Unknown plugin contract/);}
 console.log('Installed event registration, configuration, acceptance, login and source-fetch refusal passed.');
} finally { if(web){web.kill('SIGTERM');await new Promise(resolve=>web.once('exit',resolve));} fs.rmSync(temporary,{recursive:true,force:true}); }
