// One recording reducer for live following, seek and playback. Graph addresses
// identify static nodes; occurrence + explicit parent identify dynamic scopes.
export const occurrenceKey = occurrence => JSON.stringify([occurrence.address, occurrence.context]);
export function indexGraph(graph) {
  const items = new Map();
  function visit(nodes) { for (const node of nodes) { items.set(node.id, node); visit(node.items ?? []); } }
  visit(graph.items);
  return {items, addresses: new Map(graph.addressItems.map(x => [x.address, x.item])), bodies: graph.bodies, edges: graph.edges};
}
export function newRecording(graph) {
  return {graph: indexGraph(graph), occurrences: new Map(), selections: new Set(), cursor: -1n, elapsed: 0n, terminal: null};
}
export function reduceEvent(state, record) {
  const sequence = BigInt(record.sequence);
  if (sequence <= state.cursor) return state; // a retried page cannot double-count
  if (sequence !== state.cursor + 1n) throw new Error('The recording has a sequence gap. Reload to read it from the beginning.');
  state.cursor = sequence;
  state.elapsed = BigInt(record.event.elapsedNanos);
  const body = record.event.body;
  if (body.kind !== 'flow') { state.terminal = body; return state; }
  const summary = body.summary, key = occurrenceKey(summary.occurrence);
  if (summary.event.kind === 'entered') {
    if (state.occurrences.has(key)) throw new Error('Duplicate occurrence entry in recording.');
    state.occurrences.set(key, {key, occurrence: summary.occurrence, parent: summary.parent,
      node: summary.node, notes: summary.notes, entered: state.elapsed, terminal: null,
      total: summary.event.total, completedBodies: 0, events: [], item: state.graph.addresses.get(summary.occurrence.address)});
  }
  const scope = state.occurrences.get(key);
  if (!scope) throw new Error('Event without an observed entry in recording.');
  scope.events.push({at: state.elapsed, ...summary.event});
  if (summary.event.kind === 'selected') state.selections.add(summary.event.edge);
  if (['returned', 'failed', 'cancelled'].includes(summary.event.kind)) {
    scope.terminal = summary.event.kind;
    scope.ended = state.elapsed;
    scope.outcome = summary.event.outcome;
    // Only the published element-body root counts, never an arbitrary descendant.
    if (summary.event.kind === 'returned' && scope.parent) {
      const parent = state.occurrences.get(occurrenceKey(scope.parent));
      if (parent && ['each', 'repeat'].includes(parent.node) && state.graph.bodies.some(b =>
        b.owner === parent.occurrence.address && b.bodyRoot === scope.occurrence.address)) parent.completedBodies++;
    }
  }
  return state;
}
// Forward movement visits only newly reached records. Backward seeks rebuild.
export function advance(state, records, through) {
  for (let i = Number(state.cursor + 1n); i < records.length; i++) {
    if (BigInt(records[i].event.elapsedNanos) > through) break;
    reduceEvent(state, records[i]);
  }
  return state;
}
export function replay(graph, records, through) { return advance(newRecording(graph), records, through); }
export function contextText(context) {
  return [...context].reverse().map(([kind, , index, total]) => {
    if (kind === 'each') return `element ${index + 1} of ${total}`;
    if (kind === 'repeat') return `pass ${index + 1}`;
    if (kind === 'call') return `tool call ${total + 1} of turn ${index + 1}`;
    return kind;
  }).join(' · ');
}
const words = value => value.replace(/([a-z])([A-Z])/g, '$1 $2').toLowerCase();
function itemLabel(graph, address) {
  const item = graph.items.get(graph.addresses.get(address));
  return item?.labels?.join(' · ') || item?.nodeKind || address;
}
export function eventText(event, graph) {
  switch (event.kind) {
    case 'entered': return 'Entered' + (event.total === null ? '' : ` · ${event.total} elements`);
    case 'returned': return `Returned · ${words(event.outcome)}`;
    case 'selected': {
      const edge = graph.edges.find(edge => edge.selections.includes(event.edge));
      return `Branch selected · ${edge?.label || event.edge}`;
    }
    case 'callResolved': return `Tool resolved · ${itemLabel(graph, event.binding)} · body ${itemLabel(graph, event.body)}`;
    case 'turned': return `Turn ${event.turn + 1} · ${event.action === 'tools' ? 'tool calls' : 'response'}`;
    case 'outputRejected': return `Output rejected · turn ${event.turn + 1}`;
    case 'drafting': return 'Drafting';
    case 'judged': return 'Judged';
    case 'failed': return 'Failed';
    case 'cancelled': return 'Cancelled';
    default: return words(event.kind);
  }
}
export function nodeState(state, item, stopped) {
  const scopes = [...state.occurrences.values()].filter(x => x.item === item);
  if (!scopes.length) return 'unseen';
  if (scopes.some(x => x.terminal === 'failed')) return 'failed';
  if (scopes.some(x => x.terminal === null)) return stopped ? 'unknown' : 'open';
  if (scopes.some(x => x.terminal === 'cancelled')) return 'cancelled';
  return 'returned';
}
const seconds = nanos => (Number(nanos) / 1e9).toFixed(2) + ' s';
function el(tag, text, css) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (css) node.className = css;
  return node;
}
function button(text, action) { const node = el('button', text); node.type = 'button'; node.onclick = action; return node; }
async function startViewer(initial) {
  const $ = id => document.getElementById(id);
  const graph = initial.header.graph, records = [];
  const nodes = new Map(), edgeNodes = [];
  let live = newRecording(graph), state = live, selected = null, summary = initial;
  let following = initial.status === 'active', playing = false, position = 0n, duration = 0n;
  let initialLoading = true, readError = null;
  let incomplete = false, completePage = false, stopped = false, pollTimer, frame, previous = null;
  const seek = $('run-seek'), play = $('run-play'), follow = $('run-follow'), message = $('run-message');
  // Accessible node buttons remain available even when Mermaid cannot render.
  const fallback = el('div', undefined, 'node-list');
  for (const [id, item] of indexGraph(graph).items) {
    const node = button((item.labels ?? []).join(' · ') || item.nodeKind || 'Flow', () => inspect(id));
    node.dataset.item = id; fallback.append(node);
  }
  $('run-diagram').append(fallback);
  function inspect(item) { selected = item; $('run-inspector').hidden = false; drawInspector(); }
  function drawInspector() {
    const pane = $('run-inspector');
    if (!selected) return;
    const item = live.graph.items.get(selected), scopes = [...state.occurrences.values()].filter(x => x.item === selected);
    pane.replaceChildren(el('h2', (item.labels ?? []).slice(0, 1).join('') || 'Node'));
    const labels = el('details'); labels.append(el('summary', 'Full node label'), el('pre', (item.labels ?? []).join('\n'))); pane.append(labels);
    pane.append(el('p', `${scopes.length} observed occurrence${scopes.length === 1 ? '' : 's'}`));
    if (!scopes.length) pane.append(el('p', 'No occurrence observed at this point.', 'muted'));
    for (const scope of scopes) {
      const detail = el('details', undefined, 'occurrence');
      const outcome = scope.terminal ?? (stopped && completePage && position >= duration ? 'unknown — no terminal observed' : 'no terminal observed');
      detail.open = true;
      detail.append(el('summary', `${words(scope.node)} · ${words(outcome)}`));
      const context = contextText(scope.occurrence.context);
      if (context) detail.append(el('p', context));
      detail.append(el('small', `Address: ${scope.occurrence.address}`));
      detail.append(el('p', `Parent: ${scope.parent ? itemLabel(state.graph, scope.parent.address) : 'none (run root)'}`));
      detail.append(el('p', `Entered at ${seconds(scope.entered)}${scope.ended === undefined ? '' : ` · observed duration ${seconds(scope.ended - scope.entered)}`}`));
      if (scope.node === 'each') detail.append(el('p', `Element bodies returned: ${scope.completedBodies} / ${scope.total}`, 'progress-count'));
      if (scope.node === 'repeat') detail.append(el('p', `Iteration bodies returned: ${scope.completedBodies} · total unknown`, 'progress-count'));
      if (scope.outcome) detail.append(el('p', `Return outcome: ${scope.outcome}`));
      const events = el('ul');
      for (const event of scope.events) {
        events.append(el('li', `${seconds(event.at)} · ${eventText(event, state.graph)}`));
      }
      detail.append(events); pane.append(detail);
    }
  }
  function draw() {
    const atEnd = completePage && position >= duration;
    const ended = atEnd && stopped;
    for (const [item, node] of nodes) {
      node.dataset.state = nodeState(state, item, ended);
      node.classList.toggle('selected-node', item === selected);
    }
    for (const node of fallback.children) node.dataset.state = nodeState(state, node.dataset.item, ended);
    edgeNodes.forEach((node, i) => node.classList.toggle('selected-edge', graph.edges[i]?.selections.some(edge => state.selections.has(edge))));
    seek.max = String(Math.max(0, Math.ceil(Number(duration) / 1e6)));
    seek.value = String(Number(position) / 1e6);
    $('run-time').textContent = `${seconds(position)} / ${seconds(duration)}`;
    play.textContent = playing ? 'Pause' : 'Play'; play.disabled = !!readError || records.length === 0;
    follow.disabled = !!readError || following; follow.textContent = following ? 'Following live' : stopped ? 'Show latest' : 'Follow live';
    const phase = following ? (stopped ? summary.status : 'Live · following') : playing ? 'Playback' : 'Paused';
    message.textContent = readError ?? `${phase} · ${state.cursor + 1n} / ${summary.eventCount} events${!completePage ? ' · loading more…' : ''}${incomplete ? ' · incomplete final record' : ''}`;
    const outcome = $('run-outcome'); outcome.replaceChildren();
    if (state.terminal) {
      const terminal = state.terminal;
      outcome.append(el('strong', `Invocation ${terminal.kind}`, `outcome ${terminal.kind}`));
      if (terminal.kind === 'completed') {
        const link = el('a', `Draft ${terminal.draft}`); link.href = '/evolutions/' + encodeURIComponent(terminal.draft); outcome.append(link);
      }
      for (const diagnostic of terminal.diagnostics ?? []) outcome.append(el('p', diagnostic.message));
    } else if (ended) outcome.append(el('p', 'Recording interrupted. Unfinished occurrences have unknown outcomes.', 'outcome interrupted'));
    else outcome.append(el('p', 'No invocation outcome observed at this point.', 'muted'));
    drawInspector();
  }
  function seekTo(target) {
    following = false; playing = false; initialLoading = false;
    const next = target > duration ? duration : target;
    state = next < position || state === live ? replay(graph, records, next) : advance(state, records, next);
    position = next; draw();
  }
  seek.oninput = () => seekTo(BigInt(seek.value) * 1000000n);
  follow.onclick = () => { following = true; playing = false; state = live; position = duration; draw(); };
  play.onclick = () => {
    following = false; initialLoading = false;
    if (!playing && position >= duration) { position = 0n; state = replay(graph, records, position); }
    playing = !playing; previous = null; draw();
  };
  function tick(now) {
    if (playing) {
      if (previous !== null) {
        position += BigInt(Math.round((now - previous) * Number($('run-speed').value) * 1e6));
        if (position >= duration) { position = duration; playing = false; }
        state = advance(state, records, position); draw();
      }
      previous = now;
    } else previous = null;
    frame = requestAnimationFrame(tick);
  }
  async function poll() {
    try {
      const params = new URLSearchParams({limit: '200'});
      if (live.cursor >= 0n) params.set('after', String(live.cursor));
      const response = await fetch(`/runs/${encodeURIComponent(initial.runId)}/events?${params}`, {cache: 'no-store'});
      if (!response.ok) {
        if (response.status === 404) throw new Error('This recording has been cleared.');
        const error = await response.json();
        throw new Error(error.diagnostics?.map(d => d.message).join('\n') || `Unable to read recording (${response.status}).`);
      }
      const page = await response.json();
      for (const event of page.events) {
        if (BigInt(event.sequence) <= live.cursor) continue;
        reduceEvent(live, event); records.push(event);
        duration = BigInt(event.event.elapsedNanos);
      }
      summary = page.summary; incomplete = page.incompleteTail; completePage = !page.more;
      stopped = summary.status !== 'active';
      if (following || initialLoading) { state = live; position = duration; }
      if (completePage) initialLoading = false;
      draw();
      if (page.more || !stopped) pollTimer = setTimeout(poll, page.more ? 0 : 1000);
    } catch (error) {
      playing = false; readError = error.message; message.textContent = readError;
      message.classList.add('error'); follow.disabled = true; play.disabled = true;
      // Preserve the readable prefix; never turn a failed read into success.
    }
  }
  draw(); frame = requestAnimationFrame(tick); poll();
  window.addEventListener('pagehide', () => { clearTimeout(pollTimer); cancelAnimationFrame(frame); }, {once: true});
  try {
    await new Promise((resolve, reject) => {
      const script = el('script'); script.src = '/_inspection/vendor/mermaid.js';
      script.onload = resolve; script.onerror = reject; document.head.append(script);
    });
    globalThis.mermaid.initialize({startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true,
      flowchart: {htmlLabels: false, useMaxWidth: false}});
    const {svg} = await globalThis.mermaid.render('recorded-flow', initial.header.mermaid);
    const viewport = el('div', undefined, 'graph-viewport'); viewport.innerHTML = svg;
    $('run-diagram').prepend(viewport); fallback.hidden = true;
    const drawing = viewport.querySelector('svg');
    for (const node of drawing.querySelectorAll('.node, .cluster')) {
      const localId = node.id.replace(/^recorded-flow-/, '');
      const id = node.classList.contains('cluster') ? localId : localId.replace(/^flowchart-/, '').replace(/-\d+$/, '');
      const item = live.graph.items.get(id); if (!item) continue;
      nodes.set(item.id, node); node.dataset.item = item.id; node.setAttribute('role', 'button'); node.setAttribute('tabindex', '0');
      node.setAttribute('aria-label', (item.labels ?? []).join(' · ') || 'Flow node');
      const select = event => { event.stopPropagation(); inspect(item.id); draw(); };
      node.onclick = select; node.onkeydown = event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); select(event); } };
    }
    edgeNodes.push(...drawing.querySelectorAll('.edgePath path, path.flowchart-link'));
    let scale = 1; const bounds = drawing.viewBox.baseVal;
    const resize = () => { drawing.style.width = bounds.width * scale + 'px'; drawing.style.height = bounds.height * scale + 'px'; };
    const fit = () => { scale = (viewport.clientWidth - 24) / bounds.width; resize(); };
    $('run-fit').onclick = fit;
    $('run-zoom-in').onclick = () => { scale = Math.min(4, scale * 1.3); resize(); };
    $('run-zoom-out').onclick = () => { scale = Math.max(.05, scale / 1.3); resize(); };
    fit(); draw();
  } catch (error) {
    $('run-diagram').prepend(el('p', 'Diagram unavailable; inspect the recorded nodes below.', 'muted'));
    fallback.hidden = false;
  }
}
if (typeof document !== 'undefined') {
  const data = document.getElementById('run-data');
  if (data) startViewer(JSON.parse(data.value)).catch(error => { document.getElementById('run-message').textContent = error.message; });
}
