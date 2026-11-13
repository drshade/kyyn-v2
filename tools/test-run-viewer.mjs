// Pure viewer projection: explicit occurrence/parent/body relations, unknown
// terminals, zero each, repeat progress, idempotent polling and seek equivalence.
import assert from 'node:assert/strict';
import {newRecording, reduceEvent, replay, occurrenceKey, nodeState, advance, contextText, eventText} from '../host/kyyn/web/run-viewer.mjs';
const graph = {root:'root',items:[{id:'root',kind:'box',labels:['Run'],items:[
  {id:'each',kind:'box',labels:['Each'],items:[{id:'body',kind:'node',nodeKind:'step',labels:['Body']}]},
  {id:'call',kind:'node',nodeKind:'tool',labels:['Helper " </script> <img src=x onerror=alert(1)>']},
  {id:'junction',kind:'node',nodeKind:'junction',labels:[]}]}],
  edges:[{from:'each',to:'call',style:'flow',label:'chosen',selections:['branch-left']}],
  addressItems:[{address:'$',item:'root'},{address:'each',item:'each'},{address:'body',item:'body'},{address:'call',item:'call'}],
  bodies:[{owner:'each',binding:null,bodyRoot:'body'}]};
const occurrence = (address, context=[]) => ({address,context});
const root=occurrence('$'), each=occurrence('each'), first=occurrence('body',[['each','each',0]]), second=occurrence('body',[['each','each',1]]);
let seq=0;
const flow=(occ,parent,node,event)=>({sequence:String(seq++),event:{elapsedNanos:String(BigInt(seq)*1000000000n),body:{kind:'flow',summary:{occurrence:occ,parent,node,notes:[],event}}}});
const records=[flow(root,null,'run',{kind:'entered',total:null}),flow(each,root,'each',{kind:'entered',total:2}),
  flow(first,each,'pure',{kind:'entered',total:null}), flow(first,each,'pure',{kind:'returned',outcome:'completed'}),
  flow(second,each,'pure',{kind:'entered',total:null}), flow(each,root,'each',{kind:'returned',outcome:'completed'}),
  flow(root,null,'run',{kind:'returned',outcome:'completed'})];
const live=records.reduce(reduceEvent,newRecording(graph));
assert.equal(live.occurrences.get(occurrenceKey(each)).completedBodies,1);
assert.equal(live.occurrences.get(occurrenceKey(second)).terminal,null,'Ancestor terminal cannot close child');
assert.equal(nodeState(live,'body',true),'unknown');
assert.equal(nodeState(live,'body',false),'open');
assert.equal(nodeState(live,'junction',true),'unseen');
assert.equal(live.terminal,null,'Root return is not invocation completion');
assert.deepEqual(live,replay(graph,records,7000000000n));
const count=live.occurrences.size;
reduceEvent(live,records.at(-1));assert.equal(live.occurrences.size,count);
assert.throws(()=>reduceEvent(live,{...records[0],sequence:'999'}),/sequence gap/);
const middle=replay(graph,records,3500000000n);
assert.equal(middle.occurrences.get(occurrenceKey(each)).completedBodies,0);
assert.equal(middle.occurrences.size,3);
seq=0;
const zero=[flow(root,null,'run',{kind:'entered',total:null}),flow(each,root,'each',{kind:'entered',total:0}),flow(each,root,'each',{kind:'returned',outcome:'completed'})].reduce(reduceEvent,newRecording(graph));
assert.equal(zero.occurrences.get(occurrenceKey(each)).total,0);
assert.equal(zero.occurrences.get(occurrenceKey(each)).completedBodies,0);
seq=0;
const repeated=[flow(root,null,'run',{kind:'entered',total:null}),flow(each,root,'repeat',{kind:'entered',total:null}),flow(first,each,'pure',{kind:'entered',total:null}),flow(first,each,'pure',{kind:'returned',outcome:'completed'})].reduce(reduceEvent,newRecording(graph));
assert.equal(repeated.occurrences.get(occurrenceKey(each)).total,null);
assert.equal(repeated.occurrences.get(occurrenceKey(each)).completedBodies,1);
seq=0;
const call=occurrence('call');
const rejected=[flow(root,null,'run',{kind:'entered',total:null}),flow(call,root,'call',{kind:'entered',total:null}),
 flow(call,root,'call',{kind:'callResolved',binding:'helper',body:'body'}),flow(call,root,'call',{kind:'returned',outcome:'invalidInput'})].reduce(reduceEvent,newRecording(graph));
assert.equal(rejected.occurrences.size,2,'A resolved call does not imply body entry');
assert.equal(rejected.occurrences.get(occurrenceKey(call)).outcome,'invalidInput');
const incremental=newRecording(graph);
advance(incremental,records,3500000000n);
assert.deepEqual(incremental,middle);
advance(incremental,records,7000000000n);
assert.deepEqual(incremental,live);
// A forward tick must not reread old records, even with a long elapsed timeline.
const unreadablePast = records.map((r,i) => new Proxy(r,{get(target,key){if(i<records.length)throw Error('re-read past event');return target[key];}}));
advance(incremental,unreadablePast,8000000000n);
assert.equal(contextText([['repeat','x',0],['each','y',1,2]]),'element 2 of 2 · pass 1');
assert.equal(contextText([['call','x',1,2,'call-id']]),'tool call 3 of turn 2');
assert.equal(eventText({kind:'turned',turn:0,action:'tools'},live.graph),'Turn 1 · tool calls');
console.log('Run viewer: live/seek equivalence, incremental playback, body-root counts, unknown outcomes and readable occurrence fields passed.');
