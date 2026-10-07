// Pinned shortcuts for the toolbar: stored per device as [{label, combo:[codes]}], at most 6.
// Pure helpers, tested by web/tests/shortcuts.test.mjs.

export const MAX_PINNED = 6;
const MODS = { MetaLeft: '⌘', AltLeft: '⌥', ControlLeft: '⌃', ShiftLeft: '⇧' };
const MOD_ORDER = ['ControlLeft', 'AltLeft', 'ShiftLeft', 'MetaLeft'];   // the order macOS shows them in

const KEY_LABELS = { Space: 'Space', Enter: '↩', Escape: 'Esc', Tab: '⇥', Backspace: '⌫', Delete: '⌦',
  ArrowLeft: '←', ArrowRight: '→', ArrowUp: '↑', ArrowDown: '↓' };

/** "⌃⌘Q" style text for a combo of KeyboardEvent.code names. */
export function comboLabel(combo) {
  const mods = MOD_ORDER.filter((m) => combo.includes(m)).map((m) => MODS[m]).join('');
  const keys = combo.filter((c) => !MODS[c]).map((c) => KEY_LABELS[c] ?? c.replace(/^Key|^Digit/, '')).join('');
  return mods + keys;
}

/** Builds a combo from chosen modifiers and one key; null if there's no key. */
export function buildCombo(mods, key) {
  if (!key) return null;
  return [...MOD_ORDER.filter((m) => mods.includes(m)), key];
}

/** Reads the saved list, dropping anything malformed. */
export function parsePinned(saved) {
  if (!Array.isArray(saved)) return [];
  return saved.filter((p) => p && typeof p.label === 'string' && Array.isArray(p.combo) && p.combo.length
    && p.combo.every((c) => typeof c === 'string')).slice(0, MAX_PINNED);
}

/** Pins (or unpins, if already pinned) a shortcut. Returns the new list. */
export function togglePinned(list, item) {
  const key = item.combo.join('+');
  if (list.some((p) => p.combo.join('+') === key)) return list.filter((p) => p.combo.join('+') !== key);
  if (list.length >= MAX_PINNED) return list;
  return [...list, { label: item.label, combo: item.combo }];
}

export const isPinned = (list, combo) => list.some((p) => p.combo.join('+') === combo.join('+'));
