// Installed domain-view journey: unchecked/live draft pages, checked query data,
// last-successful candidate after failed checks, accepted refresh, asset confinement,
// browser helper semantics and guest build reuse after view-only edits.
// Host validation and non-view freshness are deliberately deferred to #304.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import {spawn, spawnSync} from 'node:child_process';
import {once} from 'node:events';
const executable = fs.realpathSync(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-web-'));
const kb = path.join(temporary, 'kb');
const env = {...process.env, GIT_CONFIG_NOSYSTEM:'1', GIT_CONFIG_GLOBAL:'/dev/null',
  GIT_AUTHOR_NAME:'Web fixture', GIT_COMMITTER_NAME:'Web fixture',
  GIT_AUTHOR_EMAIL:'test@example.invalid', GIT_COMMITTER_EMAIL:'test@example.invalid'};
const children = [];
function cli(args, expected=0) {
  console.error('Web journey: '+args.join(' '));
  const r=spawnSync(executable,['--kb',kb,'--json',...args],{env,encoding:'utf8',timeout:600000,maxBuffer:16*1024*1024});
  assert.equal(r.status,expected,r.stderr+r.stdout); return JSON.parse(r.stdout).result;
}
function write(file,text){fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,text);}
async function serve(extra=[]) {
  const child=spawn(executable,['--kb',kb,'web','serve','--port','0',...extra],{env});children.push(child);
  let out='',err=''; child.stderr.on('data',x=>err+=x);
  const url=await new Promise((resolve,reject)=>{
    const timer=setTimeout(()=>{child.kill();reject(new Error('Startup timeout: '+out+err));},30000);
    child.stdout.on('data',x=>{out+=x;const m=out.match(/Serving (http:\/\/127\.0\.0\.1:\d+)\/kb\//);if(m){clearTimeout(timer);resolve(m[1]);}});
    child.on('exit',code=>{clearTimeout(timer);reject(new Error('Server exited '+code+': '+err));});
  });
  return url;
}
async function request(base,url,options={},status=200){
  const r=await fetch(base+url,options);assert.equal(r.status,status,await r.clone().text());return r;
}
async function query(base,name,args,status=200){return (await request(base,'/kb/queries/'+name,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(args)},status)).json();}
const html='<script src="/kb/kyyn.js"></script><h1>Training</h1><script>kyyn.query("titles", {}).then(rows => document.body.append(rows.join(", ")));</script>';
try {
  cli(['kb','init']);
  const d=cli(['evolution','new','domain-view']);const target=path.join(d.path,'target');
  const manifest=path.join(target,'kb.dhall');
  const emptyQueries='queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }';
  const emptyViews='views = [] : List { name : Text, description : Text, path : Text }';
  let m=fs.readFileSync(manifest,'utf8');assert(m.includes(emptyViews));assert(m.includes(emptyQueries));
  m=m.replace(emptyViews,'views = [{ name = "training", description = "Training & reports", path = "views/training/index.html" }]')
    .replace(emptyQueries,'queries = [{ name = "titles", description = "Task titles", implementation = "Report.titles", inputType = "Report.Input", inputMetadata = "Report.metadata", resultType = "Report.Output", resultMetadata = "Report.metadata" }]');
  write(manifest,m);write(path.join(target,'views/training/index.html'),html);
  write(path.join(target,'src/Schema.hs'),`{-# LANGUAGE DeriveGeneric, DeriveAnyClass, OverloadedStrings #-}
module Schema where
import GHC.Generics (Generic)
import Data.Text (Text)
import Kyyn.Schema
data Todo = Todo { title :: Text } deriving (Eq, Show, Generic, Contract)
data Root = Root { todos :: [Fact Todo] } deriving (Eq, Show, Generic, Contract)
metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] [CollectionDecl "todos" "todos" []]
`);
  write(path.join(target,'src/Report.hs'),`module Report where
import Data.Text (Text)
import Kyyn.Schema
import Kyyn.Query (readCollection)
import KyynQueryBindings
import Schema (Todo(..))
type Input = ()
type Output = [Text]
metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] []
titles :: Input -> Query Output
titles () = do
  facts <- readCollection todos
  pure [t | Fact _ (Todo t) <- facts]
`);
  const change=path.join(d.path,'change/Evolution.hs');
  const evolution=`{-# LANGUAGE OverloadedStrings #-}
module Evolution where
import Kyyn.Workspace.Evolution
import Kyyn.Schema
import qualified Schema
import qualified Kyyn.Workspace.Target as Target
evolution :: Evolution Schema.Root
evolution = prepare (pure ()) $ edit (Rationale "First task" [])
  (within Target.todos (append (Fact (FactId "one") (Schema.Todo "First lesson"))))
`;
  write(change,'broken evolution');
  const preview=await serve(['--evolution',d.id]);
  const busy=spawnSync(executable,['--kb',kb,'--json','web','serve','--port',new URL(preview).port],{env,encoding:'utf8',timeout:30000});
  assert.equal(busy.status,1,busy.stderr+busy.stdout);
  const busyResponse=JSON.parse(busy.stdout);
  assert.equal(busyResponse.diagnostics[0].code,'web.listen');
  assert(busyResponse.diagnostics[0].message.includes(new URL(preview).port));
  assert.equal(await (await request(preview,'/kb/views/training/')).text(),html);
  assert((await (await request(preview,'/kb/')).text()).includes('Draft '+d.id));
  assert.equal((await query(preview,'titles',{},409)).diagnostics[0].code,'evolution.no-candidate');
  assert((await (await request(preview,'/kb/')).text()).includes('Training &amp; reports'));
  const script=await (await request(preview,'/kb/kyyn.js')).text();
  const browser={window:{location:{search:'?month=2026-11&tag=a&tag=b'}},URLSearchParams,fetch:(url,opts)=>fetch(preview+url,opts)};
  vm.runInNewContext(script,browser);
  assert.equal(browser.window.kyyn.params().get('month'),'2026-11');
  assert.equal(browser.window.kyyn.viewUrl('training',{q:'a b&c'}),'/kb/views/training/?q=a+b%26c');
  assert.throws(()=>browser.window.kyyn.viewUrl('missing',{}),/Undeclared/);
  const secret = path.join(temporary,'outside.txt');write(secret,'NOT A VIEW');
  const unrelated = path.join(target,'src/unrelated');fs.symlinkSync(secret,unrelated);
  await request(preview,'/kb/views/training/');fs.unlinkSync(unrelated);
  const link = path.join(target,'views/training/outside.txt');fs.symlinkSync(secret,link);
  const denied = await request(preview,'/kb/views/training/outside.txt',{},500);
  assert(!(await denied.text()).includes('NOT A VIEW'));fs.unlinkSync(link);
  write(manifest,m.replace('views/training/index.html','index.html'));
  await request(preview,'/kb/',{},400);write(manifest,m);
  write(change,evolution);cli(['evolution','check',d.id]);
  const candidates=path.join(kb,'.kyyn/candidates');
  assert.equal(fs.readFileSync(path.join(candidates,'checked',d.id),'utf8'),fs.readFileSync(path.join(candidates,'latest',d.id),'utf8'),'Checked candidate should reuse the saved directory');
  assert.deepEqual((await query(preview,'titles',{})).result,['First lesson']);
  await query(preview,'titles',true,400);
  assert.equal((await query(preview,'missing',{},404)).diagnostics[0].code,'query.unknown');
  await assert.rejects(browser.window.kyyn.query('missing',{}),e=>e.status===404 && e.diagnostics[0].code==='query.unknown');
  await request(preview,'/kb/queries/titles',{method:'POST',body:'{}'},415);
  const compiled=path.join(kb,'.kyyn/compiled');
  const before=fs.readdirSync(compiled).sort();
  write(path.join(target,'views/training/index.html'),html+'<p>Edited</p>');
  assert((await (await request(preview,'/kb/views/training/')).text()).endsWith('<p>Edited</p>'));
  assert.deepEqual((await query(preview,'titles',{})).result,['First lesson']);
  const nix=spawnSync('which',['nix'],{encoding:'utf8'}).stdout.trim();assert(nix);
  const wrapper=path.join(temporary,'nix-observer');const calls=path.join(temporary,'nix-calls');
  const quote=s=>"'"+s.replaceAll("'", "'\\''")+"'";
  write(wrapper,'#!/bin/sh\nprintf \'%s\\n\' "$@" >> '+quote(calls)+'\nexec '+quote(nix)+' "$@"\n');
  fs.chmodSync(wrapper,0o755);
  cli(['--nix',wrapper,'evolution','check',d.id]);
  assert(!fs.readFileSync(calls,'utf8').split('\n').includes('build'),'View-only check invoked nix build');
  assert.deepEqual(fs.readdirSync(compiled).sort(),before,'View-only check changed retained guest builds');
  // A semantic failure saves an inspectable candidate, but never replaces checked query data.
  const validate=path.join(target,'src/Validate.hs');const valid=fs.readFileSync(validate,'utf8');
  write(validate,'{-# LANGUAGE OverloadedStrings #-}\n'+valid.replace('ValidationReport []','ValidationReport [errorDiagnostic "test.invalid" "Invalid candidate"]'));
  write(change,evolution.replace('First lesson','Rejected lesson'));
  cli(['evolution','check',d.id],1);
  assert.deepEqual((await query(preview,'titles',{})).result,['First lesson']);
  write(change,'broken again');
  assert((await (await request(preview,'/kb/views/training/')).text()).includes('Edited'));
  await request(preview,'/kb/views/training/%2e%2e%2f%2e%2e%2fkb.dhall',{},404);
  write(change,evolution);write(validate,valid);cli(['evolution','check',d.id]);
  const accepted=await serve();
  const emptyIndex=await (await request(accepted,'/kb/')).text();
  assert(emptyIndex.includes('Accepted revision '));assert(emptyIndex.includes('No views are declared.'));
  cli(['evolution','ready',d.id]);cli(['evolution','accept',d.id]);
  assert.deepEqual((await query(accepted,'titles',{})).result,['First lesson']);
  const acceptedPage=path.join(kb,'root/views/training/index.html');
  const committedPage=fs.readFileSync(acceptedPage);
  write(acceptedPage,'UNCOMMITTED');
  assert(!(await (await request(accepted,'/kb/views/training/')).text()).includes('UNCOMMITTED'));
  fs.writeFileSync(acceptedPage,committedPage);
  const e=cli(['evolution','new','next-lesson']);
  write(path.join(e.path,'change/Evolution.hs'),evolution.replace('"one"','"two"').replace('First lesson','Second lesson'));
  cli(['evolution','check',e.id]);cli(['evolution','ready',e.id]);cli(['evolution','accept',e.id]);
  assert.deepEqual((await query(accepted,'titles',{})).result,['First lesson','Second lesson']);
  console.log('Installed live draft views, last checked data, accepted refresh and view-only build reuse passed.');
} finally {
  await Promise.all(children.map(async c=>{if(c.exitCode===null){c.kill('SIGTERM');await once(c,'exit');}}));
  fs.rmSync(temporary,{recursive:true,force:true});
}
