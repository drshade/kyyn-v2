// Installed interactive flow lifecycle using only CLI operations and synthetic
// authored flows. No providers, secrets or user KB. Proves pinned resumption with
// current source deliberately broken and Nix unavailable to runtime operations.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn, spawnSync} from 'node:child_process';
import {once} from 'node:events';
const executable=fs.realpathSync(process.argv[2]);
const temporary=fs.mkdtempSync(path.join(os.tmpdir(),'kyyn-interactive-cli-')),kb=path.join(temporary,'kb');
const env={...process.env,GIT_CONFIG_NOSYSTEM:'1',GIT_CONFIG_GLOBAL:'/dev/null',GIT_AUTHOR_NAME:'Interactive fixture',GIT_AUTHOR_EMAIL:'fixture@example.invalid',GIT_COMMITTER_NAME:'Interactive fixture',GIT_COMMITTER_EMAIL:'fixture@example.invalid'};
const children=[];
function invoke(command,args,status=0){const r=spawnSync(command,args,{cwd:temporary,env,encoding:'utf8',timeout:600000});assert.equal(r.status,status,JSON.stringify({command,args,...r}));return r.stdout;}
const cli=(args,status=0)=>JSON.parse(invoke(executable,['--kb',kb,'--json',...args],status));
const runtime=(args,status=0)=>cli(['--nix','/not-installed',...args],status);
const show=id=>runtime(['flow','show',id]).result;
async function until(test){const deadline=Date.now()+30000;while(Date.now()<deadline){if(test())return;await new Promise(r=>setTimeout(r,100));}throw Error('Timed out waiting for flow state');}
function background(args){const child=spawn(executable,['--kb',kb,'--json','--nix','/not-installed',...args],{cwd:temporary,env});children.push(child);let output='',errors='';child.stdout.on('data',x=>output+=x);child.stderr.on('data',x=>errors+=x);return {child,output:()=>output,errors:()=>errors};}
try{
 cli(['kb','init']);
 const setup=cli(['evolution','new','interactive-demo']).result,target=path.join(setup.path,'target');
 fs.writeFileSync(path.join(target,'src/Conversations.hs'),`module Conversations where
import qualified Agentic as A
import qualified Agentic.Codec as C
import qualified Agentic.Schema as S
import qualified Agentic.Value as V
import Control.Monad.Trans.Except (throwE)
import Kyyn.Agentic (Flow)
import Kyyn.Plugin (FetchError(..))
conversation :: Flow Integer Integer
conversation = A.durably integer integer (\\_ n -> pure (n + 1)) A.>>> A.await integer integer
refuse :: Flow Integer Integer
refuse = A.act (\\_ -> throwE (FetchError "Authored fixture refusal"))
integer :: C.Codec Integer
integer = C.primitive S.SInteger V.Integer (\\value -> case value of V.Integer n -> Right n; _ -> Left "Expected an integer")
`);
 fs.writeFileSync(path.join(setup.path,'change/Evolution.hs'),`module Evolution where
import Kyyn.Workspace.Evolution
import Kyyn.Interactive (createInteractiveRecipe)
import qualified Kyyn.Workspace.Target.InteractiveFlows.Conversations as Flows
import qualified Schema
evolution :: Evolution Schema.Root
evolution = prepare (pure ()) (edit (Rationale "Declare interactive recipes" []) (do
  createInteractiveRecipe (RecipeId "conversation") Flows.conversation
  createInteractiveRecipe (RecipeId "refuse") Flows.refuse))
`);
 console.log('Declaring and accepting synthetic interactive recipes');
 cli(['evolution','check',setup.id]);cli(['evolution','ready',setup.id]);cli(['evolution','accept',setup.id]);
 const accepted=invoke('git',['-C',kb,'rev-parse','HEAD']).trim();
 const started=cli(['flow','start','conversation','--key','demo','--input','+1']).result;
 assert.equal(started.status,'runnable');assert.deepEqual(started.attempts,[]);
 assert.equal(cli(['flow','start','conversation','--key','demo','--input','+1']).result.id,started.id);
 cli(['flow','start','conversation','--key','demo','--input','+2'],1);
 const cancelled=cli(['flow','start','conversation','--key','cancel-demo','--input','+1']).result;
 const failed=cli(['flow','start','refuse','--key','failure-demo','--input','+1']).result;
 assert.equal(invoke('git',['-C',kb,'rev-parse','HEAD']).trim(),accepted,'Start changed accepted knowledge');
 const worker=background(['flow','worker']);
 await until(()=>show(started.id).status==='waiting');
 await until(()=>show(cancelled.id).status==='waiting');
 await until(()=>show(failed.id).status==='failed');
 const waiting=show(started.id),wait=waiting.waits.find(x=>x.status==='open');
 assert.equal(wait.descriptor.request,2);assert.equal(waiting.attempts.length,1);
 assert.equal(waiting.attempts[0].path,'/runs/'+waiting.attempts[0].id);
 runtime(['run','clear',waiting.attempts[0].id]);
 assert.equal(show(started.id).attempts.length,1,'Clearing recording removed the durable link');
 runtime(['flow','fulfil',started.id,'--wait',wait.id,'--key','invalid','--reply','"not an integer"']);
 await until(()=>show(started.id).deliveries[0].outcome.invalid!==undefined);
 assert.equal(show(started.id).status,'waiting');assert.equal(show(started.id).attempts.length,1);
 runtime(['flow','cancel',cancelled.id]);assert.equal(show(cancelled.id).status,'cancelled');
 worker.child.kill('SIGINT');await once(worker.child,'exit');
 assert.equal(show(started.id).status,'waiting','Stopping worker cancelled a flow');
 // New accepted source cannot replace the pinned executable/input/configuration.
 fs.writeFileSync(path.join(kb,'root/src/Conversations.hs'),'this source deliberately does not compile');
 invoke('git',['-C',kb,'add','root/src/Conversations.hs']);invoke('git',['-C',kb,'-c','commit.gpgsign=false','commit','-qm','Break current source for pinned-runtime test']);
 const brokenRevision=invoke('git',['-C',kb,'rev-parse','HEAD']).trim();
 const waiter=background(['flow','await',started.id]);
 runtime(['flow','fulfil',started.id,'--wait',wait.id,'--key','answer','--reply','9']);
 runtime(['flow','fulfil',started.id,'--wait',wait.id,'--key','same','--reply','9']);
 runtime(['flow','fulfil',started.id,'--wait',wait.id,'--key','conflict','--reply','10']);
 runtime(['flow','worker','--once']);
 await until(()=>waiter.child.exitCode!==null);
 assert.equal(waiter.child.exitCode,0,waiter.errors());
 assert.equal(JSON.parse(waiter.output()).result.status,'completed');
 const completed=show(started.id);assert.equal(completed.result,'9');assert.equal(completed.revision,accepted);
 assert.deepEqual(completed.deliveries.slice(1).map(x=>x.outcome),['accepted','duplicate','conflicting']);
 assert.equal(completed.waits[0].reply.origin.surface,'cli');
 assert.equal(completed.attempts.length,2);
 runtime(['flow','retry',started.id],1);
 runtime(['flow','clear',started.id,cancelled.id,failed.id]);
 assert.deepEqual(runtime(['flow','list']).result.instances,[]);
 assert.equal(runtime(['run','show',completed.attempts[1].id]).result.status,'returned','Clearing flow hid its recording');
 assert.equal(invoke('git',['-C',kb,'rev-parse','HEAD']).trim(),brokenRevision,'Runtime changed accepted knowledge');
 console.log('Interactive CLI: idempotent start, foreground worker, manual replies, cancellation, pinned resume, await and independent clearing passed.');
}finally{
 for(const child of children)if(child.exitCode===null&&child.signalCode===null){child.kill('SIGINT');await once(child,'exit');}
 fs.rmSync(temporary,{recursive:true,force:true});
}
