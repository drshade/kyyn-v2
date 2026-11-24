// Installed live-query path: typed plugin discovery, CLI freshness, durable restore,
// a new occurrence, rejected query results, typed failure, deadline cleanup and
// captured configuration. Synthetic local HTTP only; no credentials or user KB.
// Usage: node tools/test-live-query.mjs /absolute/path/to/kyyn-v2
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
const executable=fs.realpathSync(process.argv[2]);
const temporary=fs.mkdtempSync(path.join(os.tmpdir(),'kyyn-live-query-'));
const kb=path.join(temporary,'kb'),provider=path.join(temporary,'provider'),calls=path.join(temporary,'calls');
const env={...process.env,GIT_CONFIG_NOSYSTEM:'1',GIT_CONFIG_GLOBAL:'/dev/null',GIT_AUTHOR_NAME:'Live fixture',GIT_AUTHOR_EMAIL:'fixture@example.invalid',GIT_COMMITTER_NAME:'Live fixture',GIT_COMMITTER_EMAIL:'fixture@example.invalid'};
function invoke(command,args,status=0){const r=spawnSync(command,args,{cwd:temporary,env,encoding:'utf8',timeout:600000});assert.equal(r.status,status,JSON.stringify({command,args,...r}));return r.stdout;}
const cli=(args,status=0)=>JSON.parse(invoke(executable,['--kb',kb,'--json',...args],status));
const runtime=(args,status=0)=>cli(['--nix','/not-installed',...args],status);
const show=id=>runtime(['flow','show',id]).result;
const count=()=>fs.existsSync(calls)?fs.readFileSync(calls,'utf8').trim().split('\n').filter(Boolean).length:0;
const server=spawn(process.execPath,['--input-type=module','-e',`
import http from 'node:http';import fs from 'node:fs';
let count=0;
const server=http.createServer((req,res)=>{fs.appendFileSync(${JSON.stringify(calls)},req.url+'\\n');res.end(String(++count));});
server.listen(0,'127.0.0.1',()=>console.log(server.address().port));
`],{stdio:['ignore','pipe','inherit']});
let port='';for await(const chunk of server.stdout){port+=chunk;if(port.includes('\n'))break;}port=Number(port.trim());
try{
 fs.mkdirSync(path.join(provider,'src'),{recursive:true});
 fs.writeFileSync(path.join(provider,'kyyn-plugin.dhall'),'{ name = "live-fixture", entryModule = "Provider" }');
 fs.writeFileSync(path.join(provider,'src/Provider.hs'),`module Provider where
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import Kyyn.Contract (Contract)
import Kyyn.Plugin
import Kyyn.Plugin.Host
import Kyyn.Plugin.Live
import Kyyn.Validation
connectors :: [Connector]
connectors = [LiveConnector "Live" "Provider.validate" Nothing [LiveQuery "query" "Synthetic bounded query" "Provider.query"]]
validate :: Text -> ValidationReport
validate _ = ValidationReport []
data Answer = Answer Integer | Rejected Text deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
query :: Text -> Integer -> LiveQueryProgram (Either FetchError Answer)
query base value = do
  response <- sendHttp (HttpRequest "GET" (base <> "/" <> Text.pack (show value)) [] "")
  case response of
    Left _ -> pure (Left (FetchError "fixture transport failed"))
    Right (HttpResponse _ _ body)
      | value == -1 -> pure (Left (FetchError "fixture provider failure"))
      | value == -2 -> pure (Right (Rejected "fixture rejected query"))
      | value == -3 -> waitSeconds 120 >> pure (Right (Answer 0))
      | otherwise -> case reads (Text.unpack body) of
          [(number,"")] -> pure (Right (Answer number))
          _ -> pure (Left (FetchError "fixture invalid response"))
`);
 invoke('git',['-C',provider,'init','-q']);invoke('git',['-C',provider,'add','.']);invoke('git',['-C',provider,'commit','-qm','Fixture']);
 cli(['kb','init']);
 const setup=cli(['evolution','new','live-query']).result,target=path.join(setup.path,'target');
 cli(['plugin','install','--from',provider,'--evolution',setup.id]);
 fs.writeFileSync(path.join(target,'plugins/config/live-fixture.dhall'),`[ { name = "local", binding = "live", connector = < Live : Text >.Live "http://127.0.0.1:${port}" } ]`);
 fs.writeFileSync(path.join(target,'src/Conversations.hs'),`module Conversations where
import qualified Agentic as A
import qualified Agentic.Codec as C
import qualified Agentic.Schema as S
import qualified Agentic.Value as V
import Kyyn.Agentic (Flow)
import Kyyn.Interactive (liveQuery)
import qualified Kyyn.Connectors as Connectors
import qualified Kyyn.Plugins.P_live_fixture.Live as Live
import qualified Provider
conversation :: Flow Integer Provider.Answer
conversation = liveQuery (Live.query Connectors.live) A.>>> A.arr (const 0)
  A.>>> A.awaitWith integer integer A.>>> liveQuery (Live.query Connectors.live)
once :: Flow Integer Provider.Answer
once = liveQuery (Live.query Connectors.live)
integer :: C.Codec Integer
integer = C.primitive S.SInteger V.Integer (\\value -> case value of V.Integer n -> Right n; _ -> Left "Expected integer")
`);
 fs.writeFileSync(path.join(setup.path,'change/Evolution.hs'),`module Evolution where
import Kyyn.Workspace.Evolution
import Kyyn.Interactive (createInteractiveRecipe)
import qualified Kyyn.Workspace.Target.InteractiveFlows.Conversations as Flows
import qualified Schema
evolution :: Evolution Schema.Root
evolution = prepare (pure ()) (edit (Rationale "Live query fixture" []) (do
  createInteractiveRecipe (RecipeId "conversation") Flows.conversation
  createInteractiveRecipe (RecipeId "once") Flows.once))
`);
 console.log('Building live-query fixture');
 cli(['evolution','check',setup.id]);cli(['evolution','ready',setup.id]);cli(['evolution','accept',setup.id]);
 const methods=cli(['plugin','connector','method','list','live-fixture','local']);assert.match(JSON.stringify(methods),/Synthetic bounded query/);
 cli(['plugin','connector','method','show','live-fixture','local','query']);
 const fresh=()=>cli(['plugin','connector','query','live-fixture','local','query','--input','+1']);
 const before=count();fresh();fresh();assert.equal(count(),before+2,'CLI must always query');
 cli(['plugin','connector','query','live-fixture','local','query','--input','"wrong"'],1);assert.equal(count(),before+2,'Invalid input reached provider');
 cli(['plugin','connector','method','execute','live-fixture','local','query','--input','+1'],1);
 const normal=cli(['flow','start','conversation','--input','+1']).result;
 const rejected=cli(['flow','start','conversation','--input','-2']).result;
 const failed=cli(['flow','start','once','--input','-1']).result;
 // Corrupt current config after capture; runtime must keep the pinned instance.
 fs.writeFileSync(path.join(kb,'root/plugins/config/live-fixture.dhall'),'deliberately broken current config');
 const baseline=count();runtime(['flow','worker','--once']);
 assert.equal(show(normal.id).status,'waiting');assert.equal(show(rejected.id).status,'waiting');assert.equal(show(failed.id).status,'failed');
 assert.equal(count(),baseline+3);
 runtime(['flow','worker','--once']);assert.equal(count(),baseline+3,'Waiting instance reissued query');
 runtime(['flow','fulfil',normal.id,'--reply','+1']);runtime(['flow','fulfil',rejected.id,'--reply','+1']);
 runtime(['flow','worker','--once']);
 assert.equal(show(normal.id).status,'completed');assert.equal(show(rejected.id).status,'completed');
 assert.equal(count(),baseline+5,'Restore must not reissue successful or rejected query; second occurrence must issue');
 runtime(['flow','retry',failed.id]);runtime(['flow','worker','--once']);assert.equal(count(),baseline+6);
 invoke('git',['-C',kb,'restore','root/plugins/config/live-fixture.dhall']);
 const timeout=cli(['flow','start','once','--input','-3']).result;
 console.log('Checking fixed 60-second adapter deadline and subsequent query');
 const start=Date.now();runtime(['flow','worker','--once']);
 assert.ok(Date.now()-start<80000,'Adapter deadline did not clean up');assert.equal(show(timeout.id).status,'failed');
 assert.match(JSON.stringify(show(timeout.id)),/60-second deadline/);
 fresh();
 console.log('Live query CLI, capture, replay, rejection, retry and deadline journey passed');
}catch(error){console.error(`Retained fixture: ${temporary}`);throw error;}
finally{server.kill('SIGTERM');}
