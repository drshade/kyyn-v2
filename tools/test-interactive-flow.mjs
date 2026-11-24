// Installed interactive flow lifecycle using only CLI operations and synthetic
// authored flows. No providers, secrets or user KB. Proves pinned resumption with
// current source deliberately broken and Nix unavailable to runtime operations.
import assert from 'node:assert/strict';
import {newFlowProjection, addAttempt, reduceAttempt, finishAttempt} from '../host/kyyn/web/flow-projection.mjs';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn, spawnSync} from 'node:child_process';
import {once} from 'node:events';
const executable=fs.realpathSync(process.argv[2]);
const temporary=fs.mkdtempSync(path.join(os.tmpdir(),'kyyn-interactive-cli-')),kb=path.join(temporary,'kb');
const env={...process.env,GIT_CONFIG_NOSYSTEM:'1',GIT_CONFIG_GLOBAL:'/dev/null',GIT_AUTHOR_NAME:'Interactive fixture',GIT_AUTHOR_EMAIL:'fixture@example.invalid',GIT_COMMITTER_NAME:'Interactive fixture',GIT_COMMITTER_EMAIL:'fixture@example.invalid'};
const children=[];
const retainedRecordings=new Map();
function recording(id){
 const directory=path.join(kb,'.kyyn/runs',id);
 return {header:JSON.parse(fs.readFileSync(path.join(directory,'header.json'),'utf8')),
  events:fs.readFileSync(path.join(directory,'events.jsonl'),'utf8').trim().split('\n').map(JSON.parse)};
}
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
import Kyyn.Interactive (FlowHandle, startFlow, flowRef, flowRefTyped, inspectFlow, cancelFlow)
import qualified Kyyn.Interactive as I
import Kyyn.Types.KnowledgeBase (RecipeId(..))
import Data.Text (Text)
import qualified Child
import Kyyn.Plugin (FetchError(..))
awaitParent :: Flow Integer Integer
awaitParent = startFlow (flowRef (RecipeId "child") Child.review) A.>>> I.awaitFlow
  A.>>> A.arr (\\outcome -> case outcome of I.Completed result -> result; I.Cancelled -> -1; I.Failed _ -> -2)
observeParent :: Flow Integer Integer
observeParent = startFlow (flowRef (RecipeId "child") Child.review)
  A.>>> (inspectFlow A.&&& A.arr id)
  A.>>> A.first (A.arr statusName A.>>> A.awaitWith text integer)
  A.>>> A.arr snd A.>>> inspectFlow
  A.>>> A.arr (\\status -> case status.execution of I.Finished (I.Completed result) -> result; _ -> -1)
  where
    statusName status = case status.execution of I.Runnable -> "runnable"; _ -> "changed"
    text = C.primitive (S.SString Nothing) V.String (\\value -> case value of V.String t -> Right t; _ -> Left "Expected text")
cancelParent :: Flow Integer Integer
cancelParent = startFlow (flowRef (RecipeId "child") Child.review)
  A.>>> (cancelFlow I.FlowAndDescendants A.&&& A.arr id)
  A.>>> A.arr snd A.>>> inspectFlow
  A.>>> A.arr (\\status -> case status.execution of I.Finished I.Cancelled -> 1; _ -> 0)
parent :: Flow Integer (FlowHandle Integer)
parent = startFlow (flowRef (RecipeId "child") Child.review)
badReference :: Flow Text (FlowHandle Integer)
badReference = startFlow (flowRefTyped @Text @Integer (RecipeId "child"))
self :: Flow Integer Integer
self = A.arr (\\n -> if n > 0 then Left (n-1) else Right 0)
  A.>>> ((startFlow (flowRef (RecipeId "self") self) A.>>> A.arr (const 0)) A.||| A.arr id)
