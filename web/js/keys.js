// Keyboard: hardware keys (by physical code), soft keyboards (by text),
// and sticky modifier buttons shared by touch and desktop.
export const MODIFIER_CODES = new Set([
  'MetaLeft', 'MetaRight', 'AltLeft', 'AltRight', 'ControlLeft', 'ControlRight', 'ShiftLeft', 'ShiftRight', 'CapsLock', 'Fn',
]);

/** Best-effort physical key for a typed character (US layout), used for sticky-modifier combos. */
export function codeForChar(ch) {
  if (/^[a-z]$/i.test(ch)) return { code: `Key${ch.toUpperCase()}`, shift: ch !== ch.toLowerCase() };
  if (/^[0-9]$/.test(ch)) return { code: `Digit${ch}`, shift: false };
  const map = {
    ' ': 'Space', '-': 'Minus', '=': 'Equal', '[': 'BracketLeft', ']': 'BracketRight', '\\': 'Backslash',
    ';': 'Semicolon', "'": 'Quote', ',': 'Comma', '.': 'Period', '/': 'Slash', '`': 'Backquote',
  };
  return map[ch] ? { code: map[ch], shift: false } : null;
}

export class Keyboard {
  constructor(stream, toolbar) {
    this.stream = stream;
    this.down = new Set();
    this.sticky = new Map(); // code -> 'on' | 'locked'
    this.metaSwallow = new Set();
    this.onStickyChange = () => {};
  }

  key(code, down) {
    this.stream.send({ t: 'key', code, down });
    if (down) this.down.add(code); else this.down.delete(code);
  }

  tap(code) {
    this.key(code, true);
    this.key(code, false);
    this.consumeSticky();
  }

  /** Presses a combo like ['MetaLeft','ShiftLeft','Digit4']. */
  combo(codes) {
    for (const c of codes) this.key(c, true);
    for (const c of [...codes].reverse()) this.key(c, false);
    this.consumeSticky();
  }

  text(s) {
    if (!s) return;
    if (this.sticky.size) {
      // With ⌘/⌃/⌥ held via the toolbar, send real key presses so shortcuts work.
      for (const ch of s) {
        const k = codeForChar(ch);
        if (!k) { this.stream.send({ t: 'text', s: ch }); continue; }
        if (k.shift) this.key('ShiftLeft', true);
        this.key(k.code, true);
        this.key(k.code, false);
        if (k.shift) this.key('ShiftLeft', false);
      }
      this.consumeSticky();
      return;
    }
    this.stream.send({ t: 'text', s });
  }

  toggleSticky(code) {
    const state = this.sticky.get(code);
    if (!state) {
      this.sticky.set(code, 'on');
      this.key(code, true);
    } else if (state === 'on' && performance.now() - (this.lastStickyTap?.[code] ?? 0) < 350) {
      this.sticky.set(code, 'locked'); // double-tap locks
    } else {
      this.sticky.delete(code);
      this.key(code, false);
    }
    this.lastStickyTap = { ...this.lastStickyTap, [code]: performance.now() };
    this.onStickyChange(this.sticky);
  }

  /** Releases one-shot sticky modifiers after a key or click. */
  consumeSticky() {
    let changed = false;
    for (const [code, state] of this.sticky) {
      if (state === 'on') {
        this.sticky.delete(code);
        this.key(code, false);
        changed = true;
      }
    }
    if (changed) this.onStickyChange(this.sticky);
  }

  releaseAll() {
    this.down.clear();
    this.sticky.clear();
    this.metaSwallow.clear();
    this.onStickyChange(this.sticky);
    this.stream.send({ t: 'release' });
  }

  /** Hardware keyboard events (desktop, iPad Magic Keyboard). */
  handleKeyDown(e) {
    if (e.isComposing || e.keyCode === 229 || !e.code) return false;
    if (MODIFIER_CODES.has(e.code)) {
      if (!e.repeat) this.key(e.code, true);
      return true;
    }
    // Safari/Chrome on macOS never deliver keyup for keys pressed while ⌘ is held,
    // so send those as a complete tap and ignore the (missing) keyup.
    if (e.metaKey) {
      this.key(e.code, true);
      this.key(e.code, false);
      this.metaSwallow.add(e.code);
      this.consumeSticky();
      return true;
    }
    this.key(e.code, true);
    return true;
  }

  handleKeyUp(e) {
    if (!e.code) return false;
    if (this.metaSwallow.delete(e.code)) return true;
    if (this.down.has(e.code)) {
      this.key(e.code, false);
      if (!MODIFIER_CODES.has(e.code)) this.consumeSticky();
      return true;
    }
    return false;
  }
}
