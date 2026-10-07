// Pointer + touch input. Mouse/trackpad pointers send absolute positions;
// touch uses a virtual trackpad (default) or direct-touch mode.
export class Input {
  constructor({ stream, view, keyboard, surface }) {
    this.stream = stream;
    this.view = view;
    this.kb = keyboard;
    this.surface = surface;
    this.touchMode = 'trackpad';
    this.enabled = true;
    this.pendingMove = null;
    this.rafQueued = false;
    this.bindPointer();
    this.bindWheel();
    this.bindTouch();
  }

  send(obj) { if (this.enabled) this.stream.send(obj); }

  // --- Mouse / trackpad / pen (desktop, iPad pointer) ---------------------

  bindPointer() {
    const s = this.surface;
    s.addEventListener('pointermove', (e) => {
      if (e.pointerType === 'touch') return;
      // Pointer captured (trackpad or mouse locked to the page): send relative moves, like a real trackpad.
      if (document.pointerLockElement) {
        if (e.movementX || e.movementY) {
          this.send({ t: 'mrel', dx: e.movementX / this.view.displayedWidth, dy: e.movementY / this.view.displayedHeight });
        }
        return;
      }
      const events = e.getCoalescedEvents?.() ?? [];
      const last = events.length ? events[events.length - 1] : e;
      this.queueMove(this.view.toNormalized(last.clientX, last.clientY));
    });
    s.addEventListener('pointerdown', (e) => {
      if (e.pointerType === 'touch') return;
      e.preventDefault();
      s.focus({ preventScroll: true });
      s.setPointerCapture(e.pointerId);
      if (!document.pointerLockElement) this.flushMove(this.view.toNormalized(e.clientX, e.clientY));
      this.send({ t: 'btn', b: e.button, down: true });
    });
    s.addEventListener('pointerup', (e) => {
      if (e.pointerType === 'touch') return;
      this.flushMove(this.view.toNormalized(e.clientX, e.clientY));
      this.send({ t: 'btn', b: e.button, down: false });
      this.kb.consumeSticky();
    });
    s.addEventListener('contextmenu', (e) => e.preventDefault());
  }

  queueMove(p) {
    this.pendingMove = p;
    if (this.rafQueued) return;
    this.rafQueued = true;
    requestAnimationFrame(() => {
      this.rafQueued = false;
      if (this.pendingMove) this.send({ t: 'move', ...this.pendingMove });
      this.pendingMove = null;
    });
  }

  flushMove(p) {
    this.pendingMove = null;
    this.send({ t: 'move', ...p });
  }

  bindWheel() {
    this.surface.addEventListener('wheel', (e) => {
      e.preventDefault();
      const k = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 400 : 1;
      this.send({ t: 'scroll', dx: e.deltaX * k, dy: e.deltaY * k });
    }, { passive: false });
  }

  // --- Touch ---------------------------------------------------------------

  bindTouch() {
    const s = this.surface;
    const opts = { passive: false };
    s.addEventListener('touchstart', (e) => this.touchStart(e), opts);
    s.addEventListener('touchmove', (e) => this.touchMove(e), opts);
    s.addEventListener('touchend', (e) => this.touchEnd(e), opts);
    s.addEventListener('touchcancel', (e) => this.touchEnd(e), opts);
  }

