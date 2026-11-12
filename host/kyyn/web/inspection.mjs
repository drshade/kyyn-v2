// Agentic's Mermaid renderer emits quoted n<number> nodes and subgraphs.
// Keep its topology, but move full labels out of the diagram into step details.
export function compactFlow(source) {
  const steps = [];
  const diagram = source.replace(/^(\s*(?:subgraph )?)(n\d+)(\(\["|\[\/"|\[")([\s\S]*?)("\]\)|"\/\]|"\])$/gm,
    (_, prefix, id, opening, label, closing) => {
      const text = label.replaceAll('<br/>', '\n').replaceAll('#quot;', '"');
      const lines = text.split('\n');
      const title = lines.slice(0, 2).join(' · ');
      const short = title.length > 100 ? title.slice(0, 97) + '…' : title;
      steps.push({id, title: short, text});
      // Encode label characters so quotes, markup and Mermaid punctuation are text.
      const encoded = [...short].map(c => `#${c.codePointAt(0)};`).join('');
      return prefix + id + opening + encoded + closing;
    });
  return {diagram, steps};
}

function element(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
}

async function showFlow(source, container) {
  const {diagram, steps} = compactFlow(source.textContent);
  const viewport = element('div', undefined, 'flow-viewport');
  const toolbar = element('div', undefined, 'flow-toolbar');
  const list = element('section');
  list.append(element('h3', 'Steps'));
  const details = new Map();
  for (const step of steps) {
    const detail = element('details', undefined, 'flow-step');
    detail.id = 'step-' + step.id;
    detail.append(element('summary', step.title), element('pre', step.text));
    list.append(detail);
    details.set(step.id, detail);
  }
  container.append(toolbar, viewport, list);
  const status = element('p', 'Loading diagram…');
  viewport.append(status);
  try {
    await new Promise((resolve, reject) => {
      const script = element('script');
      script.src = '/_inspection/vendor/mermaid.js';
      script.onload = resolve;
      script.onerror = reject;
      document.head.append(script);
    });
    mermaid.initialize({startOnLoad: false, securityLevel: 'strict',
      suppressErrorRendering: true, flowchart: {htmlLabels: true, useMaxWidth: false}});
    const {svg} = await mermaid.render('recipe-diagram', diagram);
    viewport.innerHTML = svg;
    const drawing = viewport.querySelector('svg');
    const bounds = drawing.viewBox.baseVal;
    let scale = 1;
    const resize = () => {
      drawing.style.width = bounds.width * scale + 'px';
      drawing.style.height = bounds.height * scale + 'px';
    };
    const fit = () => {
      scale = Math.min(1, (viewport.clientWidth - 8) / bounds.width, window.innerHeight * .6 / bounds.height);
      resize();
    };
    for (const [label, action] of [
      ['Fit', fit], ['Zoom in', () => {scale = Math.min(4, scale * 1.4); resize();}],
      ['Zoom out', () => {scale = Math.max(.05, scale / 1.4); resize();}]
    ]) {
      const button = element('button', label);
      button.type = 'button'; button.addEventListener('click', action); toolbar.append(button);
    }
    toolbar.append(element('span', 'Select a step to read its details.'));
    for (const node of drawing.querySelectorAll('.node, .cluster')) {
      const id = node.id.match(/^recipe-diagram-flowchart-(n\d+)-\d+$/)?.[1] ?? node.id.replace(/^recipe-diagram-/, '');
      const detail = details.get(id);
      if (!detail) continue;
      node.setAttribute('tabindex', '0'); node.setAttribute('role', 'button');
      node.setAttribute('aria-label', detail.querySelector('summary').textContent);
      const select = event => {
        event.stopPropagation();
        detail.open = true;
        detail.scrollIntoView({block: 'nearest'});
        detail.querySelector('summary').focus();
      };
      node.addEventListener('click', select);
      node.addEventListener('keydown', event => {
        if (event.key === 'Enter' || event.key === ' ') {event.preventDefault(); select(event);}
      });
    }
    scale = Math.min(1, (viewport.clientWidth - 8) / bounds.width);
    resize();
    document.querySelector('#flow-source').open = false;
  } catch {
    viewport.replaceChildren(element('p', 'Diagram unavailable. Read the steps below or expand the Mermaid source.'));
    document.querySelector('#flow-source').open = true;
  }
}

if (typeof document !== 'undefined') {
  const source = document.querySelector('#flow-mermaid');
  const container = document.querySelector('#recipe-flow');
  if (source && container) showFlow(source, container);
}
