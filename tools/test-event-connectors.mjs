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
 const config=cli(['plugin','install','--evolution',draft.id,'--from',path.join(repo,'tools/fixtures/event-plugin')]).result.configuration;
 fs.writeFileSync(path.join(kb,config.path),'[ { name = "updates", binding = "updates", connector = < Updates : Integer >.Updates +10 } ]');
 const target=path.join(draft.path,'target');
 fs.writeFileSync(path.join(target,'src/Conversations.hs'),`module Conversations where
import qualified Agentic as A
import Kyyn.Agentic (Flow)
import Kyyn.Interactive (EventRef)
import qualified Kyyn.Connectors as Connectors
import qualified Kyyn.Plugins.P_event_fixture.Updates as Updates
import qualified Events
import Data.Text (Text)
reference = Updates.question Connectors.updates
inputWitness :: EventRef request reply -> request -> ()
inputWitness _ _ = ()
replyWitness :: EventRef request reply -> (reply -> Text) -> ()
replyWitness _ _ = ()
conversation :: Flow () ()
conversation = A.arr (\\_ -> case inputWitness reference (Events.makeRequest "Update please") of () -> replyWitness reference Events.replyText)
`);
 const declaration=`module Evolution where
import Kyyn.Workspace.Evolution
import Kyyn.Interactive (createInteractiveRecipe, withEvents, event)
import qualified Kyyn.Workspace.Target.InteractiveFlows.Conversations as Flows
import qualified Kyyn.Connectors as Connectors
import qualified Kyyn.Plugins.P_event_fixture.Updates as Updates
import qualified Schema
evolution :: Evolution Schema.Root
evolution = prepare (pure ()) (edit (Rationale "Declare the event conversation" [])
  (createInteractiveRecipe (RecipeId "conversation") (withEvents [event (Updates.question Connectors.updates)] Flows.conversation)))
`;
 const evolutionFile=path.join(draft.path,'change/Evolution.hs');fs.writeFileSync(evolutionFile,declaration);
 cli(config.schemaCommand.slice('kyyn-v2 '.length).split(' '));
 cli(config.checkCommand.slice('kyyn-v2 '.length).split(' '));
 fs.writeFileSync(evolutionFile,declaration.replace('[event (Updates.question Connectors.updates)]','[event (Updates.question Connectors.updates), event (Updates.question Connectors.updates)]'));
 assert.match(JSON.stringify(cli(['evolution','check',draft.id],1)),/duplicate event declarations/);
 fs.writeFileSync(evolutionFile,declaration.replace('import qualified Schema','import Kyyn.Types.Plugin (ConnectorInstance)\nimport qualified Schema').replace('Updates.question Connectors.updates','Updates.question (undefined :: ConnectorInstance ())'));
 cli(['evolution','check',draft.id],1);
 fs.writeFileSync(evolutionFile,declaration);
 cli(['evolution','check',draft.id]);
 cli(['evolution','ready',draft.id]);
 cli(['evolution','accept',draft.id]);
 const started=cli(['flow','start','conversation']).result;assert(started);
 const changed=cli(['evolution','new','contract-drift']).result;
 const source=path.join(changed.path,'target/plugins/packages/event-fixture/source/src/Events.hs');
 fs.writeFileSync(source,fs.readFileSync(source,'utf8').replace('question :: Text','question :: Text, revision :: Integer').replace('makeRequest = Request','makeRequest text = Request text 0').replace('(Request question)','(Request question _)'));
 assert.match(JSON.stringify(cli(['evolution','check',changed.id],1)),/request contract differs/);
 cli(['plugin','connector','login','event-fixture','updates']);
 const refused=cli(['evidence','fetch','event-fixture','updates'],1);
 assert.match(JSON.stringify(refused),/source connector/);
 web=spawn(executable,['--kb',kb,'web','serve','--port','0'],{cwd:temporary,env});
 let errors='';web.stderr.on('data',x=>errors+=x);
 const base=await new Promise((resolve,reject)=>{let out='';web.stdout.on('data',x=>{out+=x;const m=out.match(/Serving (http:\/\/127\.0\.0\.1:\d+)/);if(m)resolve(m[1]);});web.on('exit',()=>reject(Error(errors)));});
 const response=await fetch(base+'/plugins/event-fixture');assert.equal(response.status,200);
 const html=await response.text();assert.match(html,/Event connector/);assert.match(html,/Binding: updates/);
 const links=[...html.matchAll(/href="([^"]+)"/g)].map(x=>x[1]).filter(x=>decodeURIComponent(x).includes('/types/Updates/event:'));
 assert.equal(new Set(links).size,6,'Each event request, reply and cursor has a type link');
 for(const link of new Set(links)){const page=await fetch(base+link.replaceAll('&amp;','&'));assert.equal(page.status,200,link);assert.doesNotMatch(await page.text(),/Unknown plugin contract/);}
 console.log('Installed event registration, configuration, acceptance, login and source-fetch refusal passed.');
} finally { if(web){web.kill('SIGTERM');await new Promise(resolve=>web.once('exit',resolve));} fs.rmSync(temporary,{recursive:true,force:true}); }
