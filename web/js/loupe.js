// A magnifier above the finger while dragging or pointing on a touch screen, so small targets
// are easy to hit. It shows a 2.5x crop of the video around the Mac's pointer.
const SIZE = 120;
const ZOOM = 2.5;
const LIFT = 96; // drawn above the finger so the finger doesn't hide it

export class Loupe {
  constructor(source, view, cursor) {
    this.source = source;
    this.view = view;
    this.cursor = cursor;
    this.el = document.createElement('canvas');
    this.el.id = 'loupe';
    this.el.hidden = true;
    this.el.setAttribute('aria-hidden', 'true');
    document.body.append(this.el);
    this.ctx = this.el.getContext('2d');
    this.active = false;
    this.enabled = true;
  }

  show(x, y) {
    if (!this.enabled) return;
    const dpr = devicePixelRatio || 1;
    this.el.width = this.el.height = Math.round(SIZE * dpr);
    this.active = true;
    this.el.hidden = false;
    this.move(x, y);
    const loop = () => { if (!this.active) return; this.draw(); requestAnimationFrame(loop); };
    requestAnimationFrame(loop);
  }

  move(x, y) {
    if (!this.active) return;
    const left = Math.min(innerWidth - SIZE - 8, Math.max(8, x - SIZE / 2));
    const top = y - SIZE / 2 - LIFT < 8 ? y + LIFT / 2 : y - SIZE / 2 - LIFT;
    this.el.style.transform = `translate(${Math.round(left)}px, ${Math.round(top)}px)`;
  }

  hide() {
    this.active = false;
    this.el.hidden = true;
  }

  draw() {
    const pos = this.cursor.pos;
    if (!pos || !this.view.videoW) return;
    const W = this.el.width;
    const scale = this.view.scale || 1;                 // CSS px per video px
    const span = SIZE / (scale * ZOOM);                  // video px shown across the loupe
    const cx = pos.x * this.view.videoW, cy = pos.y * this.view.videoH;
    const c = this.ctx;
    c.fillStyle = '#000';
    c.fillRect(0, 0, W, W);
    c.imageSmoothingEnabled = true;
    c.drawImage(this.source, cx - span / 2, cy - span / 2, span, span, 0, 0, W, W);
    // Crosshair at the pointer.
    c.strokeStyle = 'rgba(255,255,255,.9)';
    c.lineWidth = W / 80;
    c.beginPath();
    c.moveTo(W / 2 - W / 14, W / 2); c.lineTo(W / 2 + W / 14, W / 2);
    c.moveTo(W / 2, W / 2 - W / 14); c.lineTo(W / 2, W / 2 + W / 14);
    c.stroke();
  }
}

// The menu-bar magnifier: while the Mac's pointer is in its menu bar (on a touch screen, not zoomed
// in), a wide strip across the top shows the bar at 3x around the pointer, so its small icons and
// menus are easy to aim at. It only shows; taps still go where the pointer is.
const STRIP_ZOOM = 3;
const STRIP_H = 64;

export class MenuBarStrip {
  constructor(source, view, cursor) {
    this.source = source;
    this.view = view;
    this.cursor = cursor;
    this.el = document.createElement('canvas');
    this.el.id = 'menubar-zoom';
    this.el.hidden = true;
    this.el.setAttribute('aria-hidden', 'true');
    document.body.append(this.el);
    this.ctx = this.el.getContext('2d');
    this.active = false;
  }

  set(show) {
    if (show === this.active) return;
    this.active = show;
    this.el.hidden = !show;
    if (!show) return;
    const dpr = devicePixelRatio || 1;
    this.width = Math.min(innerWidth - 16, 640);
    this.el.width = Math.round(this.width * dpr);
    this.el.height = Math.round(STRIP_H * dpr);
    this.el.style.width = `${this.width}px`;
    const loop = () => { if (!this.active) return; this.draw(); requestAnimationFrame(loop); };
    requestAnimationFrame(loop);
  }

  draw() {
    const pos = this.cursor.pos;
    if (!pos || !this.view.videoW) return;
    const W = this.el.width, H = this.el.height;
    const scale = this.view.scale || 1;
    const spanX = this.width / (scale * STRIP_ZOOM);               // video px across the strip
    const spanY = spanX * (H / W);
    const cx = pos.x * this.view.videoW;
    const sx = Math.max(0, Math.min(this.view.videoW - spanX, cx - spanX / 2));
    const c = this.ctx;
    c.fillStyle = '#000';
    c.fillRect(0, 0, W, H);
    c.imageSmoothingEnabled = true;
    c.drawImage(this.source, sx, 0, spanX, spanY, 0, 0, W, H);
    // Where the pointer is, inside the strip.
    const px = ((cx - sx) / spanX) * W, py = ((pos.y * this.view.videoH) / spanY) * H;
    c.strokeStyle = 'rgba(255,255,255,.95)';
    c.lineWidth = Math.max(2, W / 320);
    c.beginPath();
    c.arc(px, py, H / 5, 0, Math.PI * 2);
    c.stroke();
  }
}