conversation :: Flow Integer Integer
conversation = A.durablyWith integer integer (\\_ n -> pure (n + 1)) A.>>> A.awaitWith integer integer
multiple :: Flow Integer Integer
multiple = (A.awaitWith integer integer A.&&& A.awaitWith integer integer) A.>>> A.arr (uncurry (+))
refuse :: Flow Integer Integer
refuse = A.act (\\_ -> throwE (FetchError "Authored fixture refusal"))
integer :: C.Codec Integer
integer = C.primitive S.SInteger V.Integer (\\value -> case value of V.Integer n -> Right n; _ -> Left "Expected an integer")
`);
 fs.writeFileSync(path.join(target,'src/Child.hs'),`module Child where
import qualified Agentic as A
import qualified Agentic.Codec as C
import qualified Agentic.Schema as S
import qualified Agentic.Value as V
import Kyyn.Agentic (Flow)
review :: Flow Integer Integer
review = A.awaitWith integer integer
integer :: C.Codec Integer
integer = C.primitive S.SInteger V.Integer (\\value -> case value of V.Integer n -> Right n; _ -> Left "Expected an integer")
`);
 fs.writeFileSync(path.join(setup.path,'change/Evolution.hs'),`module Evolution where
import Kyyn.Workspace.Evolution
import Kyyn.Interactive (createInteractiveRecipe, withChildren, child)
import qualified Kyyn.Workspace.Target.InteractiveFlows.Conversations as Flows
import qualified Kyyn.Workspace.Target.InteractiveFlows.Child as Child
import qualified Schema
evolution :: Evolution Schema.Root
evolution = prepare (pure ()) (edit (Rationale "Declare interactive recipes" []) (do
  createInteractiveRecipe (RecipeId "conversation") Flows.conversation
  createInteractiveRecipe (RecipeId "refuse") Flows.refuse
  createInteractiveRecipe (RecipeId "multiple") Flows.multiple
  createInteractiveRecipe (RecipeId "child") Child.review
  createInteractiveRecipe (RecipeId "awaitParent") (withChildren [child (RecipeId "child") Child.review] Flows.awaitParent)
  createInteractiveRecipe (RecipeId "observeParent") (withChildren [child (RecipeId "child") Child.review] Flows.observeParent)
  createInteractiveRecipe (RecipeId "cancelParent") (withChildren [child (RecipeId "child") Child.review] Flows.cancelParent)
  createInteractiveRecipe (RecipeId "parent") (withChildren [child (RecipeId "child") Child.review] Flows.parent)
  createInteractiveRecipe (RecipeId "badReference") (withChildren [child (RecipeId "child") Child.review] Flows.badReference)
  createInteractiveRecipe (RecipeId "self") (withChildren [child (RecipeId "self") Flows.self] Flows.self)))
