// Installed local-evidence inspection: unfetched captures/source edits, typed reports,
// payload record/positional sums, blobs, secret references without secret values,
// accepted configuration versus local capture, rationale resolution and no GET fetches.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {spawn,spawnSync} from 'node:child_process';
import {once} from 'node:events';
const executable=fs.realpathSync(process.argv[2]);
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'kyyn-evidence-web-'));
const kb=path.join(temp,'kb'),plugin=path.join(temp,'plugin');
const env={...process.env,GIT_CONFIG_NOSYSTEM:'1',GIT_CONFIG_GLOBAL:'/dev/null',
 GIT_AUTHOR_NAME:'Inspection fixture',GIT_AUTHOR_EMAIL:'test@example.invalid',GIT_COMMITTER_NAME:'Inspection fixture',GIT_COMMITTER_EMAIL:'test@example.invalid'};
const secret='SENTINEL_SECRET_VALUE_MUST_NEVER_APPEAR';
const children=[];let fetches=0;
const server=http.createServer((_,res)=>{fetches++;res.end('binary fixture bytes '+fetches);});
server.listen(0,'127.0.0.1');await once(server,'listening');
function write(file,text){fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,text);}
async function cli(args,input){
 console.error('Evidence web: '+args.join(' '));
 const child=spawn(executable,['--kb',kb,'--json',...args],{env});let out='',err='';
 child.stdout.on('data',x=>out+=x);child.stderr.on('data',x=>err+=x);child.stdin.end(input);
 const [code]=await once(child,'exit');assert.equal(code,0,err+out);return JSON.parse(out).result;
}
async function accept(d){await cli(['evolution','check',d.id]);await cli(['evolution','ready',d.id]);await cli(['evolution','accept',d.id]);}
function git(where,...args){const r=spawnSync('git',['-C',where,...args],{env,encoding:'utf8'});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
try {
 fs.cpSync(new URL('./fixtures/inspection-plugin',import.meta.url),plugin,{recursive:true});
 git(plugin,'init','-q','-b','main');git(plugin,'add','.');git(plugin,'commit','-qm','Fixture');
 await cli(['kb','init']);await cli(['secret','set','fixture-key'],secret);
 const d=await cli(['evolution','new','connectors']);await cli(['plugin','install','--evolution',d.id,'--from',plugin]);
 const config=`let Auth = < Anonymous | Credential : { secretName : Text } >
let Connector = < Capture : { endpoint : Text, authentication : Auth } >
in [ { name = "captured", binding = "captured", connector = Connector.Capture { endpoint = "http://127.0.0.1:${server.address().port}/bytes", authentication = Auth.Credential { secretName = "fixture-key" } } }
, { name = "unfetched", binding = "unfetched", connector = Connector.Capture { endpoint = "http://127.0.0.1:${server.address().port}/bytes", authentication = Auth.Anonymous } } ]`;
 write(path.join(d.path,'target/plugins/config/inspection-fixture.dhall'),config);await accept(d);
 const web=spawn(executable,['--kb',kb,'web','serve','--port','0'],{env});children.push(web);
 const base=await new Promise((resolve,reject)=>{let out='';web.stdout.on('data',x=>{out+=x;const m=out.match(/Serving (http:\/\/127\.0\.0\.1:\d+)/);if(m)resolve(m[1]);});web.on('exit',()=>reject(new Error('Web exited')));});
 async function page(url,status=200,method='GET') {const r=await fetch(base+url,{method});const text=await r.text();assert.equal(r.status,status,text);assert(!text.includes(secret));return text;}
 const connector='/connectors/inspection-fixture/captured';
 assert((await page('/')).includes(connector));assert((await page(connector)).includes('no captured evidence'));
 assert((await page(connector)).includes('fixture-key'));assert.equal(fetches,0);
 await cli(['evidence','fetch','inspection-fixture','captured','--options','{ marker = "fixture option" }']);assert.equal(fetches,1);
 const before=await cli(['evidence','list','inspection-fixture','captured']);const head=git(kb,'rev-parse','HEAD');
 const detail=await page(connector);assert(detail.includes('3 added'));assert(detail.includes('fixture option'));assert(detail.includes('Fixture coverage'));
 assert(detail.includes('record%20%2F%20one'));assert(detail.includes('Truncated'));
 assert((await page('/evidence/inspection-fixture/captured/record%20%2F%20one')).includes('Captured &lt;document&gt;'));
 const blob=await page('/evidence/inspection-fixture/captured/record%20%2F%20one');assert(blob.includes('class="text-value"'));assert(blob.includes('.text-value{white-space:pre-wrap;overflow-wrap:anywhere}'));assert(blob.includes('First line\nSecond line'));assert(blob.includes('fixture.bin'));assert(blob.includes('<dt>sha256</dt>'));assert(blob.includes('<dt>mediaType</dt>'));assert(blob.includes('SHA-256'));assert(!blob.includes('binary fixture bytes'));
 const positional=await page('/evidence/inspection-fixture/captured/positional');assert(positional.includes('Measurement'));assert(positional.includes('90'));
 assert((await page('/evidence/inspection-fixture/captured/truncated')).includes('Payload no longer retained locally.'));
 const typ=await page(connector+'/types/payload/InspectionFixture.Payload');assert(typ.includes('Measurement'));assert(typ.includes('title'));assert(typ.includes('value'));
 assert((await page(connector+'/types/report/InspectionFixture.Report')).includes('examined'));
 await page('/evidence/inspection-fixture/captured/missing',404);await page('/connectors/inspection-fixture/missing',404);await page(connector,405,'POST');
 const draft=await cli(['evolution','new','evidence-links']);
 write(path.join(draft.path,'change/Evolution.hs'),`module Evolution where
import Kyyn.Workspace.Evolution
import qualified Schema
evolution :: Evolution Schema.Root
evolution = prepare (pure ()) $ edit (Rationale "Evidence links"
 [ EvidenceRef "inspection-fixture" "captured" "record / one" []
 , EvidenceRef "inspection-fixture" "captured" "missing" [] ]) (pure ())
`);
 await cli(['evolution','check',draft.id]);
 const report=await page('/evolutions/'+draft.id);assert(report.includes('/evidence/inspection-fixture/captured/record%20%2F%20one'));assert(report.includes('Not in local evidence'));
 const current=await page(connector+'?evolution='+draft.id);assert(current.includes('fixture-key'));assert(current.includes('Local capture · accepted connector configuration'));
 assert.equal(fetches,1);assert.equal(git(kb,'rev-parse','HEAD'),head);assert.deepEqual(await cli(['evidence','list','inspection-fixture','captured']),before);
 const changed=await cli(['evolution','new','producer-changed']);
 fs.appendFileSync(path.join(changed.path,'target/plugins/packages/inspection-fixture/source/src/InspectionFixture.hs'),'\n-- changed producer\n');await accept(changed);
 assert((await page(connector)).includes('Fixture coverage'));assert.equal(fetches,1);
 assert((await page('/evidence/inspection-fixture/captured/record%20%2F%20one')).includes('Captured &lt;document&gt;'));
 assert.deepEqual(await cli(['evidence','list','inspection-fixture','captured']),before);
 await cli(['evidence','fetch','inspection-fixture','captured']);assert.equal(fetches,2);
 const continued=await page(connector);assert(continued.includes('0 added'));assert(continued.includes('3 updated'));assert(continued.includes('Continued position'));
 const broken=await cli(['evolution','new','position-type']);
 const source=path.join(broken.path,'target/plugins/packages/inspection-fixture/source/src/InspectionFixture.hs');
 fs.writeFileSync(source,fs.readFileSync(source,'utf8').replace('FetchContext Integer','FetchContext Bool').replace('FetchResult Payload Integer Report','FetchResult Payload Bool Report').replace('1 (Report 3','False (Report 3'));
 await accept(broken);
 const failure=spawn(executable,['--kb',kb,'--json','evidence','fetch','inspection-fixture','captured'],{env});let diagnostic='';failure.stdout.on('data',x=>diagnostic+=x);failure.stderr.on('data',x=>diagnostic+=x);
 const [failureCode]=await once(failure,'exit');assert.notEqual(failureCode,0,diagnostic);assert.equal(fetches,2);
 assert((await page(connector)).includes('Continued position'));
 await cli(['evidence','fetch','inspection-fixture','captured','--restart-sync']);assert.equal(fetches,3);
 const restarted=await page(connector);assert(restarted.includes('No position'));assert(restarted.includes('3 updated'));
 console.log('Evidence inspection journey passed: latest capture, typed payloads/reports, references, blobs, scoped types, secrets excluded and read-only GETs.');
} finally {
 await Promise.all(children.map(async c=>{if(c.exitCode===null){c.kill();await once(c,'exit');}}));
 server.close();fs.rmSync(temp,{recursive:true,force:true});
}
