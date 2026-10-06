// Test broker for the same two-section byte framing used by the native host.
export function encodeFrame(metadata, body = Buffer.alloc(0)) {
  const section = bytes => {
    const parts = [];
    for (let at = 0; at < bytes.length; at += 65536) {
      const chunk = bytes.subarray(at, at + 65536);
      parts.push(Buffer.from(`${chunk.length}\n`), chunk);
    }
    parts.push(Buffer.from('0\n'));
    return parts;
  };
  return Buffer.concat([...section(Buffer.from(JSON.stringify(metadata))), ...section(body)]);
}

export async function* readFrames(input) {
  let pending = Buffer.alloc(0), count = null, sections = [], parts = [];
  for await (const incoming of input) {
    pending = Buffer.concat([pending, incoming]);
    while (true) {
      if (count === null) {
        const newline = pending.indexOf(10);
        if (newline < 0) {
          if (pending.length > 5) throw new Error('Invalid chunk length');
          break;
        }
        const header = pending.subarray(0, newline).toString('ascii');
        if (!/^(0|[1-9][0-9]{0,4})$/.test(header) || Number(header) > 65536)
          throw new Error('Invalid chunk length');
        pending = pending.subarray(newline + 1);
        count = Number(header);
        if (count === 0) {
          sections.push(Buffer.concat(parts)); parts = []; count = null;
          if (sections.length === 2) {
            const [metadata, body] = sections; sections = [];
            yield { metadata: JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(metadata)), body };
          }
          continue;
        }
      }
      if (pending.length < count) break;
      parts.push(pending.subarray(0, count));
      pending = pending.subarray(count); count = null;
    }
  }
  if (pending.length || count !== null || sections.length || parts.length)
    throw new Error('Incomplete frame');
}
