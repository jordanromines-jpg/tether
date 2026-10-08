// The data meter: bytes received this session and today, kept per device. Pure helpers are
// tested by web/tests/usage.test.mjs.

export function formatBytes(n) {
  if (n < 1e6) return `${Math.max(0, Math.round(n / 1e3))} KB`;
  if (n < 1e9) return `${Math.round(n / 1e6)} MB`;
  return `${(n / 1e9).toFixed(1)} GB`;
}

/** Adds `delta` to the saved daily total, starting over on a new local day. */
export function addToDay(saved, delta, today) {
  if (!saved || saved.day !== today) return { day: today, bytes: delta };
  return { day: today, bytes: saved.bytes + delta };
}

/** Whether this session just crossed the warning limit (MB; 0 = off). */
export function crossedLimit(before, after, limitMB) {
  if (!limitMB) return false;
  const limit = limitMB * 1e6;
  return before < limit && after >= limit;
}

export const localDay = (d = new Date()) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;

/** Upload progress in words: "2.1 MB/s · about 12 s left". Empty until there's enough to go on. */
export function transferText(loaded, total, elapsedMs) {
  if (elapsedMs < 500 || loaded <= 0) return '';
  const perSec = loaded / (elapsedMs / 1000);
  const speed = perSec < 1e6 ? `${Math.max(1, Math.round(perSec / 1e3))} KB/s` : `${(perSec / 1e6).toFixed(1)} MB/s`;
  const left = Math.max(0, (total - loaded) / perSec);
  const leftText = left < 1 ? 'almost done'
    : left < 60 ? `about ${Math.ceil(left)} s left`
    : `about ${Math.ceil(left / 60)} min left`;
  return `${speed} · ${leftText}`;
}
