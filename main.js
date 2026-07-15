// v0 prototype bootstrap — WebGPU fullscreen raymarcher
const canvas = document.getElementById('gfx');

async function init() {
  if (!navigator.gpu) return fail('no navigator.gpu');
  const adapter = await navigator.gpu.requestAdapter();
  if (!adapter) return fail('no adapter');
  const device = await adapter.requestDevice();
  const ctx = canvas.getContext('webgpu');
  const format = navigator.gpu.getPreferredCanvasFormat();
  ctx.configure({ device, format, alphaMode: 'opaque' });

  const code = await (await fetch('shader.wgsl')).text();
  const module = device.createShaderModule({ code });
  const info = await module.getCompilationInfo();
  for (const m of info.messages) {
    console[m.type === 'error' ? 'error' : 'warn'](
      `WGSL ${m.type} @${m.lineNum}:${m.linePos} ${m.message}`);
  }

  const pipeline = device.createRenderPipeline({
    layout: 'auto',
    vertex: { module, entryPoint: 'vs' },
    fragment: { module, entryPoint: 'fs', targets: [{ format }] },
    primitive: { topology: 'triangle-list' },
  });

  const ubuf = device.createBuffer({ size: 32, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  const bind = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [{ binding: 0, resource: { buffer: ubuf } }],
  });

  // pointer state (smoothed on CPU)
  const target = { x: innerWidth / 2, y: innerHeight / 2 };
  const mouse = { x: target.x, y: target.y, down: 0 };
  addEventListener('pointermove', e => { target.x = e.clientX; target.y = e.clientY; }, { passive: true });
  addEventListener('pointerdown', e => { mouse.down = 1; target.x = e.clientX; target.y = e.clientY; });
  addEventListener('pointerup', () => { mouse.down = 0; });

  const DPR_CAP = 1.5;
  function resize() {
    const dpr = Math.min(devicePixelRatio || 1, DPR_CAP);
    const w = Math.floor(canvas.clientWidth * dpr);
    const h = Math.floor(canvas.clientHeight * dpr);
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
    return dpr;
  }

  const t0 = performance.now();
  const u = new Float32Array(8);
  let visible = true;
  document.addEventListener('visibilitychange', () => { visible = !document.hidden; if (visible) requestAnimationFrame(frame); });

  function frame() {
    if (!visible) return;
    const dpr = resize();
    // smooth pointer (lag = the "liquid chases you" feel)
    mouse.x += (target.x - mouse.x) * 0.07;
    mouse.y += (target.y - mouse.y) * 0.07;

    u[0] = canvas.width; u[1] = canvas.height;
    u[2] = (performance.now() - t0) / 1000;
    u[3] = dpr;
    u[4] = mouse.x * dpr; u[5] = mouse.y * dpr;
    u[6] = mouse.down; u[7] = 0;
    device.queue.writeBuffer(ubuf, 0, u);

    const enc = device.createCommandEncoder();
    const pass = enc.beginRenderPass({
      colorAttachments: [{
        view: ctx.getCurrentTexture().createView(),
        loadOp: 'clear', clearValue: { r: 0.02, g: 0.03, b: 0.04, a: 1 },
        storeOp: 'store',
      }],
    });
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bind);
    pass.draw(3);
    pass.end();
    device.queue.submit([enc.finish()]);
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
}

function fail(why) {
  console.warn('WebGPU unavailable:', why);
  document.getElementById('nogpu').style.display = 'grid';
}

init().catch(e => { console.error(e); fail(e.message); });
