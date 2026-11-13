// Compiler-free run HTTP routes and optional Chromium screenshots/interactions.
// Fixture recordings only; no providers or user KB changes. Browser mode uses
// KYYN_PLAYWRIGHT_MODULE (an installed Playwright index.mjs), not a product dependency.
// Usage: node tools/test-run-web.mjs CLI FIXTURE_DIRECTORY [SCREENSHOT_DIRECTORY]
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn, spawnSync} from 'node:child_process';
import {once} from 'node:events';
import {pathToFileURL} from 'node:url';
const [executable, fixtureDirectory, screenshots] = process.argv.slice(2);
assert(executable && fixtureDirectory, 'Usage: node tools/test-run-web.mjs CLI FIXTURE_DIRECTORY [SCREENSHOT_DIRECTORY]');
const temporary=fs.mkdtempSync(path.join(os.tmpdir(),'kyyn-run-web-')), kb=path.join(temporary,'kb');
const env={...process.env,GIT_CONFIG_NOSYSTEM:'1',GIT_CONFIG_GLOBAL:'/dev/null',GIT_AUTHOR_NAME:'Run viewer fixture',GIT_AUTHOR_EMAIL:'fixture@example.invalid',GIT_COMMITTER_NAME:'Run viewer fixture',GIT_COMMITTER_EMAIL:'fixture@example.invalid'};
const children=[];let browser;
const fixture=JSON.parse(fs.readFileSync(path.join(fixtureDirectory,'completed.json'),'utf8'));
const failure=JSON.parse(fs.readFileSync(path.join(fixtureDirectory,'failed.json'),'utf8'));
function git(...args){const r=spawnSync('git',['-C',kb,...args],{env,encoding:'utf8'});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
function write(file,contents){fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,contents);}
const header=graph=>({recipe:'demoReview',flow:'Flows.trace',before:'a'.repeat(40),startedAt:'2026-11-13T10:00:00Z',graph,mermaid:fixture.mermaid,
 build:{sourcesDigest:'fixture',targetSystem:'fixture',derivationPath:'fixture.drv',outputPath:'/fixture/not-present'}});
