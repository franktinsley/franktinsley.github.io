// webgpu-renderer.js — two fragment passes (BUILD_PLAN §1.3):
//   Pass 1: march into a persistent rgba16float target, drawn at a
//           renderScale-sized SUBRECT (viewport+scissor) — changing renderScale
//           never reallocates anything.
//   Pass 2: upsample the subrect to the swapchain + tonemap + dither.
// The march target is reallocated only when the canvas backing size changes.

import { MAX_PRIMS, PRIM_STRIDE, GLOBALS_SIZE } from './scene-format.js';

export class Renderer {
  static async create(canvas) {
    if (!navigator.gpu) throw new Error('no navigator.gpu');
    const adapter = await navigator.gpu.requestAdapter({ powerPreference: 'low-power' });
    if (!adapter) throw new Error('no adapter');
    const device = await adapter.requestDevice();
    const ctx = canvas.getContext('webgpu');
    const format = navigator.gpu.getPreferredCanvasFormat();
    ctx.configure({ device, format, alphaMode: 'opaque' });
    return new Renderer(canvas, device, ctx, format);
  }

  constructor(canvas, device, ctx, format) {
    this.canvas = canvas;
    this.device = device;
    this.ctx = ctx;
    this.format = format;
    this.target = null;
    this.targetView = null;
    this.compositeBind = null;
  }

  async initPipelines(commonSrc, marchSrc, compositeSrc) {
    const d = this.device;

    const marchModule = d.createShaderModule({ code: commonSrc + '\n' + marchSrc });
    const compModule = d.createShaderModule({ code: compositeSrc });
    for (const mod of [marchModule, compModule]) {
      const info = await mod.getCompilationInfo();
      for (const m of info.messages) {
        console[m.type === 'error' ? 'error' : 'warn'](
          `WGSL ${m.type} @${m.lineNum}:${m.linePos} ${m.message}`);
      }
    }

    [this.marchPipeline, this.compPipeline] = await Promise.all([
      d.createRenderPipelineAsync({
        layout: 'auto',
        vertex: { module: marchModule, entryPoint: 'vs' },
        fragment: { module: marchModule, entryPoint: 'fs', targets: [{ format: 'rgba16float' }] },
        primitive: { topology: 'triangle-list' },
      }),
      d.createRenderPipelineAsync({
        layout: 'auto',
        vertex: { module: compModule, entryPoint: 'vs' },
        fragment: { module: compModule, entryPoint: 'fs', targets: [{ format: this.format }] },
        primitive: { topology: 'triangle-list' },
      }),
    ]);

    this.globalsBuf = d.createBuffer({ size: GLOBALS_SIZE, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    this.primsBuf = d.createBuffer({ size: MAX_PRIMS * PRIM_STRIDE, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
    this.cuBuf = d.createBuffer({ size: 32, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    this.cuArr = new Float32Array(8);
    this.sampler = d.createSampler({ magFilter: 'linear', minFilter: 'linear' });

    this.marchBind = d.createBindGroup({
      layout: this.marchPipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: this.globalsBuf } },
        { binding: 1, resource: { buffer: this.primsBuf } },
      ],
    });
  }

  // css size + dpr -> backing store; march target reallocates only on growth/shrink
  resize(cssW, cssH, dpr) {
    const w = Math.max(1, Math.floor(cssW * dpr));
    const h = Math.max(1, Math.floor(cssH * dpr));
    if (this.canvas.width !== w || this.canvas.height !== h) {
      this.canvas.width = w;
      this.canvas.height = h;
    }
    if (!this.target || this.target.width !== w || this.target.height !== h) {
      if (this.target) this.target.destroy();
      this.target = this.device.createTexture({
        size: [w, h],
        format: 'rgba16float',
        usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING,
      });
      this.targetView = this.target.createView();
      this.compositeBind = this.device.createBindGroup({
        layout: this.compPipeline.getBindGroupLayout(0),
        entries: [
          { binding: 0, resource: { buffer: this.cuBuf } },
          { binding: 1, resource: this.targetView },
          { binding: 2, resource: this.sampler },
        ],
      });
    }
  }

  // globals[0..1] are filled here with the actual march subrect size
  render(globals, pool, scale, time) {
    const d = this.device;
    const tw = this.target.width;
    const th = this.target.height;
    const sw = Math.max(1, Math.floor(tw * scale));
    const sh = Math.max(1, Math.floor(th * scale));

    globals[0] = sw;
    globals[1] = sh;
    d.queue.writeBuffer(this.globalsBuf, 0, globals);
    if (pool.dirty) {
      d.queue.writeBuffer(this.primsBuf, 0, pool.data);
      pool.dirty = false;
    }
    const cu = this.cuArr;
    cu[0] = sw / tw; cu[1] = sh / th;
    cu[2] = 1 / this.canvas.width; cu[3] = 1 / this.canvas.height;
    cu[4] = (sw - 0.5) / tw; cu[5] = (sh - 0.5) / th;
    cu[6] = time; cu[7] = 0;
    d.queue.writeBuffer(this.cuBuf, 0, cu);

    const enc = d.createCommandEncoder();

    const p1 = enc.beginRenderPass({
      colorAttachments: [{
        view: this.targetView,
        loadOp: 'clear',
        clearValue: { r: 0, g: 0, b: 0, a: 1 },
        storeOp: 'store',
      }],
    });
    p1.setPipeline(this.marchPipeline);
    p1.setBindGroup(0, this.marchBind);
    p1.setViewport(0, 0, sw, sh, 0, 1);
    p1.setScissorRect(0, 0, sw, sh);
    p1.draw(3);
    p1.end();

    const p2 = enc.beginRenderPass({
      colorAttachments: [{
        view: this.ctx.getCurrentTexture().createView(),
        loadOp: 'clear',
        clearValue: { r: 0, g: 0, b: 0, a: 1 },
        storeOp: 'store',
      }],
    });
    p2.setPipeline(this.compPipeline);
    p2.setBindGroup(0, this.compositeBind);
    p2.draw(3);
    p2.end();

    d.queue.submit([enc.finish()]);
  }
}
