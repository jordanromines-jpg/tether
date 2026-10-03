// Plays the Mac's sound. AAC via WebCodecs AudioDecoder when available, else 24 kHz PCM.
export class AudioPlayer {
  constructor(stream) {
    this.stream = stream;
    this.on = false;
    this.ctx = null;
    this.decoder = null;
    this.next = 0;
    this.ts = 0;
    stream.addEventListener('open', () => { if (this.on) this.request(); });
  }

  static async bestFormat() {
    try {
      if (typeof AudioDecoder !== 'undefined') {
        const r = await AudioDecoder.isConfigSupported({ codec: 'mp4a.40.2', sampleRate: 48000, numberOfChannels: 2 });
        if (r.supported) return 'aac';
      }
    } catch { /* fall through */ }
    return 'pcm';
  }

  /** Must be called from a tap/click (browsers only start audio after a user gesture). */
  async start() {
    this.ctx = new (window.AudioContext || window.webkitAudioContext)({ latencyHint: 'interactive' });
    await this.ctx.resume();
    this.format = await AudioPlayer.bestFormat();
    if (this.format === 'aac') {
      this.decoder = new AudioDecoder({
        output: (data) => this.playAudioData(data),
        error: (e) => { console.warn('audio decoder', e); this.format = 'pcm'; this.request(); },
      });
      this.decoder.configure({ codec: 'mp4a.40.2', sampleRate: 48000, numberOfChannels: 2, description: new Uint8Array([0x11, 0x90]) });
    }
    this.on = true;
    this.next = 0;
    this.request();
  }

  request() { this.stream.send({ t: 'audio', on: true, format: this.format }); }

  stop() {
    this.on = false;
    this.stream.send({ t: 'audio', on: false });
    try { this.decoder?.close(); } catch { /* closed */ }
    this.decoder = null;
    this.ctx?.close();
    this.ctx = null;
  }

  onFrame(bytes) {
    if (!this.on || !this.ctx) return;
    const payload = bytes.subarray(10);
    if (bytes[1] === 1 && this.decoder?.state === 'configured') {
      this.ts += 21333; // 1024 samples @ 48 kHz
      this.decoder.decode(new EncodedAudioChunk({ type: 'key', timestamp: this.ts, data: payload }));
    } else if (bytes[1] === 2) {
      const samples = new Int16Array(payload.buffer, payload.byteOffset, payload.byteLength >> 1);
      const frames = samples.length >> 1;
      if (!frames) return;
      const buf = this.ctx.createBuffer(2, frames, 24000);
      const l = buf.getChannelData(0), r = buf.getChannelData(1);
      for (let i = 0; i < frames; i++) { l[i] = samples[2 * i] / 32768; r[i] = samples[2 * i + 1] / 32768; }
      this.schedule(buf);
    }
  }

  playAudioData(data) {
    const buf = this.ctx.createBuffer(data.numberOfChannels, data.numberOfFrames, data.sampleRate);
    for (let ch = 0; ch < data.numberOfChannels; ch++) {
      const tmp = new Float32Array(data.numberOfFrames);
      data.copyTo(tmp, { planeIndex: ch, format: 'f32-planar' });
      buf.copyToChannel(tmp, ch);
    }
    data.close();
    this.schedule(buf);
  }

  /** Small jitter buffer: play ~80 ms behind, resync if we drift too far. */
  schedule(buf) {
    const now = this.ctx.currentTime;
    if (this.next < now + 0.03 || this.next > now + 0.35) this.next = now + 0.08;
    const src = this.ctx.createBufferSource();
    src.buffer = buf;
    src.connect(this.ctx.destination);
    src.start(this.next);
    this.next += buf.duration;
  }
}