  touchStart(e) {
    e.preventDefault();
    const n = e.touches.length;
    const now = performance.now();
    if (n === 1) {
      const t = e.touches[0];
      this.g = { kind: 'one', x: t.clientX, y: t.clientY, sx: t.clientX, sy: t.clientY, t0: now, moved: false, dragging: false };
      if (this.touchMode === 'direct') {
        const p = this.view.toNormalized(t.clientX, t.clientY);
        if (!this.stream.observe) this.cursor?.predictAt(p.x, p.y);
        this.flushMove(p);
        // A finger that stays down shows the magnifier (quick taps don't).
        this.g.loupe = setTimeout(() => { if (this.g?.kind === 'one') this.onFinger?.('start', this.g.x, this.g.y); }, 200);
      } else {
        // Touch-and-hold starts a drag (like a trackpad click-and-hold).
        this.g.hold = setTimeout(() => {
          if (this.g?.kind === 'one' && !this.g.moved) {
            this.g.dragging = true;
            this.send({ t: 'btn', b: 0, down: true });
            navigator.vibrate?.(10);
            this.onFinger?.('start', this.g.x, this.g.y);
          }
        }, 380);
      }
    } else if (n === 2) {
      this.cancelOne();
      const [a, b] = e.touches;
      this.g = {
        kind: 'two', t0: now, moved: false, mode: null,
        cx: (a.clientX + b.clientX) / 2, cy: (a.clientY + b.clientY) / 2,
        dist: Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY),
        zoom0: this.view.zoom,
      };
      this.g.dist0 = this.g.dist;
      this.g.cx0 = this.g.cx;
      this.g.cy0 = this.g.cy;
    } else if (n >= 3) {
      this.cancelOne();
      const cx = avgX(e.touches), cy = avgY(e.touches);
      this.g = { kind: 'three', t0: now, moved: false, cx, cy, sx: cx, sy: cy };
    }
  }

  touchMove(e) {
    e.preventDefault();
    const g = this.g;
    if (!g) return;
    if (g.kind === 'one' && e.touches.length === 1) {
      const t = e.touches[0];
      const dx = t.clientX - g.x, dy = t.clientY - g.y;
      g.x = t.clientX; g.y = t.clientY;
      if (!g.moved && Math.hypot(g.x - g.sx, g.y - g.sy) > 6) {
        g.moved = true;
        clearTimeout(g.hold);
        if (this.touchMode === 'direct' && !g.dragging) {
          g.dragging = true;
          this.send({ t: 'btn', b: 0, down: true });
        }
      }
      if (!g.moved) return;
      this.onFinger?.('move', t.clientX, t.clientY);
      if (this.touchMode === 'direct') {
        const p = this.view.toNormalized(t.clientX, t.clientY);
        if (!this.stream.observe) this.cursor?.predictAt(p.x, p.y);
        this.queueMove(p);
      } else {
        // Pointer acceleration: slow moves are precise, fast flicks cover the screen.
        const speed = Math.hypot(dx, dy);
        const gain = 1.3 + Math.min(2.2, speed / 10);
        const ndx = (dx * gain) / this.view.displayedWidth, ndy = (dy * gain) / this.view.displayedHeight;
        if (!this.stream.observe) this.cursor?.predictDelta(ndx, ndy);
        this.send({ t: 'mrel', dx: ndx, dy: ndy });
      }
    } else if (g.kind === 'two' && e.touches.length === 2) {
      const [a, b] = e.touches;
      const cx = (a.clientX + b.clientX) / 2, cy = (a.clientY + b.clientY) / 2;
      const dist = Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);
      const dx = cx - g.cx, dy = cy - g.cy;
      g.cx = cx; g.cy = cy; g.dist = dist;
      if (!g.mode) {
        const pinch = Math.abs(dist - g.dist0) / g.dist0;
        const pan = Math.hypot(cx - g.cx0, cy - g.cy0);
        if (pinch > 0.12) g.mode = 'zoom';
        else if (pan > 8) g.mode = 'scroll';
        if (g.mode) g.moved = true;
        return;
      }
      if (g.mode === 'zoom') {
        this.view.zoomAt(g.zoom0 * (dist / g.dist0), cx, cy);
        this.view.panBy(dx, dy);
      } else {
        // Natural scrolling: content follows the fingers.
        this.send({ t: 'scroll', dx: -dx * 2, dy: -dy * 2 });
      }
    } else if (g.kind === 'three' && e.touches.length >= 3) {
      const cx = avgX(e.touches), cy = avgY(e.touches);
      // Zoomed in: three fingers pan the view. Otherwise they swipe (handled on release).
      if (this.view.zoom > 1.01) this.view.panBy(cx - g.cx, cy - g.cy);
      g.cx = cx; g.cy = cy;
      g.moved = true;
    }
  }

  touchEnd(e) {
    e.preventDefault();
    const g = this.g;
    if (!g) return;
    const dt = performance.now() - g.t0;
    if (g.kind === 'one' && e.touches.length === 0) {
      clearTimeout(g.hold);
      clearTimeout(g.loupe);
      this.onFinger?.('end');
      if (g.dragging) {
        if (this.touchMode === 'direct') this.flushMove(this.view.toNormalized(g.x, g.y));
        this.send({ t: 'btn', b: 0, down: false });
      } else if (!g.moved && dt < 350) {
        this.click(0);
      }
      this.g = null;
    } else if (g.kind === 'two' && e.touches.length < 2) {
      if (!g.moved && dt < 350) this.click(2);
      this.g = e.touches.length ? { kind: 'done' } : null;
    } else if (g.kind === 'three' && e.touches.length < 3) {
      const dx = g.cx - g.sx, dy = g.cy - g.sy;
      if (this.view.zoom <= 1.01 && Math.max(Math.abs(dx), Math.abs(dy)) > 50) {
        // Like a Mac trackpad: swipe between Spaces, up for Mission Control, down for App Exposé.
        const combo = Math.abs(dx) > Math.abs(dy)
          ? ['ControlLeft', dx < 0 ? 'ArrowRight' : 'ArrowLeft']
          : ['ControlLeft', dy < 0 ? 'ArrowUp' : 'ArrowDown'];
        this.kb.combo(combo);
      }
      this.g = e.touches.length ? { kind: 'done' } : null;
    } else if (e.touches.length === 0) {
      this.g = null;
    }
  }

  cancelOne() {
    if (this.g?.kind !== 'one') return;
    clearTimeout(this.g.hold);
    clearTimeout(this.g.loupe);
    this.onFinger?.('end');
    if (this.g.dragging) this.send({ t: 'btn', b: 0, down: false });
  }

  click(button) {
    this.send({ t: 'btn', b: button, down: true });
    this.send({ t: 'btn', b: button, down: false });
    this.kb.consumeSticky();
  }
}

const avgX = (ts) => [...ts].reduce((s, t) => s + t.clientX, 0) / ts.length;
const avgY = (ts) => [...ts].reduce((s, t) => s + t.clientY, 0) / ts.length;
