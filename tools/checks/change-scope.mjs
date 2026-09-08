import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export function docsOnly(paths) {
  return paths.length > 0 && paths.every(path =>
    /^(README|AGENTS)\.md$/.test(path) ||
    /^(docs|architecture)\/.*\.md$/.test(path));
}

export function changedDocsOnly(eventName, event, git) {
  let range;
  if (eventName === 'pull_request') {
    range = `${event.pull_request.base.sha}...${event.pull_request.head.sha}`;
  } else if (eventName === 'push' && event.before && !/^0+$/.test(event.before)) {
    range = `${event.before}..${event.after}`;
  } else {
    return false;
  }
  // Include both sides of renames: moving code into docs is still a code change.
  const paths = git(['diff', '--name-only', '--no-renames', '-z', range, '--'])
    .split('\0').filter(Boolean);
  return docsOnly(paths);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  let onlyDocs = false;
  try {
    onlyDocs = changedDocsOnly(process.env.GITHUB_EVENT_NAME,
      JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8')),
      args => execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }));
  } catch {
    console.error('Cannot determine changed paths; running normal checks.');
  }
  console.log(`docs_only=${onlyDocs}`);
}
