// Installed domain-view journey: unchecked/live draft pages, checked query data,
// last-successful candidate after failed checks, accepted refresh, asset confinement,
// browser helper semantics and guest build reuse after view-only edits.
// Inspection: saved candidate schema/facts, context selection, escaped source,
// reference links, removed records, read-only routes and accepted refresh.
// Declarations: explicit-input query results, captured modules, open/closed recipes,
// and model-capable tools described without execution, local inspection assets,
// Haskell markup, long instruction/flow fallbacks and recipe-scoped state contracts
// and saved checkpoints (browser presentation checks are separate).
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
    .replace(emptyQueries,'queries = [{ name = "titles", description = "Task titles", implementation = "Report.titles", inputType = "Report.Input", inputMetadata = "Report.metadata", resultType = "Report.Output", resultMetadata = "Report.metadata" }, { name = "echo", description = "Echo a task", implementation = "Report.echoTask", inputType = "Schema.Todo", inputMetadata = "Report.metadata", resultType = "Schema.Todo", resultMetadata = "Report.metadata" }, { name = "never", description = "Execution canary", implementation = "Report.never", inputType = "Report.Input", inputMetadata = "Report.metadata", resultType = "Report.Output", resultMetadata = "Report.metadata" }]');
  m=m.replace('tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }',
    'tools = [{ name = "summarise", description = "Summarise with a model", implementation = "DemoTools.summary", inputType = "DemoTools.Input", resultType = "DemoTools.Output" }]');
  m='('+m+') // { model = Some { provider = < OpenAI | Anthropic >.OpenAI, model = "test-model", credential = "UNCONFIGURED_WEB_TEST" } }';
  write(manifest,m);write(path.join(target,'views/training/index.html'),html);
  write(path.join(target,'src/Schema.hs'),`{-# LANGUAGE DeriveGeneric, DeriveAnyClass, OverloadedStrings #-}
module Schema where
import GHC.Generics (Generic)
import Data.Text (Text)
import Kyyn.Schema
data Todo = Todo { title :: Text, related :: [FactId] } deriving (Eq, Show, Generic, Contract)
data Root = Root { todos :: [Fact Todo] } deriving (Eq, Show, Generic, Contract)
metadata :: SchemaMetadata
metadata = SchemaMetadata [RoleDecl "title" "Display title" Title] [FieldRole "Schema.Todo" "title" "title"] [CollectionDecl "todos" "todos" [("related","todos")]]
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
  pure [t | Fact _ (Todo t _) <- facts]
echoTask :: Todo -> Query Todo
echoTask = pure
never :: Input -> Query Output
never _ = error "QUERY_MUST_NOT_RUN_WITHOUT_INPUT"
`);
  write(path.join(target,'src/DemoTools.hs'),`module DemoTools where
import Data.Text (Text)
import qualified Agentic as A
import Kyyn.Agentic (Flow, interpret)
import Kyyn.Connectors (Tool)
import Kyyn.Plugin (FetchError)
type Input = Text
type Output = Text
summary :: Input -> Tool (Either FetchError Output)
summary input = interpret (A.draft "Summarise" :: Flow Text Text) input
`);
  write(path.join(target,'src/Checkpoint.hs'),`{-# LANGUAGE DeriveGeneric, DeriveAnyClass, OverloadedStrings #-}
module Checkpoint where
import GHC.Generics (Generic)
import Data.Text (Text)
import Kyyn.Schema (Contract(..))
import qualified Agentic.Contract as A
data Mark = Pending | Seen { note :: Text } deriving (Eq, Show, Generic, Contract)
data State = State { marks :: [Mark], latest :: Maybe Mark } deriving (Eq, Show, Generic)
instance Contract State where
  contract = A.field "marks" "Previously examined items" A.genericContract
`);
  const recipeSource=`module DemoRecipe where
import qualified Agentic as A
import Kyyn.Agentic (Flow, Step)
import Kyyn.Recipe
import Kyyn.Workspace.FactEdits (RootEdit)
import qualified Schema
import qualified Checkpoint
flow :: Flow (RecipeInput Schema.Root () Checkpoint.State) (RecipeProposal RootEdit Checkpoint.State)
flow = A.act action
action :: RecipeInput Schema.Root () Checkpoint.State -> Step (RecipeProposal RootEdit Checkpoint.State)
action _ = error "RECIPE_ACTION_MUST_NOT_RUN"
`;
  write(path.join(target,'src/DemoRecipe.hs'),recipeSource);
  const longInstructions="Review tasks <carefully> " + "Keep the complete prompt available. ".repeat(20);
  const recipeEdits=`  createRecipe (RecipeId "open") (openRecipe unitRecipeType "${longInstructions}") ()
  createRecipe (RecipeId "closed") DemoRecipe.flow (Checkpoint.State [Checkpoint.Seen "Saved <checkpoint>"] Nothing)`;

  const change=path.join(d.path,'change/Evolution.hs');
  write(path.join(target,'src/Notes.txt'),'<script>alert(1)</script> & source');
  const evolution=`{-# LANGUAGE OverloadedStrings #-}
module Evolution where
import Kyyn.Workspace.Evolution
import Kyyn.Schema
import qualified Schema
import qualified Kyyn.Workspace.Target as Target
import qualified Kyyn.Workspace.Target.RecipeFlows.DemoRecipe as DemoRecipe
import qualified Checkpoint
evolution :: Evolution Schema.Root
evolution = prepare (pure ()) $ edit (Rationale "First task" []) $ do
  within Target.todos (append (Fact (FactId "one") (Schema.Todo "First lesson" [])))
${recipeEdits}
`;
  write(change,'broken evolution');
  const preview=await serve(['--evolution',d.id]);
  const page=async (url,status=200)=> {
    const response=await request(preview,url,{},status);
    assert.match(response.headers.get('content-type'),/^text\/html/);
    const text=await response.text();
    assert(text.includes('<nav>'));assert(text.includes('>Index</a>'));
    return text;
  };
  assert((await page('/')).includes('Accepted KB'),'Inspection ignores server --evolution');
  assert((await page('/evolutions/'+d.id+'?evolution='+d.id)).includes('no checked candidate'));
  assert((await page('/collections/todos?evolution='+d.id,409)).includes('No successfully checked candidate'));
  await page('/?evolution='+d.id+'&evolution='+d.id,400);
  await page('/?evolution=../bad',400);
  const methodError=await request(preview,'/',{method:'POST'},405);
  assert.match(methodError.headers.get('content-type'),/^text\/html/);
  assert((await methodError.text()).includes('supports GET only'));
  await page('/unknown',404);
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
  const movedTarget=path.join(temporary,'moved-target');fs.renameSync(target,movedTarget);
  fs.symlinkSync(movedTarget,target);await request(preview,'/kb/views/training/',{},500);
  fs.unlinkSync(target);fs.renameSync(movedTarget,target);
  write(manifest,m.replace('views/training/index.html','index.html'));
  await request(preview,'/kb/',{},400);write(manifest,m);
  write(change,evolution);cli(['evolution','check',d.id]);
  const selected='?evolution='+d.id;
  const index=await page('/'+selected);
  assert(index.includes('/collections/todos'+selected));
  const listed=await page('/collections/todos'+selected);
  assert(listed.includes('First lesson'));assert(listed.includes('/records/todos/one'+selected));
  const record=await page('/records/todos/one'+selected);
  assert(record.includes('<dt>title</dt>'));assert(record.includes('First lesson'));
  const typ=await page('/types/Schema.Todo'+selected);
  assert(typ.includes('related'));assert(typ.includes('Display title'));
  const report=await page('/evolutions/'+d.id+selected);
  assert(report.includes('saved capture'));assert(report.includes('First lesson'));
  assert(report.includes('&lt;script&gt;alert(1)&lt;/script&gt;'));assert(!report.includes('<script>alert'));
  assert(report.includes('/records/todos/one'+selected));
  assert(report.includes('<dt>title</dt>'),'Step records use labelled fields');
  assert(report.includes('Target schema projection'));assert(!report.includes('TargetProjection'));
  assert(report.includes('class="diff-removed"'));assert(report.includes('class="diff-added"'));
  assert(report.includes('- data Root = Root'));assert(report.includes('+ data Todo = Todo'));
  assert(report.includes('unchanged lines'));assert(report.includes('class="diff-context"'));
  const direct=await page('/evolutions/'+d.id);
  assert(direct.includes('href="/records/todos/one'+selected+'"'));
  assert((await page('/records/todos/one'+selected)).includes('First lesson'));
  const missingRecord=await page('/records/todos/missing'+selected,404);
  assert(missingRecord.includes('Unknown record:'));assert(missingRecord.includes('href="/'+selected+'"'));
  await page('/types/Unknown'+selected,404);
  await page('/collections/todos',404);
  // Inspection does not alter the checked candidate or authored files.
  const tracked=spawnSync('git',['-C',kb,'status','--porcelain'],{encoding:'utf8'}).stdout;
  await page('/records/todos/one'+selected);await page('/evolutions/'+d.id+selected);
  assert.equal(spawnSync('git',['-C',kb,'status','--porcelain'],{encoding:'utf8'}).stdout,tracked);
  for (const [kind,name] of [['queries','titles'],['tools','summarise'],['recipes','open'],['recipes','closed']]) {
    assert(index.includes('/'+kind+'/'+name+selected));
    assert((await page('/'+kind+'/'+name+selected)).includes('Draft '+d.id));
  }
  assert((await page('/queries/never'+selected)).includes('Execution canary'),'Query description must not execute');
  const queryPage=await page('/queries/titles'+selected);
  assert(queryPage.includes('module Report where'));assert(queryPage.includes('class="language-haskell"'));assert(!queryPage.includes('<h2>Result</h2>'));
  assert((await page('/queries/titles'+selected+'&input='+encodeURIComponent('{=}'))).includes('<h2>Result</h2>'));
  const echo=await page('/queries/echo'+selected+'&input='+encodeURIComponent('{ title = "<demo>", related = [] : List Text }'));
  assert(echo.includes('&lt;demo&gt;'));assert(echo.includes('href="/types/Schema.Todo'+selected+'"'));
  const badInput=await page('/queries/titles'+selected+'&input=True',400);
  assert(badInput.includes('Page unavailable'));
  await page('/queries/titles'+selected+'&input=%7B%3D%7D&input=%7B%3D%7D',400);
  const toolPage=await page('/tools/summarise'+selected+'&input="not executed"');
  assert(toolPage.includes('OpenAI'));assert(toolPage.includes('test-model'));
  assert(toolPage.includes('UNCONFIGURED_WEB_TEST'));assert(toolPage.includes('module DemoTools where'));
  const openPage=await page('/recipes/open'+selected);
  assert(openPage.includes('Review tasks &lt;carefully&gt;'));
  assert(openPage.includes('<details class="prompt">'));
  assert(openPage.includes('No state fields.'));
  assert(!openPage.includes('Expand saved checkpoint'));
  assert(openPage.includes(longInstructions.replaceAll('<','&lt;').replaceAll('>','&gt;')));
  const closedPage=await page('/recipes/closed'+selected);
  assert(closedPage.includes('flowchart TD'));
  assert(closedPage.includes('id="flow-source" open'));
  for (const asset of ['inspection.mjs','vendor/prism.js','vendor/mermaid.js','vendor/prism.css']) {
    const response=await request(preview,'/_inspection/'+asset);
    assert.match(response.headers.get('content-type'), /javascript|css/);
    assert((await response.text()).length > 100);
  }
  await request(preview,'/_inspection/missing.js',{},404);
  await request(preview,'/_inspection/inspection.mjs',{method:'POST'},405);
  assert(closedPage.includes('DemoRecipe.flow'));assert(closedPage.includes('State type'));
  assert(closedPage.includes('Current saved state'));assert(closedPage.includes('Saved &lt;checkpoint&gt;'));
  assert(closedPage.includes('href="/recipes/closed/types/Checkpoint.State'+selected+'"'));
  const stateType=await page('/recipes/closed/types/Checkpoint.State'+selected);
  assert(stateType.includes('Previously examined items'));
  assert(stateType.includes('[<a href="/recipes/closed/types/Checkpoint.Mark'+selected+'"'));
  assert(stateType.includes('Maybe (<a href="/recipes/closed/types/Checkpoint.Mark'+selected+'"'));
  assert(stateType.includes('href="/recipes/closed'+selected+'"'));
  const markType=await page('/recipes/closed/types/Checkpoint.Mark'+selected);
  assert(markType.includes('Pending'));assert(markType.includes('note'));
  assert((await page('/recipes/open/types/%28%29'+selected)).includes('No state fields.'));
  await page('/types/Checkpoint.State'+selected,404);
  await page('/recipes/missing/types/Checkpoint.State'+selected,404);
  await page('/recipes/open/types/Checkpoint.State'+selected,404);
  await page('/recipes/closed/types/Schema.Todo'+selected,404);
  for (const kind of ['queries','tools','recipes']) await page('/'+kind+'/missing'+selected,404);
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
  assert((await page('/records/todos/one'+selected)).includes('First lesson'));
  assert(!(await page('/evolutions/'+d.id+selected)).includes('Rejected lesson'));
  const schemaFile=path.join(target,'src/Schema.hs'),savedSchema=fs.readFileSync(schemaFile,'utf8');
  write(schemaFile,'broken schema');
  assert((await page('/types/Schema.Todo'+selected)).includes('related'));
  assert((await page('/records/todos/one'+selected)).includes('First lesson'));
  const sources=['Report.hs','DemoTools.hs','DemoRecipe.hs','Checkpoint.hs'];
  const backups=sources.map(name=>fs.readFileSync(path.join(target,'src',name),'utf8'));
  sources.forEach(name=>write(path.join(target,'src',name),'broken live source'));
  assert((await page('/queries/titles'+selected+'&input='+encodeURIComponent('{=}'))).includes('First lesson'));
  assert((await page('/tools/summarise'+selected)).includes('module DemoTools where'));
  assert((await page('/recipes/closed'+selected)).includes('DemoRecipe.flow'));
  assert((await page('/recipes/closed/types/Checkpoint.State'+selected)).includes('Previously examined items'));
  assert((await page('/recipes/closed'+selected)).includes('Saved &lt;checkpoint&gt;'));
  sources.forEach((name,i)=>write(path.join(target,'src',name),backups[i]));
  write(schemaFile,savedSchema);
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
  write(path.join(e.path,'change/Evolution.hs'),evolution.replace(recipeEdits,'  updateRecipe (RecipeId \"closed\") DemoRecipe.flow (Checkpoint.State [Checkpoint.Seen \"New checkpoint\"] (Just Checkpoint.Pending))').replace('"one"','"two"').replace('First lesson','Second lesson').replace('Schema.Todo "Second lesson" []','Schema.Todo "Second lesson" [FactId "one"]'));
  cli(['evolution','check',e.id]);
  assert((await page('/recipes/closed?evolution='+e.id)).includes('New checkpoint'));
  assert((await page('/recipes/closed')).includes('Saved &lt;checkpoint&gt;'));
  cli(['evolution','ready',e.id]);cli(['evolution','accept',e.id]);
  assert.deepEqual((await query(accepted,'titles',{})).result,['First lesson','Second lesson']);
  for (const [kind,name] of [['queries','titles'],['tools','summarise'],['recipes','open'],['recipes','closed']]) {
    const rendered=await (await request(accepted,'/'+kind+'/'+name)).text();
    assert(rendered.includes('Accepted KB'));assert(!rendered.includes('Page unavailable'));
  }
  assert((await page('/recipes/closed')).includes('New checkpoint'));
  assert((await page('/recipes/closed/types/Checkpoint.State')).includes('Previously examined items'));
  const acceptedQuery=await (await request(accepted,'/queries/titles?input='+encodeURIComponent('{=}'))).text();
  assert(acceptedQuery.includes('Second lesson'));
  const second=await (await request(accepted,'/records/todos/two')).text();
  assert(second.includes('href="/records/todos/one"'));
  assert((await (await request(accepted,'/evolutions/'+d.id)).text()).includes('First lesson'));
  const removed=cli(['evolution','new','remove-task']);
  write(path.join(removed.path,'change/Evolution.hs'),`module Evolution where
import Kyyn.Workspace.Evolution
import Kyyn.Schema
import qualified Schema
import qualified Kyyn.Workspace.Target as Target
evolution :: Evolution Schema.Root
evolution = prepare (pure ()) $ edit (Rationale "Remove second task" [])
  (within Target.todos (remove (FactId "two")))
`);
  cli(['evolution','check',removed.id]);
  const suffix='?evolution='+removed.id;
  const deleted=await (await request(accepted,'/evolutions/'+removed.id)).text();
  const overridden=await (await request(accepted,'/evolutions/'+removed.id+'?evolution='+d.id)).text();
  assert(overridden.includes('Draft '+removed.id));
  assert(deleted.includes('href="/records/todos/one'+suffix+'"'));
  assert(deleted.includes('<dt>title</dt>'));
  assert(deleted.includes('Second lesson'));assert(deleted.includes('Absent'));
  assert(!deleted.includes('href="/records/todos/two'+suffix+'"'));
  await request(accepted,'/records/todos/two'+suffix,{},404);
  assert((await (await request(accepted,'/records/todos/two')).text()).includes('Second lesson'));
  console.log('Installed inspection pages: context selection, checked snapshots, reference links, deletions, escaping and read-only GETs passed.');
  console.log('Installed live draft views, last checked data, accepted refresh and view-only build reuse passed.');
} finally {
  await Promise.all(children.map(async c=>{if(c.exitCode===null){c.kill('SIGTERM');await once(c,'exit');}}));
  fs.rmSync(temporary,{recursive:true,force:true});
}
