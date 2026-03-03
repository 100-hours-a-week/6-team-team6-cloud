export function intEnv(name, fallback) {
  const parsed = Number(__ENV[name]);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return fallback;
  }
  return Math.floor(parsed);
}

export function parseOptionalInt(value) {
  if (value === undefined || value === null || value === '') {
    return null;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) ? Math.floor(parsed) : null;
}

export function boundedNumEnv(name, fallback, min, max) {
  const parsed = Number(__ENV[name]);
  if (!Number.isFinite(parsed)) {
    return fallback;
  }
  return Math.min(Math.max(parsed, min), max);
}

export function boolEnv(name, fallback) {
  const raw = __ENV[name];
  if (raw === undefined || raw === null || String(raw).trim() === '') {
    return fallback;
  }

  const value = String(raw).trim().toLowerCase();
  if (['1', 'true', 'yes', 'y', 'on'].includes(value)) {
    return true;
  }
  if (['0', 'false', 'no', 'n', 'off'].includes(value)) {
    return false;
  }
  return fallback;
}
