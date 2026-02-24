export function stripTrailingSlash(value) {
  return String(value || '').replace(/\/+$/, '');
}

export function deriveWsUrl(baseUrl) {
  const raw = String(baseUrl || '').trim();
  const matched = raw.match(/^(https?):\/\/([^/]+)/i);

  if (matched) {
    const scheme = matched[1].toLowerCase() === 'https' ? 'wss' : 'ws';
    return `${scheme}://${matched[2]}/ws`;
  }

  const hostOnly = raw
    .replace(/^(wss?|https?):\/\//i, '')
    .split('/')[0]
    .trim();

  if (!hostOnly) {
    return 'ws://localhost/ws';
  }

  return `ws://${hostOnly}/ws`;
}

export function parseHost(url) {
  const matched = String(url).match(/^wss?:\/\/([^/]+)/i);
  return matched ? matched[1] : 'localhost';
}

export function makeSeed() {
  const timePart = Date.now().toString(36).slice(-6);
  const randPart = Math.floor(Math.random() * 1296).toString(36).padStart(2, '0');
  return `${timePart}${randPart}`;
}

export function makeLoginId(seed, index) {
  return `k${seed}${String(index).padStart(3, '0')}`;
}

export function pickRandom(arr) {
  if (!arr || arr.length === 0) {
    return null;
  }
  return arr[Math.floor(Math.random() * arr.length)];
}

export function safeJsonParse(value) {
  try {
    return JSON.parse(value);
  } catch (_) {
    return null;
  }
}

export function getHeaderValue(headers, headerName) {
  if (!headers || !headerName) {
    return '';
  }

  const target = String(headerName).trim().toLowerCase();
  if (!target) {
    return '';
  }

  const key = Object.keys(headers).find((name) => String(name).trim().toLowerCase() === target);
  if (!key) {
    return '';
  }

  const raw = headers[key];
  if (Array.isArray(raw)) {
    return String(raw[0] || '');
  }
  return String(raw || '');
}

export function hasResponseHeaderValue(res, headerName, expectedValue) {
  const actual = getHeaderValue(res && res.headers ? res.headers : null, headerName);
  if (!actual) {
    return false;
  }

  const expected = String(expectedValue || '').trim().toLowerCase();
  if (!expected) {
    return true;
  }

  return actual.trim().toLowerCase() === expected;
}
