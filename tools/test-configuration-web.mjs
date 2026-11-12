// Installed configuration inspection: snapshot-selected plugin origins/contracts,
// source and sink instances, output wiring, model names without stored secrets,
// local taps and read-only GETs. Uses no external model, fetch or publication.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
import {once} from 'node:events';
const executable=fs.realpathSync(process.argv[2]),repository=fs.realpathSync(process.argv[3]||'.');
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'kyyn-configuration-web-')),kb=path.join(temp,'kb');
const env={...process.env,GIT_CONFIG_NOSYSTEM:'1',GIT_CONFIG_GLOBAL:'/dev/null',GIT_AUTHOR_NAME:'Configuration fixture',GIT_AUTHOR_EMAIL:'fixture@example.invalid',GIT_COMMITTER_NAME:'Configuration fixture',GIT_COMMITTER_EMAIL:'fixture@example.invalid'};
let server;
const secret='CONFIGURATION_SECRET_SENTINEL_NOT_FOR_HTML';
function cli(args,input){console.error('Configuration web: '+args.join(' '));const r=spawnSync(executable,['--kb',kb,'--json',...args],{env,encoding:'utf8',input,timeout:600000,maxBuffer:16*1024*1024});assert.equal(r.status,0,r.stderr+r.stdout);return JSON.parse(r.stdout).result;}
function head(){return spawnSync('git',['-C',kb,'rev-parse','HEAD'],{encoding:'utf8'}).stdout.trim();}
try {
 cli(['kb','init']);cli(['secret','set','fixture-credential'],secret);
 const d=cli(['evolution','new','configuration']);const target=path.join(d.path,'target');
 cli(['plugin','install','--evolution',d.id,'--from',repository,'--path','plugins/local-file']);
 fs.writeFileSync(path.join(target,'src/Reporting.hs'),`module Reporting where
import Data.Text (Text)
import GHC.Generics (Generic)
import Kyyn.Schema
import KyynQueryBindings (Query)
data Heading = Heading { title :: Text } deriving stock Generic deriving anyclass Contract
metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] []
page :: Heading -> Query Text
page (Heading title) = pure title
`);
 const manifest=path.join(target,'kb.dhall');
 const original=fs.readFileSync(manifest,'utf8');
 fs.writeFileSync(manifest,original
  .replace('model = None Model','model = Some { provider = < OpenAI | Anthropic >.Anthropic, model = "fixture-model", credential = "fixture-credential" }')
  .replace('queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }','queries = [{ name = "page", description = "Page renderer", implementation = "Reporting.page", inputType = "Reporting.Heading", inputMetadata = "Reporting.metadata", resultType = "Data.Text.Text", resultMetadata = "Reporting.metadata" }]')
  .replace('outputs = [] : List { name : Text, description : Text, query : Text, sink : { plugin : Text, instanceName : Text, method : Text } }','outputs = [{ name = "website", description = "Accepted output", query = "page", sink = { plugin = "local-file", instanceName = "website", method = "publish" } }]'));
 const config='let Connector = < Folder : { directory : Text, recursive : Bool } | File : { path : Text } >\nin [{ name = "website", binding = "website", connector = Connector.File { path = "published/index.html" } }, { name = "documents", binding = "documents", connector = Connector.Folder { directory = "documents", recursive = False } }]';
 fs.writeFileSync(path.join(target,'plugins/config/local-file.dhall'),config);
 cli(['evolution','check',d.id]);cli(['evolution','ready',d.id]);cli(['evolution','accept',d.id]);
 const accepted=head();
 const captureEntries=()=>fs.readdirSync(path.join(kb,'.kyyn/evidence'),{recursive:true}).sort();
 const capturesBefore=captureEntries();
 server=spawn(executable,['--kb',kb,'web','serve','--port','0'],{env});
 const base=await new Promise((resolve,reject)=>{let out='';server.stdout.on('data',x=>{out+=x;const m=out.match(/Serving (http:\/\/127\.0\.0\.1:\d+)/);if(m)resolve(m[1]);});server.on('exit',()=>reject(new Error('Server exited')));});
 async function page(url,status=200){const r=await fetch(base+url);const text=await r.text();assert.equal(r.status,status,text);assert(!text.includes(secret));return text;}
 const index=await page('/');assert(index.includes('/plugins/local-file'));assert(index.includes('/outputs/website'));assert(index.includes('fixture-model'));assert(index.includes('fixture-credential'));assert(index.includes('Local discovery configuration'));assert(index.includes('Not synced'));
 const plugin=await page('/plugins/local-file');assert(plugin.includes('Pinned revision'));assert(plugin.includes('plugins/local-file'));assert(plugin.includes('Source connector'));assert(plugin.includes('Sink connector'));assert(plugin.includes('Captured methods'));assert(plugin.includes('content'));assert(plugin.includes('published/index.html'));assert(plugin.includes('/connectors/local-file/documents'));assert(!plugin.includes('/connectors/local-file/website'));
 assert((await page('/plugins/local-file/types/Folder/configuration/LocalFile.Types.FolderConfig')).includes('recursive'));
 assert((await page('/plugins/local-file/types/Folder/payload/LocalFile.Types.Document')).includes('text'));
 const output=await page('/outputs/website');assert(output.includes('Accepted output'));assert(output.includes('/queries/page'));assert(output.includes('/plugins/local-file'));assert(output.includes('website / publish'));assert(output.includes('/outputs/website/types/input/Reporting.Heading'));
 assert((await page('/outputs/website/types/input/Reporting.Heading')).includes('title'));
 await page('/plugins/missing',404);await page('/outputs/missing',404);await page('/plugins/local-file/types/File/payload/LocalFile.Types.Document',404);await page('/outputs/website/types/input/Schema.Root',404);
 const draft=cli(['evolution','new','configuration-draft']);
 const draftManifest=path.join(draft.path,'target/kb.dhall');fs.writeFileSync(draftManifest,fs.readFileSync(draftManifest,'utf8').replace('Accepted output','Draft output').replace('fixture-model','draft-model'));
 const draftConfig=path.join(draft.path,'target/plugins/config/local-file.dhall');fs.writeFileSync(draftConfig,config.replace('published/index.html','published/draft.html'));
 cli(['evolution','check',draft.id]);
 const selector='?evolution='+draft.id;
 assert((await page('/outputs/website'+selector)).includes('Draft output'));assert(!(await page('/outputs/website')).includes('Draft output'));
 assert((await page('/plugins/local-file'+selector)).includes('published/draft.html'));assert(!(await page('/plugins/local-file')).includes('published/draft.html'));
 const draftIndex=await page('/'+selector);assert(draftIndex.includes('draft-model'));assert(draftIndex.includes('Local discovery configuration'));assert(draftIndex.includes('/plugins/local-file'+selector));
 assert.equal(head(),accepted);assert(!fs.existsSync(path.join(kb,'published')));assert.deepEqual(captureEntries(),capturesBefore);
 console.log('Configuration inspection journey passed: captured plugins/contracts, output wiring, model references, local taps, snapshot isolation and read-only GETs.');
} finally {if(server&&server.exitCode===null){server.kill();await once(server,'exit');}fs.rmSync(temp,{recursive:true,force:true});}
