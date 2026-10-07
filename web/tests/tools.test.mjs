import { test } from 'node:test';
import assert from 'node:assert/strict';

import { TOOLS, SECTIONS, tool, deviceClass, defaultLayout, normalizeLayout, visibleLayout, availableTools, isAvailable,
  foldOrder, move, toggle, sections, keyRowTop, shortMacName } from '../js/tools.js';

const full = { control: true, desktop: true, pointerCapture: true, links: true };

test('every tool has a name, a short label that fits, an icon, a hint and a known section', () => {
  const sectionIds = SECTIONS.map(([id]) => id);
  for (const t of TOOLS) {
    assert.ok(t.label && t.icon && t.hint, t.id);
    assert.ok(t.short.length <= 11, `${t.id} short label "${t.short}" is too long for the toolbar`);
    assert.ok(sectionIds.includes(t.section), t.id);
    assert.ok(!t.hint.includes('—'), `${t.id} hint uses an em dash`);
  }
  assert.equal(new Set(TOOLS.map((t) => t.id)).size, TOOLS.length, 'ids are unique');
});

test('device classes: phones by their short side, so rotating keeps the class', () => {
  assert.equal(deviceClass({ touch: true, shortSide: 393 }), 'phone');
  assert.equal(deviceClass({ touch: true, shortSide: 820 }), 'tablet');
  assert.equal(deviceClass({ touch: false, shortSide: 900 }), 'desktop');
});

test('defaults: the phone bar is four tools (plus More), all one tap away', () => {
  assert.deepEqual(defaultLayout('phone'), ['keyboard', 'actions', 'windows', 'clipboard']);
  assert.ok(defaultLayout('tablet').includes('status'));
  assert.ok(!defaultLayout('desktop').includes('keyboard'), 'desktops type with their own keyboard');
  assert.deepEqual(defaultLayout('nonsense'), defaultLayout('desktop'));
  const a = defaultLayout('phone'); a.push('x');
  assert.equal(defaultLayout('phone').length, 4, 'defaults are copies');
});

test('saved layouts are cleaned: unknown ids and repeats dropped, nothing saved means defaults', () => {
  assert.deepEqual(normalizeLayout(['files', 'nope', 'files', 'more', 7, 'sound'], 'phone'), ['files', 'sound']);
  assert.deepEqual(normalizeLayout(null, 'phone'), defaultLayout('phone'));
  assert.deepEqual(normalizeLayout([], 'phone'), [], 'an empty bar (only More) is allowed');
});

test('availability: view only removes typing tools, desktop-only and capability tools need their context', () => {
  const viewing = { ...full, control: false };
  assert.deepEqual(visibleLayout(['keyboard', 'actions', 'windows', 'viewonly', 'curtain'], viewing), ['windows', 'viewonly']);
  assert.ok(!isAvailable(tool('fullscreen'), { ...full, desktop: false }));
  assert.ok(!isAvailable(tool('capture'), { ...full, pointerCapture: false }));
  assert.ok(!isAvailable(tool('help'), { ...full, links: false }));
  assert.ok(!isAvailable(undefined, full));
  assert.equal(availableTools(full).length, TOOLS.length);
});

test('folding: pinned shortcuts go first, then the layout from its end', () => {
  assert.deepEqual(foldOrder(['keyboard', 'actions', 'windows'], ['pin:0', 'pin:1']), ['pin:1', 'pin:0', 'windows', 'actions', 'keyboard']);
  assert.deepEqual(foldOrder([]), []);
});

test('edit toolbar: move and toggle', () => {
  const l = ['a', 'b', 'c'];
  assert.deepEqual(move(l, 'b', -1), ['b', 'a', 'c']);
  assert.deepEqual(move(l, 'c', 1), l, 'the last one stays last');
  assert.deepEqual(move(l, 'zz', 1), l);
  assert.deepEqual(toggle(l, 'b'), ['a', 'c']);
  assert.deepEqual(toggle(l, 'd'), ['a', 'b', 'c', 'd']);
  assert.deepEqual(l, ['a', 'b', 'c'], 'inputs are not changed');
});

test('More lists every available tool once, by section, without the connection item', () => {
  const s = sections(full);
  assert.deepEqual(s.map(([id]) => id), SECTIONS.map(([id]) => id));
  const ids = s.flatMap(([, , list]) => list.map((t) => t.id));
  assert.equal(ids.length, TOOLS.length - 1);
  assert.ok(!ids.includes('status'));
  assert.ok(!sections({ ...full, links: false }).flatMap(([, , l]) => l).some((t) => t.id === 'help'));
});

test('the key row sits on top of the on-screen keyboard', () => {
  // iPhone portrait, keyboard up: the visual viewport is the part above the keyboard.
  assert.equal(keyRowTop({ vvHeight: 476, vvOffsetTop: 0, rowHeight: 44 }), 432);
  // Page scrolled while the keyboard is up (iOS shifts the visual viewport).
  assert.equal(keyRowTop({ vvHeight: 476, vvOffsetTop: 120, rowHeight: 44 }), 552);
  // Hardware keyboard: no on-screen keyboard, the row sits at the bottom of the screen.
  assert.equal(keyRowTop({ vvHeight: 1180, vvOffsetTop: 0, rowHeight: 44 }), 1136);
});

test('the toolbar shows a short Mac name', () => {
  assert.equal(shortMacName('Jordan’s Mac Studio'), 'Mac Studio');
  assert.equal(shortMacName("Sam's MacBook Pro"), 'MacBook Pro');
  assert.equal(shortMacName('Studio'), 'Studio');
  assert.equal(shortMacName('Mac mini'), 'Mac mini');
  assert.equal(shortMacName('Mac Studio Downstairs'), 'Studio Downstairs');
  assert.equal(shortMacName('Jordan’s'), 'Jordan’s', 'a name that is only a possessive stays as it is');
  assert.equal(shortMacName('  '), 'Mac');
  assert.equal(shortMacName(undefined), 'Mac');
});
