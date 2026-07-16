// scene.js — CPU mirror of the GPU prim pool + dirty tracking.
// One pool, alive for the whole session; sections re-target slots, never
// create/destroy geometry (BUILD_PLAN §1.1).

import {
  MAX_PRIMS, PRIM_FLOATS,
  OFF_POS, OFF_PARAMS, OFF_META, OFF_BLEND,
  KIND_SPHERE, KIND_SLAB,
} from './scene-format.js';

export class ScenePool {
  constructor() {
    this.data = new Float32Array(MAX_PRIMS * PRIM_FLOATS);
    this.u32 = new Uint32Array(this.data.buffer);
    this.count = 0;
    this.dirty = true;
  }

  alloc() {
    if (this.count >= MAX_PRIMS) throw new Error('prim pool exhausted');
    return this.count++;
  }

  setSlab(i, x, y, z, hx, hy, hz, cornerR, k, matClass, matParam) {
    const o = i * PRIM_FLOATS;
    const d = this.data;
    d[o + OFF_POS] = x; d[o + OFF_POS + 1] = y; d[o + OFF_POS + 2] = z; d[o + OFF_POS + 3] = 0;
    d[o + OFF_PARAMS] = hx; d[o + OFF_PARAMS + 1] = hy; d[o + OFF_PARAMS + 2] = hz; d[o + OFF_PARAMS + 3] = cornerR;
    this.u32[o + OFF_META] = KIND_SLAB;
    this.u32[o + OFF_META + 2] = matClass;
    d[o + OFF_BLEND] = k; d[o + OFF_BLEND + 3] = matParam;
    this.dirty = true;
  }

  setSphere(i, x, y, z, r, k, matClass, matParam) {
    const o = i * PRIM_FLOATS;
    const d = this.data;
    d[o + OFF_POS] = x; d[o + OFF_POS + 1] = y; d[o + OFF_POS + 2] = z; d[o + OFF_POS + 3] = r;
    this.u32[o + OFF_META] = KIND_SPHERE;
    this.u32[o + OFF_META + 2] = matClass;
    d[o + OFF_BLEND] = k; d[o + OFF_BLEND + 3] = matParam;
    this.dirty = true;
  }

  setMatParam(i, v) {
    const o = i * PRIM_FLOATS + OFF_BLEND + 3;
    if (this.data[o] !== v) { this.data[o] = v; this.dirty = true; }
  }
}
