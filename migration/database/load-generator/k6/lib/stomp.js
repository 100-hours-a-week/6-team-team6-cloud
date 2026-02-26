export function buildStompFrame(command, headers, body) {
  const headerLines = [];
  for (const [key, value] of Object.entries(headers || {})) {
    headerLines.push(`${key}:${value}`);
  }

  const bodyText = body === undefined || body === null ? '' : String(body);
  return `${command}\n${headerLines.join('\n')}\n\n${bodyText}\u0000`;
}

export function parseStompFrames(rawMessage) {
  const raw = String(rawMessage || '');
  const chunks = raw.split('\u0000');
  const frames = [];

  for (const chunk of chunks) {
    const normalized = chunk.replace(/\r/g, '');
    if (!normalized.trim()) {
      continue;
    }

    const separatorIndex = normalized.indexOf('\n\n');
    const head = separatorIndex >= 0 ? normalized.slice(0, separatorIndex) : normalized;
    const body = separatorIndex >= 0 ? normalized.slice(separatorIndex + 2) : '';
    const lines = head.split('\n').filter((line) => line.length > 0);

    if (lines.length === 0) {
      continue;
    }

    const command = lines[0];
    const headers = {};

    for (let i = 1; i < lines.length; i += 1) {
      const idx = lines[i].indexOf(':');
      if (idx > 0) {
        headers[lines[i].slice(0, idx)] = lines[i].slice(idx + 1);
      }
    }

    frames.push({ command, headers, body });
  }

  return frames;
}
