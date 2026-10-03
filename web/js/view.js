// Maps between the remote screen (video pixels / normalized coords) and the
// browser viewport, including pinch-zoom and pan for touch devices.
export class View {
  constructor(canvas, viewport) {
    this.canvas = canvas;
    this.viewport = viewport;
    this.videoW = 0;
    this.videoH = 0;
    this.zoom = 1;
    this.tx = 0;
    this.ty = 0;
    this.scale = 1;
    addEventListener('resize', () => this.layout(true));
    visualViewport?.addEventListener('resize', () => this.layout(true));
  }

  setVideoSize(w, h) {
    if (w === this.videoW && h === this.videoH) return;
    this.videoW = w;
    this.videoH = h;
    this.canvas.width = w;
    this.canvas.height = h;
    this.layout(true);
  }

  get fitScale() {
    if (!this.videoW) return 1;
    const vw = this.viewport.clientWidth, vh = this.viewport.clientHeight;
    return Math.min(vw / this.videoW, vh / this.videoH);
  }

  layout(reset = false) {
    if (!this.videoW) return;
    if (reset) this.zoom = Math.max(1, this.zoom);
    this.scale = this.fitScale * this.zoom;
    this.clampPan();
    this.apply();
  }

  apply() {
    this.canvas.style.width = `${this.videoW}px`;
    this.canvas.style.height = `${this.videoH}px`;
    this.canvas.style.transform = `translate(${this.tx}px, ${this.ty}px) scale(${this.scale})`;
    this.onChange?.();
  }

  clampPan() {
    const vw = this.viewport.clientWidth, vh = this.viewport.clientHeight;
    const w = this.videoW * this.scale, h = this.videoH * this.scale;
    this.tx = w <= vw ? (vw - w) / 2 : Math.min(0, Math.max(vw - w, this.tx));
    this.ty = h <= vh ? (vh - h) / 2 : Math.min(0, Math.max(vh - h, this.ty));
  }

  /** Zooms keeping the given viewport point fixed. */
  zoomAt(newZoom, cx, cy) {
    const z = Math.min(6, Math.max(1, newZoom));
    const nx = (cx - this.tx) / this.scale, ny = (cy - this.ty) / this.scale;
    this.zoom = z;
    this.scale = this.fitScale * z;
    this.tx = cx - nx * this.scale;
    this.ty = cy - ny * this.scale;
    this.clampPan();
    this.apply();
  }

  panBy(dx, dy) {
    this.tx += dx;
    this.ty += dy;
    this.clampPan();
    this.apply();
  }

  /** Keeps the remote cursor in view while zoomed in. */
  follow(nx, ny) {
    if (this.zoom <= 1.01) return;
    const vw = this.viewport.clientWidth, vh = this.viewport.clientHeight;
    const px = this.tx + nx * this.videoW * this.scale;
    const py = this.ty + ny * this.videoH * this.scale;
    const mx = vw * 0.18, my = vh * 0.18;
    let dx = 0, dy = 0;
    if (px < mx) dx = mx - px; else if (px > vw - mx) dx = vw - mx - px;
    if (py < my) dy = my - py; else if (py > vh - my) dy = vh - my - py;
    if (dx || dy) this.panBy(dx, dy);
  }

  /** Viewport point → normalized remote coordinates (clamped). */
  toNormalized(clientX, clientY) {
    const r = this.viewport.getBoundingClientRect();
    const x = (clientX - r.left - this.tx) / (this.videoW * this.scale);
    const y = (clientY - r.top - this.ty) / (this.videoH * this.scale);
    return { x: Math.min(1, Math.max(0, x)), y: Math.min(1, Math.max(0, y)) };
  }

  /** Normalized remote coordinates → viewport CSS pixels. */
  toClient(nx, ny) {
    return { x: this.tx + nx * this.videoW * this.scale, y: this.ty + ny * this.videoH * this.scale };
  }

  /** On-screen size of the remote display in CSS pixels. */
  get displayedWidth() { return this.videoW * this.scale || 1; }
  get displayedHeight() { return this.videoH * this.scale || 1; }
}