const hostEvent=(records,body)=>({sequence:String(records.length),event:{elapsedNanos:String(BigInt(records.at(-1).event.elapsedNanos)+200000000n),body}});
const failedTerminal={kind:'failed',diagnostics:[{severity:{tag:'Error'},code:'fixture.failure',message:'The demo model was unavailable.',location:{tag:'None'}}]};
function save(id,graph,records){const dir=path.join(kb,'.kyyn/runs',id);write(path.join(dir,'header.json'),JSON.stringify(header(graph)));write(path.join(dir,'events.jsonl'),records.map(x=>JSON.stringify(x.event)+'\n').join(''));return dir;}
try{
 write(path.join(kb,'root/kb.dhall'),'deliberately broken source: runs must not compile this');
 git('init','-q','-b','main');git('add','.');git('commit','-qm','Fixture');const before=git('rev-parse','HEAD');
 const completed=[...fixture.records,hostEvent(fixture.records,{kind:'completed',draft:'000001-demo'})];
 const failed=[...failure.records,hostEvent(failure.records,failedTerminal)];
 save('completed',fixture.graph,completed);save('failed',failure.graph,failed);
 const interrupted=fixture.records.slice(0,Math.floor(fixture.records.length/2));
 const interruptedDir=save('interrupted',fixture.graph,interrupted);fs.appendFileSync(path.join(interruptedDir,'events.jsonl'),'{partial');
 const activeDir=save('active',fixture.graph,fixture.records.slice(0,10));
 const lock=spawn('flock',['-x',activeDir+'.lock','sh','-c',"printf 'locked\\n'; cat >/dev/null"],{env});children.push(lock);await once(lock.stdout,'data');
 const web=spawn(executable,['--kb',kb,'--nix','/absent-nix','web','serve','--port','0','--evolution','000099-missing'],{env});children.push(web);
 let errors='';web.stderr.on('data',x=>errors+=x);
 const base=await new Promise((resolve,reject)=>{let out='';web.stdout.on('data',x=>{out+=x;const m=out.match(/Serving (http:\/\/127\.0\.0\.1:\d+)/);if(m)resolve(m[1]);});web.on('exit',()=>reject(Error(errors)));});
 async function get(url,status=200,method='GET'){const r=await fetch(base+url,{method});const body=await r.text();assert.equal(r.status,status,body);assert.equal(r.headers.get('cache-control'),'no-store');return body;}
 assert((await get('/runs')).includes('demoReview'));
 assert((await get('/runs?recipe=missing')).includes('No runs recorded'));
 assert((await get('/runs/completed?evolution=not-an-id')).includes('run-viewer.mjs'));
 const page=JSON.parse(await get('/runs/completed/events?limit=2'));
 assert.equal(page.events.length,2);assert.equal(page.next.value,'1');assert(page.more);assert(!('header' in page.summary));
 const next=JSON.parse(await get('/runs/completed/events?after=1&limit=2'));assert.equal(next.events[0].sequence,'2');
 const empty=JSON.parse(await get('/runs/active/events?after=999999999999999999999&limit=1'));assert.equal(empty.summary.status,'active');assert.equal(empty.events.length,0);
 const partial=JSON.parse(await get('/runs/interrupted/events'));assert(partial.incompleteTail);assert.equal(partial.summary.status,'interrupted');
 for(const query of ['limit=0','limit=1001','after=-1','after=01','limit=2&limit=3','after'])await get('/runs/completed/events?'+query,400);
 await get('/runs/missing',404);await get('/runs/missing/events',404);await get('/runs/completed/events',405,'POST');
 const cli=spawnSync(executable,['--kb',kb,'--json','run','list'],{env,encoding:'utf8'});assert.equal(cli.status,0,cli.stderr);assert(!JSON.stringify(JSON.parse(cli.stdout).result).includes('addressItems'),'List leaked full graphs');
 save('broken',fixture.graph,[]);fs.writeFileSync(path.join(kb,'.kyyn/runs/broken/events.jsonl'),'not json\n');await get('/runs/broken/events',500);fs.rmSync(path.join(kb,'.kyyn/runs/broken'),{recursive:true});
 const timings=[];
 for(let i=0;i<15;i++){const start=performance.now();await get('/runs/completed/events?after=10&limit=200');timings.push(performance.now()-start);}
 console.log(`Run polling fixture: ${completed.length} events, ${fs.statSync(path.join(kb,'.kyyn/runs/completed/events.jsonl')).size} bytes; median ${timings.sort((a,b)=>a-b)[7].toFixed(1)} ms (whole-file decode).`);
 if(screenshots){
  assert(process.env.KYYN_PLAYWRIGHT_MODULE,'Set KYYN_PLAYWRIGHT_MODULE for Chromium checks');
  const {chromium}=await import(pathToFileURL(process.env.KYYN_PLAYWRIGHT_MODULE));
  browser=await chromium.launch({headless:true,executablePath:process.env.KYYN_CHROMIUM});const page=await browser.newPage({viewport:{width:1440,height:1050}});
  const pageErrors=[];page.on('pageerror',e=>pageErrors.push(e.message));fs.mkdirSync(screenshots,{recursive:true});
  async function show(id){await page.goto(base+'/runs/'+id);await page.locator('#run-diagram svg').waitFor();await page.waitForFunction(()=>!document.querySelector('#run-message').textContent.includes('Loading recorded'));
   await page.locator('#run-diagram [aria-label=each]').focus();await page.keyboard.press('Enter');
   await page.locator('#run-inspector .progress-count').waitFor();
   const fits=await page.locator('.graph-viewport').evaluate(v=>{const a=v.getBoundingClientRect(),b=v.querySelector('svg').getBoundingClientRect();return b.left>=a.left&&b.right<=a.right&&b.top>=a.top&&b.bottom<=a.bottom;});
   assert(fits,'Initial diagram must fit completely inside its viewport');}

  await show('active');assert((await page.locator('#run-message').innerText()).includes('Live'));
  await page.locator('#run-zoom-in').click();await page.locator('#run-fit').click();
  await page.screenshot({path:path.join(screenshots,'live.png'),fullPage:true});
  fs.appendFileSync(path.join(activeDir,'events.jsonl'),fixture.records.slice(10,20).map(x=>JSON.stringify(x.event)+'\n').join(''));
  await page.waitForFunction(()=>document.querySelector('#run-message').textContent.includes('20 / 20'));
  await show('completed');await page.locator('#run-play').click();await page.waitForTimeout(600);await page.locator('#run-play').click();
  assert((await page.locator('#run-message').innerText()).includes('Paused'));
  await page.locator('#run-diagram [aria-label=each]').focus();await page.keyboard.press('Enter');assert((await page.locator('#run-inspector').innerText()).includes('observed occurrence'));
  await page.screenshot({path:path.join(screenshots,'playback.png'),fullPage:true});
  await page.locator('#run-speed').selectOption('5');assert.equal(await page.locator('#run-speed').inputValue(),'5');
  await page.locator('#run-seek').fill('0');assert(!(await page.locator('#run-outcome').innerText()).includes('Draft'));
  await page.locator('#run-follow').click();assert((await page.locator('#run-outcome').innerText()).includes('Draft 000001-demo'));
  await show('failed');await page.waitForFunction(()=>document.querySelector('#run-outcome').textContent.includes('unavailable'));
  await page.screenshot({path:path.join(screenshots,'failed.png'),fullPage:true});
  await show('interrupted');assert((await page.locator('#run-outcome').innerText()).includes('unknown outcomes'));
  await page.screenshot({path:path.join(screenshots,'interrupted.png'),fullPage:true});
  await show('active');lock.stdin.end();await once(lock,'exit');
  await page.waitForFunction(()=>document.querySelector('#run-outcome').textContent.includes('interrupted'));
  // A separate externally removed active recording exercises the browser's
  // polling error path; ordinary CLI clear refuses an active writer.
  const removedDir=save('removed',fixture.graph,fixture.records.slice(0,10));
  const removedLock=spawn('flock',['-x',removedDir+'.lock','sh','-c',"printf 'locked\\n'; cat >/dev/null"],{env});children.push(removedLock);await once(removedLock.stdout,'data');
  await show('removed');fs.rmSync(removedDir,{recursive:true});
  await page.waitForFunction(()=>document.querySelector('#run-message').textContent.includes('cleared'));
  assert(await page.locator('#run-play').isDisabled());
  assert.deepEqual(pageErrors,[]);
 }
 assert.equal(git('rev-parse','HEAD'),before,'Viewer changed Git');
 fs.rmSync(path.join(kb,'.kyyn/runs/completed'),{recursive:true});await get('/runs/completed/events',404);
 console.log('Run Web routes: captured-source independence, pagination, errors, active/interrupted states and read-only requests passed.');
}finally{
 if(browser)await browser.close();
 for(const child of children){child.stdin?.end();if(child.exitCode===null){child.kill();await once(child,'exit');}}
 fs.rmSync(temporary,{recursive:true,force:true});
}