`);
 console.log('Declaring and accepting synthetic interactive recipes');
 cli(['evolution','check',setup.id]);cli(['evolution','ready',setup.id]);cli(['evolution','accept',setup.id]);
 const accepted=invoke('git',['-C',kb,'rev-parse','HEAD']).trim();
 const started=cli(['flow','start','conversation','--key','demo','--input','+1']).result;
 assert.equal(started.input.trim(),'+1');
 assert.equal(started.status,'runnable');assert.deepEqual(started.attempts,[]);
 assert.equal(cli(['flow','start','conversation','--key','demo','--input','+1']).result.id,started.id);
 cli(['flow','start','conversation','--key','demo','--input','+2'],1);
 const cancelled=cli(['flow','start','conversation','--key','cancel-demo','--input','+1']).result;
 const failed=cli(['flow','start','refuse','--key','failure-demo','--input','+1']).result;
 assert.equal(invoke('git',['-C',kb,'rev-parse','HEAD']).trim(),accepted,'Start changed accepted knowledge');
 const fresh=cli(['flow','start','conversation','--input','+1']).result;
 const freshAgain=cli(['flow','start','conversation','--input','+1']).result;
 assert.notEqual(fresh.id,freshAgain.id);
 runtime(['flow','cancel',fresh.id]);runtime(['flow','cancel',freshAgain.id]);
 const multiple=cli(['flow','start','multiple','--input','+1']).result;
 const parent=cli(['flow','start','parent','--input','+3']).result;
 const wrong=cli(['flow','start','badReference','--input','"bad"']).result;
 const self=cli(['flow','start','self','--input','+1']).result;
 const observer=cli(['flow','start','observeParent','--input','+2']).result;
 const canceller=cli(['flow','start','cancelParent','--input','+2']).result;
 const awaiting=cli(['flow','start','awaitParent','--input','+2']).result;
 const awaitingCancelled=cli(['flow','start','awaitParent','--input','+2']).result;
 const worker=background(['flow','worker']);
 await until(()=>show(started.id).status==='waiting');
 await until(()=>show(cancelled.id).status==='waiting');
 await until(()=>show(failed.id).status==='failed');
 await until(()=>show(multiple.id).status==='waiting');
 const open=show(multiple.id).waits.filter(x=>x.status==='open');assert.equal(open.length,2);
 const ambiguous=runtime(['flow','fulfil',multiple.id,'--reply','7'],1);
 for(const wait of open)assert.ok(ambiguous.diagnostics[0].message.includes(wait.id));
 runtime(['flow','cancel',multiple.id]);
 assert.equal(runtime(['flow','await',failed.id],1).result.status,'failed');
 await until(()=>show(parent.id).status==='completed');
 await until(()=>show(wrong.id).status==='failed');
 const instances=()=>runtime(['flow','list']).result.instances;
 await until(()=>instances().some(x=>x.parent===parent.id&&x.status==='waiting'));
 const child=instances().find(x=>x.parent===parent.id);
 assert.equal(JSON.parse(show(parent.id).result.trim()),child.id);
 assert.equal(child.owner.bundle,parent.owner.bundle);
 assert.equal(instances().filter(x=>x.parent===wrong.id).length,0,'Mismatched reference published a child');
 assert.ok(show(wrong.id).failure[0].message.includes('input contract mismatch'));
 runtime(['flow','fulfil',child.id,'--reply','11']);
 await until(()=>show(child.id).status==='completed');
 await until(()=>instances().some(x=>x.parent===self.id&&x.status==='completed'));
 assert.equal(instances().filter(x=>x.parent===self.id).length,1,'Self-reference started an unbounded tree');
 await until(()=>show(observer.id).status==='waiting');
 assert.equal(show(observer.id).waits[0].descriptor.request,'runnable');
 await until(()=>instances().some(x=>x.parent===observer.id&&x.status==='waiting'));
 const observedChild=instances().find(x=>x.parent===observer.id);
 runtime(['flow','fulfil',observedChild.id,'--reply','17']);
 await until(()=>show(observedChild.id).status==='completed');
 runtime(['flow','fulfil',observer.id,'--reply','1']);
 await until(()=>show(observer.id).status==='completed');
 assert.equal(show(observer.id).result.trim(),'+17','Inspection did not restore the old snapshot and take a fresh one at the next occurrence');
 await until(()=>show(canceller.id).status==='completed');
 assert.equal(show(canceller.id).result.trim(),'+1');
 const cancelledChild=instances().find(x=>x.parent===canceller.id);
 assert.equal(cancelledChild.status,'cancelled');assert.deepEqual(cancelledChild.attempts,[]);
 await until(()=>show(awaiting.id).status==='waiting');
 const childWait=show(awaiting.id).waits.find(x=>x.status==='open');
 const awaitedChild=instances().find(x=>x.parent===awaiting.id);
 assert.equal(childWait.child,awaitedChild.id);assert.equal(childWait.descriptor,null);
 const forged=runtime(['flow','fulfil',awaiting.id,'--wait',childWait.id,'--reply','17'],1);
 assert.ok(forged.diagnostics.some(x=>x.message.includes('Child waits')));
 assert.deepEqual(show(awaiting.id).deliveries,[],'Refused child outcome was queued');
 const inferred=runtime(['flow','fulfil',awaiting.id,'--reply','17'],1);
 assert.ok(inferred.diagnostics.some(x=>x.message.includes('Open reply waits: none')));
 const collision=runtime(['flow','fulfil',started.id,'--key','internal-child-'+childWait.id,'--reply','1'],1);
 assert.ok(collision.diagnostics.some(x=>x.message.includes('reserved')));
 await until(()=>show(awaitedChild.id).status==='waiting');
 runtime(['flow','fulfil',awaitedChild.id,'--reply','23']);
 await until(()=>show(awaiting.id).status==='completed');
 assert.equal(show(awaiting.id).result.trim(),'+23');
 assert.equal(show(awaiting.id).waits[0].reply.origin.kind,'child');
 await until(()=>show(awaitingCancelled.id).status==='waiting');
 const toCancel=instances().find(x=>x.parent===awaitingCancelled.id);
 runtime(['flow','cancel',toCancel.id]);
 await until(()=>show(awaitingCancelled.id).status==='completed');
 assert.equal(show(awaitingCancelled.id).result.trim(),'-1');
 const waiting=show(started.id),wait=waiting.waits.find(x=>x.status==='open');
 assert.equal(wait.descriptor.request,2);assert.equal(waiting.attempts.length,1);
 assert.equal(waiting.attempts[0].path,'/runs/'+waiting.attempts[0].id);
 retainedRecordings.set(waiting.attempts[0].id,recording(waiting.attempts[0].id));
 runtime(['run','clear',waiting.attempts[0].id]);
 assert.equal(show(started.id).attempts.length,1,'Clearing recording removed the durable link');
 runtime(['flow','fulfil',started.id,'--wait',wait.id,'--key','invalid','--reply','"not an integer"']);
 await until(()=>show(started.id).deliveries[0].outcome==='invalid');
 assert.equal(show(started.id).status,'waiting');assert.equal(show(started.id).attempts.length,1);
 runtime(['flow','cancel',cancelled.id]);assert.equal(show(cancelled.id).status,'cancelled');
 assert.equal(runtime(['flow','await',cancelled.id],1).result.status,'cancelled');
 const closed=runtime(['flow','fulfil',cancelled.id,'--wait','missing','--reply','7'],1);
 assert.equal(closed.result.outcome,'closed');
 assert.equal(show(cancelled.id).deliveries.at(-1).outcome,'closed');
 worker.child.kill('SIGINT');await once(worker.child,'exit');
 assert.equal(show(started.id).status,'waiting','Stopping worker cancelled a flow');
 // New accepted source cannot replace the pinned executable/input/configuration.
 fs.writeFileSync(path.join(kb,'root/src/Conversations.hs'),'this source deliberately does not compile');
 invoke('git',['-C',kb,'add','root/src/Conversations.hs']);invoke('git',['-C',kb,'-c','commit.gpgsign=false','commit','-qm','Break current source for pinned-runtime test']);
 const brokenRevision=invoke('git',['-C',kb,'rev-parse','HEAD']).trim();
 const waiter=background(['flow','await',started.id]);
 const delivery=runtime(['flow','fulfil',started.id,'--reply','9']).result;
 runtime(['flow','fulfil',started.id,'--wait',wait.id,'--key','same','--reply','9']);
 runtime(['flow','fulfil',started.id,'--wait',wait.id,'--key','conflict','--reply','10']);
 const visits=runtime(['flow','worker','--once']).result.visits;
 assert.deepEqual(visits,[{id:started.id,outcome:'advanced',retryAt:null}]);
 await until(()=>waiter.child.exitCode!==null);
 assert.equal(waiter.child.exitCode,0,waiter.errors());
 assert.equal(JSON.parse(waiter.output()).result.status,'completed');
 const completed=show(started.id);assert.equal(completed.result.trim(),'+9');assert.equal(completed.revision,accepted);
 const projection=newFlowProjection(started.id);
 for(const {id} of completed.attempts){
  const {header,events}=retainedRecordings.get(id)??recording(id);
  addAttempt(projection,id,header);
  events.forEach((event,index)=>reduceAttempt(projection,id,{sequence:String(index),event}));
  finishAttempt(projection,id,{summary:{status:'returned'},more:false,incompleteTail:false});
 }
 assert.equal(projection.episodes.length,1,'Durable action executes once across real resumptions');
 assert.equal(projection.operations.size,2,'Action and reply have distinct upstream keys');
 assert.equal([...projection.operations.values()].filter(operation=>operation.completed).length,2);
 assert.equal([...projection.operations.values()].reduce((n,operation)=>n+operation.restorations.length,0),2);
 console.log('Real captured guest recordings project one action and one fulfilled reply across resumptions.');
 assert.deepEqual(completed.deliveries.slice(1).map(x=>x.outcome),['accepted','duplicate','conflicting']);
 assert.equal(completed.waits[0].reply.origin.surface,'cli');
 assert.notEqual(delivery.id,completed.deliveries[2].id);
 assert.deepEqual(runtime(['flow','worker','--once']).result.visits,[]);
 const web=background(['web','serve','--port','0']);
 await until(()=>/Serving http:\/\/127\.0\.0\.1:\d+/.test(web.output()));
 const webBase=web.output().match(/Serving (http:\/\/127\.0\.0\.1:\d+)/)[1];
 const webPage=await (await fetch(webBase+'/flows/'+started.id)).text();
 assert(webPage.includes('+1')&&webPage.includes('+9'),'Instance page did not render typed Dhall input/result');
 // Missing metadata degrades rendering, never hides lifecycle state.
 const bundle=path.join(kb,'.kyyn/flows/bundles',completed.owner.bundle+'.json');
 const captured=fs.readFileSync(bundle);fs.unlinkSync(bundle);
 const absent=show(started.id);assert.equal(absent.status,'completed');assert.equal(absent.result,null);
 assert.equal(absent.inspectionDiagnostics[0].code,'flow.bundle-missing');
 const unavailablePeers=runtime(['flow','list']).result.instances.filter(x=>x.owner.bundle===completed.owner.bundle);
 assert(unavailablePeers.length>1,'Fixture must share captured metadata');
 assert(unavailablePeers.every(x=>x.input===null&&x.inspectionDiagnostics[0].code==='flow.bundle-missing'));

 const missingMetadataPage=await (await fetch(webBase+'/flows/'+started.id)).text();
 assert(missingMetadataPage.includes('flow.bundle-missing'));assert(!missingMetadataPage.includes('<summary>Original input</summary>'));
 fs.writeFileSync(bundle,captured);
 const restoredPeers=runtime(['flow','list']).result.instances.filter(x=>x.owner.bundle===completed.owner.bundle);
 assert(restoredPeers.every(x=>x.input!==null&&x.inspectionDiagnostics.length===0),'Metadata failure survived a later command');
 assert.equal(completed.attempts.length,2);
 runtime(['flow','retry',started.id],1);
 runtime(['flow','clear',started.id,cancelled.id,failed.id,multiple.id,fresh.id,freshAgain.id,parent.id,wrong.id,self.id,observer.id,canceller.id,awaiting.id,awaitingCancelled.id,'--descendants']);
 assert.deepEqual(runtime(['flow','list']).result.instances,[]);
 assert.equal(runtime(['run','show',completed.attempts[1].id]).result.status,'returned','Clearing flow hid its recording');
 assert.equal(invoke('git',['-C',kb,'rev-parse','HEAD']).trim(),brokenRevision,'Runtime changed accepted knowledge');
 console.log('Interactive CLI: idempotent start, foreground worker, manual replies, cancellation, pinned resume, await and independent clearing passed.');
}finally{
 for(const child of children)if(child.exitCode===null&&child.signalCode===null){child.kill('SIGINT');await once(child,'exit');}
 fs.rmSync(temporary,{recursive:true,force:true});
}
