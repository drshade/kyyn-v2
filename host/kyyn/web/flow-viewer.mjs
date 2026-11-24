import {compactFlow} from './inspection.mjs';
import {eventText, contextText} from './run-viewer.mjs';
import {newFlowProjection, addAttempt, reduceAttempt, finishAttempt, flowNodeState} from './flow-projection.mjs';

function disclosureKey(node) {
  const owner = node.closest('[data-wait]');
  return JSON.stringify([owner?.dataset.wait ?? '', node.querySelector('summary')?.textContent]);
}
export function refreshSnapshot(current, incoming) {
  const selection = document.getSelection();
  if (selection && !selection.isCollapsed && current.contains(selection.anchorNode)) return false;
  const scroll = window.scrollY;
  const opened = new Set([...current.querySelectorAll('details[open]')].map(disclosureKey));
  const focused = current.contains(document.activeElement) && document.activeElement.closest('details');
  const focusKey = focused && disclosureKey(focused);
  current.dataset.finished = incoming.dataset.finished;
  current.replaceChildren(...incoming.childNodes);
  for (const detail of current.querySelectorAll('details')) {
    if (opened.has(disclosureKey(detail))) detail.open = true;
    if (focusKey === disclosureKey(detail)) detail.querySelector('summary')?.focus({preventScroll: true});
  }
  window.scrollTo({top: scroll, behavior: "instant"});
  return true;
}
class RetryableRead extends Error {}
function element(doc, tag, text, css) {
  const node = doc.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (css) node.className = css;
  return node;
}
export function mountFlowViewer(doc = document, fetchPage = fetch) {
  const snapshot = doc.querySelector('#flow-snapshot');
  if (!snapshot) return;
  const $ = id => doc.getElementById(id), el = (tag, text, css) => element(doc, tag, text, css);
  const follow = $('flow-follow'), message = $('flow-message'), projection = newFlowProjection(snapshot.dataset.instance);
  const diagram = $('flow-diagram'), inspector = $('flow-inspector'), nodes = new Map();
  const attempted = new Set(), retries = new Map();
  let stopped = false, pending = false, complete = false, timer, selected = null, rendered = false;
  const seconds = value => (Number(value) / 1e9).toFixed(2) + ' s';
  function inspect(item) {selected = item; inspector.hidden = false; drawInspector();}
  function drawInspector() {
    if (!selected || !projection.graph) return;
    const item = projection.graph.items.get(selected);
    const expanded = new Set([...inspector.querySelectorAll('details[open]')].map(node => node.dataset.key));
    const content = [el('h2', item.labels?.[0] || item.nodeKind || 'Flow')];
    const label = el('details'); label.dataset.key = 'label';
    label.append(el('summary', 'Full node label'), el('pre', (item.labels ?? []).join('\n'))); content.push(label);
    const operations = [...projection.operations.values()].filter(op => op.item === selected);
    const episodes = projection.episodes.filter(episode => episode.item === selected);
    content.push(el('p', `${operations.filter(op => op.completed).length} completed keyed operations · ${episodes.length} live selections`));
    for (const episode of episodes) {
      const detail = el('details'); detail.dataset.key = episode.id;
      const outcome = episode.terminal ?? (projection.attempts.get(episode.attempt).closed ? 'unknown' : 'no terminal observed');
      detail.append(el('summary', `Live selection · ${outcome}`));
      detail.append(el('p', 'Selected for execution; this notification alone does not establish that the callback ran.'));
      const link = el('a', `Attempt ${episode.attempt}`); link.href = `/runs/${encodeURIComponent(episode.attempt)}`; detail.append(link);
      const context = contextText(episode.scope.summary.occurrence.context);
      if (context) detail.append(el('p', context));
      detail.append(el('p', `Selected at ${seconds(episode.selected)} within this attempt${episode.ended == null ? '' : ` · terminal at ${seconds(episode.ended)}`}`));
      content.push(detail);
    }
    for (const operation of operations) {
      if (!operation.restorations.length) continue;
      const detail = el('details'); detail.dataset.key = operation.identity;
      detail.append(el('summary', `${operation.restorations.length} restoration${operation.restorations.length === 1 ? '' : 's'} · one logical operation`));
      if (!operation.episodes.length) detail.append(el('p', 'Completion is known from restoration. Its original execution time was not observed.'));
      for (const restore of operation.restorations) {
        const link = el('a', `Attempt ${restore.attempt} · ${eventText({kind:'restored', operation:restore.operation}, projection.graph)}`);
        link.href = `/runs/${encodeURIComponent(restore.attempt)}`;
        const paragraph = el('p'); paragraph.append(link); detail.append(paragraph);
      }
      content.push(detail);
    }
    for (const attempt of projection.attempts.values()) {
      for (const scope of attempt.scopes.values()) {
        if (scope.item !== selected) continue;
        const detail = el('details'); detail.dataset.key = `${attempt.id}:${scope.key}`;
        detail.append(el('summary', `Attempt ${attempt.id} · ${scope.terminal ?? 'unknown'}${scope.classified ? '' : ' · no operation classification'}`));
        const list = el('ul');
        for (const record of scope.events) list.append(el('li', `${seconds(record.elapsed)} · ${eventText(record.event, projection.graph)}`));
        detail.append(list); content.push(detail);
      }
    }
    inspector.replaceChildren(...content);
    for (const detail of inspector.querySelectorAll('details')) detail.open = expanded.has(detail.dataset.key);
  }
  function draw() {
    for (const [id, elements] of nodes) for (const node of elements) {
      node.dataset.state = flowNodeState(projection, id);
      node.classList.toggle('selected-node', id === selected);
    }
    diagram.classList.add('motion-enabled');
    diagram.classList.toggle('motion-running', follow.checked && !complete);
    const completed = [...projection.operations.values()].filter(op => op.completed).length;
    $('flow-progress').textContent = `${completed} completed keyed operations · ${projection.episodes.length} live selections · ${projection.attempts.size} readable attempts`;
    $('flow-gaps').replaceChildren(...[...projection.gaps, ...retries].map(([id, text]) => el('p', `Attempt ${id}: ${text}`, 'diagnostic')));
    if (!doc.getSelection()?.toString()) drawInspector();
  }
  async function render() {
    if (rendered || !projection.header) return;
    rendered = true;
    const fallback = el('div', undefined, 'node-list');
    function register(id, node) {
      if (!nodes.has(id)) nodes.set(id, []);
      nodes.get(id).push(node); node.dataset.item = id;
      const choose = event => {event.stopPropagation(); inspect(id); draw();};
      node.onclick = choose;
      node.onkeydown = event => {if (event.key === 'Enter' || event.key === ' ') {event.preventDefault(); choose(event);}};
    }
    for (const [id,item] of projection.graph.items) {
      const button = el('button', item.labels?.[0] || item.nodeKind || 'Flow'); button.type = 'button';
      register(id,button); fallback.append(button);
    }
    diagram.append(fallback);
    try {
      if (!globalThis.mermaid) await new Promise((resolve,reject) => {
        const script = el('script'); script.src = '/_inspection/vendor/mermaid.js';
        script.onload = resolve; script.onerror = reject; doc.head.append(script);
      });
      globalThis.mermaid.initialize({startOnLoad:false, securityLevel:'strict', suppressErrorRendering:true,
        flowchart:{htmlLabels:true,useMaxWidth:false}});
      const {svg} = await globalThis.mermaid.render('conversation-flow', compactFlow(projection.header.mermaid).diagram);
      const viewport = el('div', undefined, 'graph-viewport'); viewport.innerHTML = svg;
      diagram.prepend(viewport); fallback.hidden = true;
      const drawing = viewport.querySelector('svg');
      for (const node of drawing.querySelectorAll('.node, .cluster')) {
        const local = node.id.replace(/^conversation-flow-/, '');
        const id = node.classList.contains('cluster') ? local : local.replace(/^flowchart-/, '').replace(/-\d+$/, '');
        if (!projection.graph.items.has(id)) continue;
        node.setAttribute('role','button'); node.setAttribute('tabindex','0');
        node.setAttribute('aria-label', projection.graph.items.get(id).labels?.join(' · ') || 'Flow node'); register(id,node);
      }
      let scale = 1; const bounds = drawing.viewBox.baseVal;
      const resize = () => {drawing.style.width = bounds.width * scale + 'px'; drawing.style.height = bounds.height * scale + 'px';};
      $('flow-fit').onclick = () => {scale = Math.min((viewport.clientWidth-24)/bounds.width,(viewport.clientHeight-24)/bounds.height);resize();};
      $('flow-zoom-in').onclick = () => {scale = Math.min(4,scale*1.3);resize();};
      $('flow-zoom-out').onclick = () => {scale = Math.max(.05,scale/1.3);resize();};
      scale = Math.max(.75,Math.min(1,(viewport.clientWidth-24)/bounds.width)); resize();
    } catch {diagram.prepend(el('p','Diagram unavailable; inspect the recorded nodes below.','muted'));}
    draw();
  }
  async function recordingResponse(url) {
    let response;
    try {response = await fetchPage(url,{cache:'no-store'});} catch (error) {throw new RetryableRead(error.message);}
    if ([408,429,502,503,504].includes(response.status)) throw new RetryableRead(`Recording temporarily unavailable (HTTP ${response.status}).`);
    return response;
  }
  async function jsonPage(url) {
    const response = await recordingResponse(url);
    if (!response.ok) {
      const problem = await response.json().catch(() => ({}));
      throw new Error(problem.diagnostics?.map(item => item.message).join('; ') || `Recording unavailable (HTTP ${response.status}).`);
    }
    return response.json();
  }
  async function readAttempts() {
    for (const link of snapshot.querySelectorAll('[data-attempt]')) {
      const id = link.dataset.attempt;
      const latest = link === [...snapshot.querySelectorAll('[data-attempt]')].at(-1);
      let attempt = projection.attempts.get(id);
      if (attempt?.closed || (!attempt && attempted.has(id) && (!latest || snapshot.dataset.finished === 'true'))) continue;
      try {
        if (!attempt) {
          attempted.add(id);
          const response = await recordingResponse(link.getAttribute('href'));
          if (!response.ok) throw new Error(`Recording unavailable (HTTP ${response.status}).`);
          const page = new DOMParser().parseFromString(await response.text(),'text/html');
          const data = page.querySelector('#run-data');
          if (!data) throw new Error('Recording header is unavailable.');
          attempt = addAttempt(projection,id,JSON.parse(data.value).header);
          projection.gaps.delete(id);
          await render();
        }
        // Bound each polling pass; later attempts remain accessible after a gap.
        for (let pages = 0; pages < 5; pages++) {
          const params = new URLSearchParams({limit:'200'});
          if (attempt.cursor >= 0n) params.set('after',String(attempt.cursor));
          const page = await jsonPage(`/runs/${encodeURIComponent(id)}/events?${params}`);
          retries.delete(id);
          for (const record of page.events) reduceAttempt(projection,id,record);
          finishAttempt(projection,id,page);
          if (!page.more) break;
        }
        if (attempt.more) break;
      } catch (error) {
        if (error instanceof RetryableRead) {
          retries.set(id, `${error.message} Retrying; the last received state is retained.`);
          attempted.delete(id);
          break;
        }
        retries.delete(id);
        projection.gaps.set(id,error.message);
        if (attempt) attempt.closed = true;
      }
    }
  }
  function schedule() {
    clearTimeout(timer);
    if (!stopped && !complete && !doc.hidden && follow.checked) timer = setTimeout(poll,2000);
  }
  async function poll() {
    if (stopped || doc.hidden || pending || !follow.checked) return;
    pending = true;
    try {
      const response = await fetchPage(location.pathname,{cache:'no-store'});
      if (response.status === 404) {stopped = true; throw new Error('This flow was cleared or is no longer available.');}
      if (!response.ok) throw new Error(`Could not refresh this flow (HTTP ${response.status}).`);
      const page = new DOMParser().parseFromString(await response.text(),'text/html');
      const incoming = page.querySelector('#flow-snapshot');
      if (!incoming) throw new Error('The response did not contain this flow.');
      if (!follow.checked || stopped) return;
      const refreshed = refreshSnapshot(snapshot,incoming);
      await readAttempts();
      if (!follow.checked || stopped) return;
      complete = snapshot.dataset.finished === 'true' && [...projection.attempts.values()].every(attempt => attempt.closed);
      draw();
      message.textContent = !refreshed ? 'Details paused while text is selected.' : !projection.header ? 'Waiting for a readable execution attempt…' : snapshot.dataset.finished === 'true' ? 'Conversation finished.' : 'Following conversation';
    } catch (error) {message.textContent = `${error.message}${stopped ? '' : ' Retrying;'} showing the last received state.`;}
    finally {pending = false; schedule();}
  }
  follow.onchange = () => {message.textContent = follow.checked ? 'Following conversation' : 'Diagram and details paused; the worker continues.'; if (follow.checked) poll(); else {clearTimeout(timer); diagram.classList.remove('motion-running');}};
  $('flow-live').hidden = false;
  poll();
  doc.addEventListener('visibilitychange',schedule);
  const stop = () => {stopped = true; clearTimeout(timer); doc.removeEventListener('visibilitychange',schedule);};
  window.addEventListener('pagehide',stop,{once:true});
  return stop;
}
if (typeof document !== 'undefined') mountFlowViewer();
