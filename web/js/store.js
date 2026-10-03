// Per-device preferences. Storage can be unavailable (private mode), so every access is guarded.
const KEY = 'tether:prefs';
let cache = null;

function load() {
  if (cache) return cache;
  try { cache = JSON.parse(localStorage.getItem(KEY) || '{}'); } catch { cache = {}; }
  return cache;
}

export function pref(name, fallback) {
  const v = load()[name];
  return v === undefined ? fallback : v;
}

export function setPref(name, value) {
  load()[name] = value;
  try { localStorage.setItem(KEY, JSON.stringify(cache)); } catch { /* ignore */ }
}
