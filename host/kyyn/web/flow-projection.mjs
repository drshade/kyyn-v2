import {indexGraph, occurrenceKey} from './run-viewer.mjs';

// Structural JSON equality for opaque upstream keys, never a local key projection.
export const valueKey = value => JSON.stringify(value, function (_, item) {
  return item && typeof item === 'object' && !Array.isArray(item)
    ? Object.fromEntries(Object.keys(item).sort().map(key => [key, item[key]])) : item;
});
export function newFlowProjection(instance) {
  return {instance, graph: null, header: null, attempts: new Map(), operations: new Map(), episodes: [], gaps: new Map()};
}
export function addAttempt(state, id, header) {
  if (state.attempts.has(id)) return state.attempts.get(id);
  if (header.instance !== state.instance) throw new Error('Recording belongs to another flow instance.');
  if (!state.header) {state.header = header; state.graph = indexGraph(header.graph);}
  if (valueKey(header.graph) !== valueKey(state.header.graph)) throw new Error('Captured graph differs from the first readable attempt.');
  const attempt = {id, cursor: -1n, scopes: new Map(), closed: false, status: 'active', incomplete: false, more: true};
  state.attempts.set(id, attempt);
  return attempt;
}
function logicalOperation(state, key, summary) {
  const identity = valueKey([state.instance, key]);
  if (!state.operations.has(identity)) state.operations.set(identity, {identity, item: state.graph.addresses.get(summary.occurrence.address), completed: false, episodes: [], restorations: []});
  return state.operations.get(identity);
}
export function reduceAttempt(state, id, record) {
  const attempt = state.attempts.get(id), sequence = BigInt(record.sequence);
  if (sequence <= attempt.cursor) return;
  if (sequence !== attempt.cursor + 1n) throw new Error('Recording has a sequence gap.');
  const body = record.event.body, elapsed = BigInt(record.event.elapsedNanos);
  if (body.kind !== 'flow') {attempt.cursor = sequence; attempt.terminal = body; return;}
  const summary = body.summary, event = summary.event, key = occurrenceKey(summary.occurrence);
  let scope = attempt.scopes.get(key);
  if (event.kind === 'entered') {
    if (scope) throw new Error('Duplicate scope entry.');
    if (summary.parent && !attempt.scopes.has(occurrenceKey(summary.parent))) throw new Error('Missing parent scope.');
    scope = {key, summary, item: state.graph.addresses.get(summary.occurrence.address), events: [], episodes: [], terminal: null, entered: elapsed, classified: false};
    attempt.scopes.set(key, scope);
  }
  if (!scope) throw new Error('Missing scope entry.');
  const keyed = event.kind === 'restored' || (event.kind === 'executing' && event.operation.kind === 'keyed');
  if (keyed && body.operation == null) throw new Error('Canonical operation identity is missing.');
  if (!keyed && body.operation != null) throw new Error('Unexpected operation identity on a non-keyed event.');
  scope.events.push({sequence: record.sequence, elapsed, event});
  if (event.kind === 'executing') {
    const logical = keyed ? logicalOperation(state, body.operation, summary) : null;
    const episode = {id: `${id}:${sequence}`, attempt: id, scope, item: scope.item, logical, operation: event.operation,
      selected: elapsed, terminal: null, ended: null};
    scope.classified = true; scope.episodes.push(episode); state.episodes.push(episode);
    if (logical) {logical.episodes.push(episode); logical.latest = episode;}
  }
  if (event.kind === 'restored') {
    const logical = logicalOperation(state, body.operation, summary);
    logical.completed = true;
    const restoration = {attempt: id, sequence: record.sequence, elapsed, scope, operation: event.operation, terminal: 'restored'};
    logical.restorations.push(restoration); logical.latest = restoration;
    scope.classified = true;
  }
  // A model can restore earlier turns and execute another within this same scope.
  // Turned closes only its matching live turn; it does not close the draft scope.
  if (event.kind === 'turned' || event.kind === 'judged') {
    for (const episode of scope.episodes) {
      if (episode.operation.kind === 'keyed' && ((event.kind === 'turned' && episode.operation.operation?.turn === event.turn) || (event.kind === 'judged' && episode.operation.operation === 'judge')) && !episode.terminal) finish(episode, 'returned', elapsed);
    }
  }
  if (['returned', 'failed', 'cancelled', 'suspended'].includes(event.kind)) {
    scope.terminal = event.kind;
    scope.ended = elapsed;
    for (const episode of scope.episodes) if (!episode.terminal) finish(episode, event.kind, elapsed);
  }
  attempt.cursor = sequence;
}
function finish(episode, terminal, elapsed) {
  episode.terminal = terminal; episode.ended = elapsed;
  if (terminal === 'returned' && episode.logical) episode.logical.completed = true;
}
export function finishAttempt(state, id, page) {
  const attempt = state.attempts.get(id);
  attempt.status = page.summary.status;
  attempt.more = page.more;
  attempt.incomplete = page.incompleteTail;
  attempt.closed = !page.more && attempt.status !== 'active';
  if (attempt.incomplete) state.gaps.set(id, 'Incomplete final record; only the readable prefix is shown.');
}
export function flowNodeState(state, item) {
  const operations = [...state.operations.values()].filter(op => op.item === item).map(op => op.latest);
  const plain = state.episodes.filter(episode => episode.item === item && !episode.logical).at(-1);
  const latest = [...operations, ...(plain ? [plain] : [])];
  if (latest.length) return combine(latest.map(episode => episode.terminal ?? (state.attempts.get(episode.attempt).closed ? 'unknown' : 'open')));
  // Structural nodes have real terminals too, but an older suspension must not
  // override a later returned scope. Scope identity is local to an attempt.
  for (const attempt of [...state.attempts.values()].reverse()) {
    const scopes = [...attempt.scopes.values()].filter(scope => scope.item === item);
    if (scopes.length) return combine(scopes.map(scope => scope.terminal ?? 'unknown'));
  }
  return 'unseen';
}
function combine(states) {
  return ['open','failed','unknown','cancelled','suspended','returned','restored'].find(status => states.includes(status)) ?? 'unknown';
}
