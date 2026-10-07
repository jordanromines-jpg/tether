import { test } from 'node:test';
import assert from 'node:assert/strict';
import { comboLabel, buildCombo, parsePinned, togglePinned, isPinned, MAX_PINNED } from '../js/shortcuts.js';

test('combo labels read like macOS menus', () => {
  assert.equal(comboLabel(['MetaLeft', 'KeyQ']), '⌘Q');
  assert.equal(comboLabel(['MetaLeft', 'ControlLeft', 'KeyQ']), '⌃⌘Q');
  assert.equal(comboLabel(['MetaLeft', 'ShiftLeft', 'Digit4']), '⇧⌘4');
  assert.equal(comboLabel(['ControlLeft', 'ArrowUp']), '⌃↑');
});

test('building a combo needs a key and orders modifiers', () => {
  assert.equal(buildCombo(['MetaLeft'], ''), null);
  assert.deepEqual(buildCombo(['MetaLeft', 'ControlLeft'], 'KeyK'), ['ControlLeft', 'MetaLeft', 'KeyK']);
});

test('saved list is cleaned up', () => {
  assert.deepEqual(parsePinned(null), []);
  assert.deepEqual(parsePinned([{ label: 'x' }, { label: 'Spotlight', combo: ['MetaLeft', 'Space'] }, 5]),
    [{ label: 'Spotlight', combo: ['MetaLeft', 'Space'] }]);
});

test('pin, unpin, and the limit', () => {
  const s = { label: 'Spotlight', combo: ['MetaLeft', 'Space'] };
  let list = togglePinned([], s);
  assert.ok(isPinned(list, s.combo));
  list = togglePinned(list, s);
  assert.equal(list.length, 0);
  const full = Array.from({ length: MAX_PINNED }, (_, i) => ({ label: `S${i}`, combo: ['MetaLeft', `Digit${i}`] }));
  assert.equal(togglePinned(full, s).length, MAX_PINNED);
});
