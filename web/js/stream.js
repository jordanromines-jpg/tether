// WebSocket connection to the agent + H.264 decoding with WebCodecs.
const FRAME_HEADER = 10;

export class Stream extends EventTarget {
  constructor(canvas, view) {
    super();
    this.canvas = canvas;
    this.view = view;
    this.ctx = canvas.getContext('2d', { alpha: false, desynchronized: true });
    this.ws = null;
    this.decoder = null;
    this.codecKey = null;
    this.needKey = true;
    this.retry = 0;
    this.helloExtra = () => ({});
    this.stats = { frames: 0, bytes: 0, fps: 0, kbps: 0, rtt: 0, codec: '' };
    this.pings = new Map();
    setInterval(() => {
      this.stats.fps = this.stats.frames;
      this.stats.kbps = Math.round((this.stats.bytes * 8) / 1000);
      this.stats.frames = 0;
      this.stats.bytes = 0;
      if (this.connected) {
        // Link health for the agent's adaptive quality.
        const id = performance.now();
        this.pings.set(id, id);
        this.send({ t: 'ping', id });
        this.send({ t: 'stats', rtt: Math.round(this.stats.rtt), queue: this.decoder?.decodeQueueSize ?? 0 });
      }
    }, 1000);
  }

  /** Codecs this browser can hardware-decode, best first. */
  static async detectCodecs() {
    const probes = [['hevc', 'hvc1.1.6.L153.B0'], ['h264', 'avc1.64002a']];
    const out = [];
    for (const [name, codec] of probes) {
      try {
        const r = await VideoDecoder.isConfigSupported({ codec, codedWidth: 1920, codedHeight: 1080 });
        if (r.supported) out.push(name);
      } catch { /* unsupported */ }
    }
    return out.length ? out : ['h264'];
  }

  static support() {
    if (!window.isSecureContext) return 'This page must be opened over HTTPS (your tailnet’s https:// address).';
    if (typeof VideoDecoder === 'undefined') return 'This browser can’t decode the video stream. Use Safari 17+ or a current Chrome/Edge.';
    return null;
  }

  connect() {
    clearTimeout(this.retryTimer);
    if (this.ws && this.ws.readyState <= 1) return;
    if (this.paused) return;
    const url = `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}${location.pathname.replace(/[^/]*$/, '')}ws?device=${encodeURIComponent(this.deviceName || '')}`;
    const ws = new WebSocket(url);
    ws.binaryType = 'arraybuffer';
    this.ws = ws;
    this.emit('connecting');

    ws.onopen = () => {
      this.retry = 0;
      this.needKey = true;
      this.send({ t: 'hello', ...this.helloExtra() });
      this.emit('open');
    };
    ws.onmessage = (e) => {
      if (typeof e.data === 'string') this.onControl(JSON.parse(e.data));
      else this.onVideo(e.data);
    };
    ws.onclose = (e) => {
      if (this.ws !== ws) return;
      this.ws = null;
      this.resetDecoder();
      this.emit('close', { code: e.code });
      const delay = Math.min(8000, 500 * 2 ** this.retry++);
      this.retryTimer = setTimeout(async () => {
        // The passkey lock (or an expired session) shows up as refused connections.
        if (this.beforeReconnect && !(await this.beforeReconnect())) return;
        this.connect();
      }, delay);
    };
  }

  reconnect() {
    const ws = this.ws;
    this.ws = null;
    ws?.close();
    this.retry = 0;
    this.connect();
  }

  get connected() { return this.ws?.readyState === 1; }

  send(obj) {
    if (this.ws?.readyState === 1) this.ws.send(JSON.stringify(obj));
  }

  emit(type, detail) { this.dispatchEvent(new CustomEvent(type, { detail })); }

  onControl(msg) {
    if (msg.t === 'config') this.configure(msg);
    if (msg.t === 'pong' && this.pings.has(msg.id)) {
      const rtt = performance.now() - this.pings.get(msg.id);
      this.pings.delete(msg.id);
      this.stats.rtt = this.stats.rtt ? this.stats.rtt * 0.7 + rtt * 0.3 : rtt;
    }
    this.emit(msg.t, msg);
  }

  configure({ codec, desc, w, h }) {
    const key = `${codec}:${desc}`;
    if (key === this.codecKey && this.decoder?.state === 'configured') return;
    this.resetDecoder();
    const description = Uint8Array.from(atob(desc), (c) => c.charCodeAt(0));
    this.decoder = new VideoDecoder({
      output: (frame) => this.draw(frame),
      error: (err) => {
        console.warn('decoder error', err);
        this.resetDecoder();
        this.requestKeyframe();
      },
    });
    this.decoder.configure({ codec, description, codedWidth: w, codedHeight: h, optimizeForLatency: true });
    this.codecKey = key;
    this.stats.codec = codec.startsWith('hvc') ? 'HEVC' : 'H.264';
    this.view.setVideoSize(w, h);
    this.needKey = true;
  }

  resetDecoder() {
    try { this.decoder?.close(); } catch { /* already closed */ }
    this.decoder = null;
    this.codecKey = null;
    this.needKey = true;
  }

  requestKeyframe() {
    this.needKey = true;
    this.send({ t: 'keyframe' });
  }

  onVideo(buf) {
    const bytes = new Uint8Array(buf);
    if (bytes[0] === 2) { this.onAudio?.(bytes); return; }
    if (bytes.length <= FRAME_HEADER || bytes[0] !== 1) return;
    const isKey = (bytes[1] & 1) === 1;
    if (!this.decoder || this.decoder.state !== 'configured') return;
    if (this.needKey && !isKey) return;
    this.needKey = false;
    const view = new DataView(buf);
    const ts = Number(view.getBigUint64(2));
    this.stats.bytes += bytes.length;
    try {
      this.decoder.decode(new EncodedVideoChunk({
        type: isKey ? 'key' : 'delta',
        timestamp: ts,
        data: bytes.subarray(FRAME_HEADER),
      }));
    } catch (err) {
      console.warn('decode failed', err);
      this.resetDecoder();
      this.requestKeyframe();
    }
  }

  draw(frame) {
    if (frame.displayWidth !== this.canvas.width || frame.displayHeight !== this.canvas.height) {
      this.view.setVideoSize(frame.displayWidth, frame.displayHeight);
    }
    this.ctx.drawImage(frame, 0, 0);
    frame.close();
    this.stats.frames++;
    if (!this.hasVideo) {
      this.hasVideo = true;
      this.emit('firstframe');
    }
  }
}
