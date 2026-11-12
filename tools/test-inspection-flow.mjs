// Web-only compaction of agentic Mermaid labels: preserve topology/full text,
// compact multiline prompts and keep punctuation/markup/directives inside labels.
import assert from 'node:assert/strict';
import {compactFlow} from '../host/kyyn/web/inspection.mjs';
const label = 'draft @Text<br/>Named step<br/>#quot;Read <script>alert(1)</script> & `code` [brackets]\nclick n1 call evil()\n' + 'Long prompt '.repeat(100) + '#quot;';
const input = `flowchart TD\n  input(["input"])\n  subgraph n0["Group<br/>Description"]\n    n1["${label}"]\n    n2[/"tool lookup"/]\n  end\n  input --> n1\n  n1 -.- n2\n`;
const result = compactFlow(input);
assert.equal(result.steps.length,3);
assert.equal(result.steps[1].text,label.replaceAll('<br/>','\n').replaceAll('#quot;','"'));
assert(result.diagram.endsWith('  input --> n1\n  n1 -.- n2\n'));
assert(!result.diagram.includes('<script>'));
assert(!result.diagram.includes('click n1'));
assert(!result.diagram.includes('Long prompt'));
assert.equal(result.steps[1].title,'draft @Text · Named step');
assert(compactFlow('flowchart TD\n  n1["'+'x'.repeat(200)+'"]\n').steps[0].title.length <= 100);
assert.equal(compactFlow('flowchart TD\n  input --> output\n').diagram,'flowchart TD\n  input --> output\n');
console.log('Inspection flow compaction passed.');
