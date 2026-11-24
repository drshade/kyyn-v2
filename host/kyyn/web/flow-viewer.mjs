// Poll the existing read-only page; the captured run viewer owns event streaming.
export function latestAttempt(snapshot) {
  return [...snapshot.querySelectorAll('[data-attempt]')].at(-1)?.getAttribute('href') ?? null;
}
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
export function mountFlowViewer(doc = document, fetchPage = fetch) {
  const snapshot = doc.querySelector('#flow-snapshot');
  if (!snapshot) return;
  const follow = doc.querySelector('#flow-follow'), frame = doc.querySelector('#flow-run'), message = doc.querySelector('#flow-message');
  let selected = null, stopped = false, pending = false, timer;
  function show(path) {
    if (!path || path === selected) return;
    selected = path;
    frame.src = `${path}?embedded=1`;
    frame.hidden = false;
  }
  function update() {
    if (follow.checked) show(latestAttempt(snapshot));
    message.textContent = follow.checked
      ? (selected ? 'Following the latest attempt. Replies and status update automatically.' : 'Waiting for the first execution attempt…')
      : 'Inspecting the selected attempt. Replies and status still update.';
  }
  follow.addEventListener('change', update);
  snapshot.addEventListener('click', event => {
    const link = event.target.closest('[data-attempt]');
    if (!link || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey || event.button !== 0) return;
    event.preventDefault(); follow.checked = false; show(link.getAttribute('href')); update();
  });
  function schedule() {
    clearTimeout(timer);
    if (!stopped && !doc.hidden && snapshot.dataset.finished !== 'true') timer = setTimeout(poll, 2000);
  }
  async function poll() {
    if (stopped || doc.hidden || pending) return;
    pending = true;
    try {
      const response = await fetchPage(location.pathname, {cache: 'no-store'});
      if (!response.ok) throw new Error(response.status === 404 ? 'This flow was cleared or is no longer available.' : `Could not refresh this flow (HTTP ${response.status}).`);
      const page = new DOMParser().parseFromString(await response.text(), 'text/html');
      const incoming = page.querySelector('#flow-snapshot');
      if (!incoming) throw new Error('The response did not contain this flow.');
      if (stopped) return;
      refreshSnapshot(snapshot, incoming); update();
    } catch (error) {
      if (!stopped) message.textContent = `${error.message} Retrying; showing the last received state.`;
    } finally {
      pending = false; schedule();
    }
  }
  update(); schedule();
  doc.addEventListener("visibilitychange", schedule);
  const stop = () => { stopped = true; clearTimeout(timer); doc.removeEventListener("visibilitychange", schedule); };
  window.addEventListener('pagehide', stop, {once:true});
  return stop;
}
if (typeof document !== 'undefined') mountFlowViewer();
