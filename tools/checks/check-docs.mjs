import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const adrName = /^(\d{4})-[a-z0-9]+(?:-[a-z0-9]+)*\.md$/;
const metadataKeys = ['id', 'title'];

export function checkAdr(name, source) {
  const errors = [];
  const match = adrName.exec(name);
  if (!match || match[1] === '0000') return [`${name}: invalid ADR filename`];
  const id = match[1];

  if (!source.startsWith('---\n')) return [`${name}: ADR requires front matter`];

  const lines = source.split('\n');
  const end = lines.indexOf('---', 1);
  if (end < 0) return [`${name}: front matter is not closed`];
  const fields = new Map();
  for (const line of lines.slice(1, end)) {
    const field = /^([a-z][a-z-]*): ([A-Za-z0-9._/-]+|'[^']*')$/.exec(line);
    if (!field) { errors.push(`${name}: malformed front-matter line: ${line}`); continue; }
    const [, key, raw] = field;
    if (!metadataKeys.includes(key)) errors.push(`${name}: unknown metadata key ${key}`);
    if (fields.has(key)) errors.push(`${name}: duplicate metadata key ${key}`);
    fields.set(key, raw.startsWith("'") ? raw.slice(1, -1) : raw);
  }
  for (const key of metadataKeys) if (!fields.get(key)) errors.push(`${name}: missing ${key}`);
  if (fields.get('id') !== id) errors.push(`${name}: metadata ID must match filename`);
  const heading = lines.slice(end + 1).find(line => line.startsWith('# '));
  if (heading?.slice(2) !== fields.get('title')) errors.push(`${name}: title must match H1`);
  return errors;
}

function contained(root, target) {
  const relative = path.relative(root, target);
  return relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

export function checkMarkdown(root, file, source) {
  const errors = [];
  if (!source.endsWith('\n')) errors.push(`${file}: missing final newline`);
  if (/[ \t]+$/m.test(source)) errors.push(`${file}: trailing whitespace`);

  let fence;
  for (const line of source.split('\n')) {
    const marker = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line);
    if (marker) {
      if (!fence) fence = marker[1];
      else if (marker[1][0] === fence[0] && marker[1].length >= fence.length && !marker[2].trim()) fence = undefined;
      continue;
    }
    if (fence) continue;
    for (const match of withoutInlineCode(line).matchAll(/!?\[[^\]\n]*\]\(([^)\n]+)\)/g)) {
      const target = match[1];
      if (/^(https?:|mailto:|#)/i.test(target)) continue;
      let local;
      try { local = decodeURIComponent(target.split('#')[0].replace(/^<|>$/g, '')); }
      catch { errors.push(`${file}: malformed link ${target}`); continue; }
      if (!local) continue;
      const resolved = path.resolve(root, path.dirname(file), local);
      if (!contained(root, resolved) || path.isAbsolute(local)) {
        errors.push(`${file}: local link leaves the checkout: ${target}; cite external source paths as text`);
      } else if (!fs.existsSync(resolved)) {
        errors.push(`${file}: missing local link target ${target}`);
      }
    }
  }
  if (fence) errors.push(`${file}: unclosed Markdown fence`);
  return errors;
}

function withoutInlineCode(line) {
  const markers = [...line.matchAll(/`+/g)];
  let output = '';
  let start = 0;
  for (let i = 0; i < markers.length; i++) {
    const open = markers[i];
    const precedingBackslashes = /\\*$/.exec(line.slice(0, open.index))[0].length;
    if (precedingBackslashes % 2) continue;
    const closeIndex = markers.findIndex((marker, j) => j > i && marker[0].length === open[0].length);
    if (closeIndex < 0) continue;
    const close = markers[closeIndex];
    output += line.slice(start, open.index) + ' ';
    start = close.index + close[0].length;
    i = closeIndex;
  }
  return output + line.slice(start);
}

function filesUnder(directory) {
  if (!fs.existsSync(directory)) return [];
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) return filesUnder(full);
    return entry.isFile() ? [full] : [];
  });
}

export function checkRepository(root) {
  root = path.resolve(root);
  const errors = [];
  const files = ['README.md', 'AGENTS.md', 'CONTRIBUTING.md']
    .filter(file => fs.existsSync(path.join(root, file)))
    .concat(['architecture', 'docs', '.github'].flatMap(directory =>
      filesUnder(path.join(root, directory))
        .filter(file => file.endsWith('.md'))
        .map(file => path.relative(root, file))));
  const ids = new Map();
  let adrs = 0;
  for (const file of files) {
    const source = fs.readFileSync(path.join(root, file), 'utf8');
    errors.push(...checkMarkdown(root, file, source));
    if (path.dirname(file) !== path.join('architecture', 'adr')) continue;
    const name = path.basename(file);
    if (['README.md', '0000-template.md'].includes(name)) continue;
    adrs++;
    errors.push(...checkAdr(name, source));
    const id = adrName.exec(name)?.[1];
    if (id && ids.has(id)) errors.push(`${file}: duplicate ADR ID, also in ${ids.get(id)}`);
    if (id) ids.set(id, file);
  }

  return { files: files.length, adrs, errors };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const result = checkRepository(process.argv[2] || process.cwd());
  if (result.errors.length) {
    for (const error of result.errors) console.error(error);
    process.exitCode = 1;
  } else {
    console.log(`Documentation check: ${result.files} Markdown files, ${result.adrs} numbered ADRs checked.`);
  }
}
