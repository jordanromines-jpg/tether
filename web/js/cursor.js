// Draws the Mac's cursor locally so pointer movement never waits for video.
// Desktop pointers: the real CSS cursor takes the Mac's cursor shape (zero latency).
// Touch: an overlay follows the agent's 60 Hz position, predicted from local finger motion.
export class RemoteCursor {
  constructor(viewport, view, { touch }) {
    this.view = view;
    this.touch = touch;
    this.viewport = viewport;
    this.el = document.createElement('div');
    this.el.id = 'cursor';
    this.el.hidden = true;
    viewport.append(this.el);
    this.shape = null;
    this.pos = null;            // normalized position currently drawn
    this.lastLocal = 0;         // time of last locally predicted move
    this.remote = null;         // the Mac's latest reported position
    this.scale = 1;             // "Bigger pointer" on touch screens
    view.onChange = () => this.render();
  }

  setShape({ png, w, h, hx, hy, nw, nh }) {
    this.shape = { w, h, hx, hy, nw, nh };
    const url = `data:image/png;base64,${png}`;
    if (this.touch) {
      this.el.style.backgroundImage = `url("${url}")`;
    } else {
      // 2x image for Retina; fall back to a plain image if image-set isn't supported for cursors.
      const hot = `${Math.round(hx)} ${Math.round(hy)}`;
      const s = this.viewport.style;
      s.cursor = `-webkit-image-set(url("${url}") 2x) ${hot}, auto`;
      if (!s.cursor) s.cursor = `image-set(url("${url}") 2x) ${hot}, auto`;
      if (!s.cursor) s.cursor = `url("${url}") ${hot}, auto`;
    }
    this.render();
  }

  /**
   * Authoritative position from the Mac. While a finger is moving, the local guess is drawn instead
   * (no lag); the Mac's latest position is kept and takes over as soon as the finger pauses. The Mac
   * only reports changes, so without that, a guess that drifted stayed drawn: clicks went to the real
   * pointer, somewhere else.
   */
  setRemote(x, y) {
    this.remote = { x, y };
    const wait = PREDICT_MS - (performance.now() - this.lastLocal);
    if (wait > 0 && this.pos) { this.settleLater(wait); return; }
    this.pos = { x, y };
    this.render();
  }

  settleLater(ms) {
    clearTimeout(this.settleTimer);
    this.settleTimer = setTimeout(() => {
      // Timers can fire a little early: wait out only what's left of the guess, not a whole new spell.
      const left = PREDICT_MS - (performance.now() - this.lastLocal);
      if (left > 2) { this.settleLater(left); return; }
      if (this.remote) { this.pos = { ...this.remote }; this.render(); }
    }, ms);
  }

  /** Immediate local prediction (trackpad deltas or direct touches). */
  predictDelta(dx, dy) {
    if (!this.pos) return;
    this.pos = { x: clamp(this.pos.x + dx), y: clamp(this.pos.y + dy) };
    this.predicted();
  }

  predictAt(x, y) {
    this.pos = { x: clamp(x), y: clamp(y) };
    this.predicted();
  }

  predicted() {
    this.lastLocal = performance.now();
    this.settleLater(PREDICT_MS);
    this.render();
  }

  render() {
    if (!this.touch || !this.shape || !this.pos || !this.view.videoW) { this.el.hidden = true; return; }
    const { nw, nh, w, h, hx, hy } = this.shape;
    const width = Math.max(14, nw * this.view.displayedWidth) * this.scale;
    const height = Math.max(14 * (h / w), nh * this.view.displayedHeight) * this.scale;
    const p = this.view.toClient(this.pos.x, this.pos.y);
    const st = this.el.style;
    st.width = `${width}px`;
    st.height = `${height}px`;
    st.transform = `translate(${p.x - (hx / w) * width}px, ${p.y - (hy / h) * height}px)`;
    this.el.hidden = false;
  }
}

const clamp = (v) => Math.min(1, Math.max(0, v));
/** How long a local guess is drawn before the Mac's own position takes over again. */
export const PREDICT_MS = 150;
