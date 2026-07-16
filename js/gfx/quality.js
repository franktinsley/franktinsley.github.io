// quality.js — adaptive controller. Signal is the rAF-delta EMA ONLY (no
// timestamp-query, no boot benchmark — DESIGN_SPEC §8 step 7): Safari lacks
// GPU timestamps, so the rAF path is the load-bearing one. The readout prints
// only what this signal can actually measure.

export class Quality {
  constructor() {
    this.scale = 0.5;          // start conservative, adapt up within ~2 s
    this.fps = 60;
    this.frames = 0;
    this.goodWindows = 0;
    this.lastEma = 0;
    this.samples = 0;          // readout prints fps only once actually measured
  }

  frame(nowMs) {
    if (this.lastEma) {
      const dt = Math.min(nowMs - this.lastEma, 100);
      // EMA over ~0.5 s
      const alpha = Math.min(dt / 500, 1);
      this.fps += ((1000 / Math.max(dt, 1)) - this.fps) * alpha;
      this.samples++;
    }
    this.lastEma = nowMs;
    if (++this.frames >= 30) {
      this.frames = 0;
      this.adjust();
    }
  }

  // dropped frames don't advance the EMA clock — call when the loop sleeps
  pause() { this.lastEma = 0; this.frames = 0; this.samples = 0; }

  adjust() {
    if (this.fps < 54 && this.scale > 0.35) {
      this.scale = Math.max(0.35, this.scale - 0.05);
      this.goodWindows = 0;
    } else if (this.fps > 58) {
      // hysteresis: two consecutive comfortable windows before stepping up
      if (++this.goodWindows >= 2 && this.scale < 1.0) {
        this.scale = Math.min(1.0, this.scale + 0.05);
        this.goodWindows = 0;
      }
    } else {
      this.goodWindows = 0;
    }
  }

  tier() {
    return this.scale < 0.5 ? 'LOW' : this.scale < 0.8 ? 'MED' : 'HIGH';
  }
}
