// Continuous instance projection: canonical keys, per-attempt scopes, replay,
// mixed turns, failure prefixes and graph integrity. No providers or DOM required.
import assert from 'node:assert/strict';
import {newFlowProjection, addAttempt, reduceAttempt, finishAttempt, flowNodeState} from '../host/kyyn/web/flow-projection.mjs';
const graph = {items:[{id:'node',kind:'node',labels:['Step']}],addressItems:[{address:'flow',item:'node'}],edges:[],bodies:[]};
const header = {graph,instance:'conversation',mermaid:'flowchart LR\nnode[Step]'};
const state = newFlowProjection('conversation');
function attempt(id, context = []) {
  addAttempt(state,id,header);
  let sequence = 0;
  return (event,operation = null) => {
    const record = {sequence:String(sequence++),event:{elapsedNanos:String(sequence * 100),body:{kind:'flow',operation,
      summary:{occurrence:{address:'flow',context},parent:null,node:'draft',notes:[],event}}}};
    reduceAttempt(state,id,record); return record;
  };
}
const entered = {kind:'entered',total:null}, returned = {kind:'returned',outcome:'completed'};
const live = operation => ({kind:'executing',operation:{kind:'keyed',operation}});
const restored = operation => ({kind:'restored',operation});
const key = turn => ({opaque:['upstream',turn]});
const close = id => finishAttempt(state,id,{summary:{status:'suspended'},more:false,incompleteTail:false});
let emit = attempt('first');
emit(entered);emit(live({turn:0}),key(0));emit({kind:'turned',turn:0,action:'response'});emit(returned);close('first');
assert.equal(state.operations.size,1);assert.equal(state.episodes.length,1);
emit = attempt('second');emit(entered);emit(restored({turn:0}),key(0));emit(live({turn:1}),key(1));
assert.equal(flowNodeState(state,'node'),'open');
const final = emit(returned);reduceAttempt(state,'second',final);close('second');
assert.equal(state.operations.size,2);assert.equal(state.episodes.length,2);
assert.equal([...state.operations.values()].filter(x=>x.completed).length,2);
assert.equal(state.operations.values().next().value.restorations.length,1);
// A restored reply is new logical progress, although its request suspended before.
emit = attempt('wait-miss');emit(entered);emit({kind:'suspended'});close('wait-miss');
emit = attempt('wait-reply');emit(entered);emit(restored('wait'),{opaque:'reply'});emit(returned);close('wait-reply');
assert.equal([...state.operations.values()].filter(x=>x.completed).length,3);
// Same raw action occurrence on two resumes represents two live selections.
for (const id of ['raw-one','raw-two']) {emit=attempt(id);emit(entered);emit({kind:'executing',operation:{kind:'action'}});emit(returned);close(id);}
assert.equal(state.episodes.length,4);assert.equal(state.operations.size,3);
// A prefix interrupted before Executing is unknown, never guessed as replay/live.
emit=attempt('prefix');emit(entered);emit({kind:'drafting'});close('prefix');
assert.equal(state.episodes.length,4);
// Selection itself does not prove a callback ran or completed.
emit=attempt('interrupted');emit(entered);emit(live('effect'),{opaque:'interrupted'});close('interrupted');
assert.equal(state.episodes.at(-1).terminal,null);assert.equal(flowNodeState(state,'node'),'unknown');
// A failed episode remains visible even if a retry later succeeds.
emit=attempt('failure');emit(entered);emit(live('effect'),{opaque:'retry'});emit({kind:'failed'});close('failure');
emit=attempt('retry');emit(entered);emit(live('effect'),{opaque:'retry'});emit(returned);close('retry');
assert.equal(flowNodeState(state,'node'),'failed');
assert.deepEqual(state.episodes.slice(-2).map(x=>x.terminal),['failed','returned']);
assert.equal([...state.operations.values()].find(x=>x.episodes.length===2).completed,true);
// Opaque canonical identities survive changed Each totals; the browser does not project them.
emit=attempt('each-one',[['each','flow',0,2]]);emit(entered);emit(live('effect'),{z:1,a:'same-key'});emit(returned);close('each-one');
emit=attempt('each-two',[['each','flow',0,7]]);emit(entered);emit(restored('effect'),{a:'same-key',z:1});emit(returned);close('each-two');
assert.equal([...state.operations.values()].find(x=>x.identity.includes('same-key')).restorations.length,1);
assert.throws(()=>addAttempt(state,'different',{...header,graph:{...graph,items:[]}}),/graph differs/);
assert.throws(()=>addAttempt(state,'foreign',{...header,instance:'other'}),/another flow/);
emit=attempt('missing-key');emit(entered);assert.throws(()=>emit(restored('effect')),/identity is missing/);
assert.equal(state.attempts.get('missing-key').cursor,0n);
console.log('Continuous projection: mixed replay/live turns, replies, raw actions, unknown prefixes, retry history, opaque identities and graph integrity passed.');
// Interleaved parallel branches classify independently; repeat/call keys stay distinct.
const parallel = newFlowProjection('parallel');
const parallelGraph = {...graph,items:[{id:'a'},{id:'b'},{id:'root'}],addressItems:[{address:'root',item:'root'},{address:'a',item:'a'},{address:'b',item:'b'}]};
addAttempt(parallel,'parallel-attempt',{...header,instance:'parallel',graph:parallelGraph});
let sequence = 0;
const observe = (address,event,operation=null) => reduceAttempt(parallel,'parallel-attempt',{
  sequence:String(sequence++),event:{elapsedNanos:String(sequence),body:{kind:'flow',operation,summary:{
    occurrence:{address,context:[]},parent:address==='root'?null:{address:'root',context:[]},node:'effect',notes:[],event}}}});
observe('root',entered);observe('a',entered);observe('b',entered);
observe('a',restored('effect'),{opaque:['call',0]});observe('b',live('effect'),{opaque:['call',1]});
assert.equal(flowNodeState(parallel,'a'),'restored');assert.equal(flowNodeState(parallel,'b'),'open');
observe('a',returned);observe('b',returned);observe('root',returned);
assert.equal(parallel.operations.size,2);assert.equal(parallel.episodes.length,1);
assert.equal([...parallel.operations.values()].filter(x=>x.completed).length,2);
console.log('Parallel restored/live branches retain independent classifications and call identities.');
