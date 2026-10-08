// Clipboard history: the last few things copied on the Mac and sent from this device.
// Kept in memory only, never saved: clipboards hold passwords. Gone when the page closes.
// Tested by web/tests/cliphistory.test.mjs.

export const MAX_ITEMS = 10;

/**
 * Adds an item ({ from: 'mac' | 'here', kind: 'text' | 'image', s?, id? }) to the front.
 * The same thing again moves to the front instead of appearing twice. Keeps MAX_ITEMS per side.
 */
export function addClip(list, item, now = Date.now()) {
  const same = (a) => a.from === item.from && a.kind === item.kind && (item.kind === 'text' ? a.s === item.s : a.id === item.id);
  const next = [{ ...item, at: now }, ...list.filter((a) => !same(a))];
  const kept = { mac: 0, here: 0 };
  return next.filter((a) => ++kept[a.from] <= MAX_ITEMS);
}

/** One line for the list: whitespace folded, cut at 80 characters. */
export function clipPreview(s, max = 80) {
  const flat = String(s).replace(/\s+/g, ' ').trim();
  return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
}
