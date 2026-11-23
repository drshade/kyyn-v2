// Installed typed event waits: atomic authority refusal, pinned retry, manual
// provenance, invalid/duplicate replies and dispatch visibility. Synthetic only.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
const executable=fs.realpathSync(process.argv[2]),repo=path.resolve(import.meta.dirname,'..');
const temporary=fs.mkdtempSync(path.join(os.tmpdir(),'kyyn-event-waits-')),kb=path.join(temporary,'kb');
const env={...process.env,GIT_CONFIG_NOSYSTEM:'1',GIT_CONFIG_GLOBAL:'/dev/null',GIT_AUTHOR_NAME:'Fixture',GIT_AUTHOR_EMAIL:'fixture@example.invalid',GIT_COMMITTER_NAME:'Fixture',GIT_COMMITTER_EMAIL:'fixture@example.invalid'};
let web;
function cli(args,status=0){console.error(args.join(' '));const r=spawnSync(executable,['--kb',kb,'--json',...args],{cwd:temporary,env,encoding:'utf8',timeout:600000,maxBuffer:16*1024*1024});assert.equal(r.status,status,r.stdout+r.stderr);return JSON.parse(r.stdout);}
const runtime=(args,status=0)=>cli(['--nix','/not-installed',...args],status);
const show=id=>runtime(['flow','show',id]).result;
const pass=()=>runtime(['flow','worker','--once']);
function accept(id){cli(['evolution','check',id]);cli(['evolution','ready',id]);cli(['evolution','accept',id]);}
try {
 cli(['kb','init']);
 const draft=cli(['evolution','new','event-waits']).result;
 const config=cli(['plugin','install','--evolution',draft.id,'--from',path.join(repo,'tools/fixtures/event-plugin')]).result.configuration;
 fs.writeFileSync(path.join(kb,config.path),'[ { name = "updates", binding = "updates", connector = < Updates : Integer >.Updates +10 } ]');
 const target=path.join(draft.path,'target');
 const plugin=path.join(target,'plugins/packages/event-fixture/source/src/Events.hs');
 let source=fs.readFileSync(plugin,'utf8');
 source=source.replace('pure (Right (Cursor config))','error "Dispatch must not run in the wait-only slice"')
   .replace('pure (Right (EventBatch [EventArrival (EventIdentity identity) (Reply question)] (Cursor config)))','error "Polling must not run in the wait-only slice"');
 fs.writeFileSync(plugin,source);
 fs.writeFileSync(path.join(target,'src/Conversations.hs'),`{-# LANGUAGE ScopedTypeVariables, TypeApplications #-}
module Conversations where
import qualified Agentic as A
import qualified Agentic.Codec as C
import qualified Agentic.Schema as S
import qualified Agentic.Value as V
import Control.Monad.Trans.Except (throwE)
import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Agentic (Flow)
import Kyyn.Contract (Contract(..), CompiledContract(..), compileContract)
import Kyyn.Interactive
import Kyyn.Plugin (FetchError(..))
import Kyyn.Types.EventWait (eventRequestCodec)
import Kyyn.Types.KnowledgeBase (EventReference(..))
import qualified Kyyn.Connectors as Connectors
import qualified Kyyn.Plugins.P_event_fixture.Updates as Updates
import qualified Events
reference = Updates.question Connectors.updates
conversation :: Flow () Text
conversation = A.arr (const (Events.makeRequest "Update please")) A.>>> awaitReply reference
  A.>>> A.arr (\\(ReceivedReply source reply) -> case source of
    ManualReply surface -> surface <> ":" <> Events.replyText reply
    ProviderReply binding (EventIdentity identity) -> binding.instanceName <> ":" <> identity <> ":" <> Events.replyText reply)
pollOnly :: Flow () Text
pollOnly = A.arr (const (Events.makeRequest "Update please")) A.>>> awaitReply (Updates.updates Connectors.updates)
  A.>>> A.arr (\\(ReceivedReply _ reply) -> Events.replyText reply)
bare :: Flow () Text
bare = A.arr (const "Other question") A.>>> A.await text text
  where text = C.primitive (S.SString Nothing) V.String (\\v -> case v of V.String t -> Right t; _ -> Left "Expected text")
mixed :: Flow () Text
mixed = (bare A.&&& conversation) A.>>> A.arr snd
badRequest :: Flow () Text
badRequest = forged reference (Events.makeRequest "Question") A.>>> A.arr Events.replyText
forged :: forall request reply. (Contract request, Contract reply) => EventRef request reply -> request -> Flow () reply
forged _ request = case ((,) <$> compileContract (contract @request) <*> compileContract (contract @reply)) of
  Left problem -> A.act (\\_ -> throwE (FetchError (Text.pack (show problem))))
  Right (input,output) -> A.arr (const request) A.>>> A.await
    (eventRequestCodec (EventReference "event-fixture" "Updates" "updates" "question")
      input.description output.description (C.Codec input.codec.schema (const (V.String "wrong request shape")) (const (Right request)))) output.codec
`);
 const imports=`module Evolution where
import Kyyn.Workspace.Evolution
import Kyyn.Interactive
import Kyyn.Evolution (removeRecipe)
import qualified Kyyn.Workspace.Target.InteractiveFlows.Conversations as Flows
import qualified Kyyn.Connectors as Connectors
import qualified Kyyn.Plugins.P_event_fixture.Updates as Updates
import qualified Schema
`;
 fs.writeFileSync(path.join(draft.path,'change/Evolution.hs'),imports+`evolution :: Evolution Schema.Root
evolution = prepare (pure ()) (edit (Rationale "Synthetic event waits" []) $ do
  createInteractiveRecipe (RecipeId "conversation") (withEvents [event (Updates.question Connectors.updates)] Flows.conversation)
  createInteractiveRecipe (RecipeId "pollOnly") (withEvents [event (Updates.updates Connectors.updates)] Flows.pollOnly)
  createInteractiveRecipe (RecipeId "badRequest") (withEvents [event (Updates.question Connectors.updates)] Flows.badRequest)
  createInteractiveRecipe (RecipeId "mixed") Flows.mixed)
`);
 accept(draft.id);
 const conversation=cli(['flow','start','conversation']).result;
 const pollOnly=cli(['flow','start','pollOnly']).result;
 const unauthorized=cli(['flow','start','mixed']).result;
 const malformed=cli(['flow','start','badRequest']).result;
 pass();
 assert.equal(show(conversation.id).status,'waiting');
 assert.equal(show(conversation.id).waits[0].dispatch,'pending');
 assert.equal(show(pollOnly.id).waits[0].dispatch,'not required');
 assert.equal(show(unauthorized.id).retryRequired,true);
 assert.deepEqual(show(unauthorized.id).waits,[],'Mixed unauthorized frontier partially published');
 assert.match(JSON.stringify(show(unauthorized.id).blocked),/updates.*question/);
 assert.equal(show(malformed.id).retryRequired,true);
 assert.deepEqual(show(malformed.id).waits,[],'Malformed event request published');
 const wait=show(conversation.id).waits[0];
 runtime(['flow','fulfil',conversation.id,'--reply','{"answer":7}']);pass();
 assert.equal(show(conversation.id).deliveries[0].outcome,'invalid');
 assert.equal(show(conversation.id).status,'waiting');
 assert.equal(show(conversation.id).attempts.length,1,'Invalid reply reached guest execution');
 runtime(['flow','fulfil',conversation.id,'--key','valid','--reply','{"answer":"Confirmed"}']);
 runtime(['flow','fulfil',conversation.id,'--key','duplicate','--reply','{"answer":"Confirmed"}']);
 runtime(['flow','fulfil',conversation.id,'--key','conflict','--reply','{"answer":"Different"}']);
 pass();
 const completed=show(conversation.id);
 assert.equal(completed.status,'completed');assert.match(completed.result,/cli:Confirmed/);
 assert.deepEqual(completed.deliveries.map(x=>x.outcome),['invalid','accepted','duplicate','conflicting']);
 assert.equal(completed.waits[0].reply.origin.surface,'cli');
 assert.equal(completed.waits[0].dispatch,'pending','Manual fulfil changed dispatch state');
 runtime(['flow','fulfil',pollOnly.id,'--reply','{"answer":"Manual too"}']);pass();
 assert.equal(show(pollOnly.id).status,'completed');
 const fix=cli(['evolution','new','authorize-mixed']).result;
 fs.writeFileSync(path.join(fix.path,'change/Evolution.hs'),imports+`evolution :: Evolution Schema.Root
evolution = prepare (pure ()) (edit (Rationale "Authorize mixed event wait" []) $ do
  removeRecipe (RecipeId "mixed")
  createInteractiveRecipe (RecipeId "mixed") (withEvents [event (Updates.question Connectors.updates)] Flows.mixed))
`);
 accept(fix.id);
 runtime(['flow','retry',unauthorized.id]);pass();
 assert.equal(show(unauthorized.id).retryRequired,true);
 assert.deepEqual(show(unauthorized.id).waits,[],'Retry acquired newer declaration authority');
 const authorized=cli(['flow','start','mixed']).result;pass();
 assert.equal(show(authorized.id).status,'waiting');
 assert.equal(show(authorized.id).waits.length,2);
 web=spawn(executable,['--kb',kb,'web','serve','--port','0'],{cwd:temporary,env});
 let errors='';web.stderr.on('data',x=>errors+=x);
 const base=await new Promise((resolve,reject)=>{let out='';web.stdout.on('data',x=>{out+=x;const m=out.match(/Serving (http:\/\/127\.0\.0\.1:\d+)/);if(m)resolve(m[1]);});web.on('exit',()=>reject(Error(errors)));});
 const html=await (await fetch(base+'/flows/'+authorized.id)).text();assert.match(html,/Dispatch: pending/);
 const done=await (await fetch(base+'/flows/'+conversation.id)).text();assert.match(done,/Manual · cli/);
 assert.equal(show(conversation.id).waits[0].id,wait.id);
 console.log('Typed event waits, payload validation, atomic refusal, pinned retry, manual provenance and dispatch display passed.');
} finally {if(web){web.kill('SIGTERM');await new Promise(resolve=>web.once('exit',resolve));}fs.rmSync(temporary,{recursive:true,force:true});}
