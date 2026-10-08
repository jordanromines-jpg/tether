import { test } from 'node:test';
import assert from 'node:assert/strict';
import { addClip, clipPreview, MAX_ITEMS } from '../js/cliphistory.js';

test('newest first, and repeats move to the front', () => {
  let l = addClip([], { from: 'mac', kind: 'text', s: 'one' }, 1);
  l = addClip(l, { from: 'mac', kind: 'text', s: 'two' }, 2);
  l = addClip(l, { from: 'mac', kind: 'text', s: 'one' }, 3);
  assert.deepEqual(l.map((a) => a.s), ['one', 'two']);
  assert.equal(l[0].at, 3);
});

test('the same text sent and received are separate entries', () => {
  let l = addClip([], { from: 'mac', kind: 'text', s: 'hi' });
  l = addClip(l, { from: 'here', kind: 'text', s: 'hi' });
  assert.equal(l.length, 2);
});

test('keeps the last few each way', () => {
  let l = [];
  for (let i = 0; i < 15; i++) l = addClip(l, { from: 'mac', kind: 'text', s: `m${i}` });
  for (let i = 0; i < 3; i++) l = addClip(l, { from: 'here', kind: 'text', s: `h${i}` });
  assert.equal(l.filter((a) => a.from === 'mac').length, MAX_ITEMS);
  assert.equal(l.filter((a) => a.from === 'here').length, 3);
  assert.equal(l.find((a) => a.from === 'mac').s, 'm14');
});

test('images are told apart by id', () => {
  let l = addClip([], { from: 'mac', kind: 'image', id: 1 });
  l = addClip(l, { from: 'mac', kind: 'image', id: 2 });
  assert.equal(l.length, 2);
});

test('previews are one short line', () => {
  assert.equal(clipPreview('a\n\n  b'), 'a b');
  assert.equal(clipPreview('x'.repeat(100)).length, 80);
});
