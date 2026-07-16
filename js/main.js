// main.js — entry: tier boot, module wiring, the demand-driven render loop.
// ES modules, no bundler, static files (the "view source" claim is a feature).
const V = 'c4993e4-181612'; // deploy.sh stamps this for cache-busted sub-resource fetches

import { decideTier, applyStatic, markGpuLive } from './gfx/boot.js';
import { Renderer } from './gfx/webgpu-renderer.js';
import { ScenePool } from './gfx/scene.js';
import { LayoutModel } from './gfx/layout.js';
import { Animator } from './gfx/animator.js';
import { Quality } from './gfx/quality.js';
import { GLOBALS_FLOATS, GLOBALS_SIZE, PRIM_STRIDE, LAMP_COUNT } from './gfx/scene-format.js';

console.assert(PRIM_STRIDE % 16 === 0, 'Prim stride must be 16-byte aligned');
console.assert(GLOBALS_SIZE % 16 === 0, 'Globals size must be 16-byte aligned');

const DPR_CAP = 1.2;
const SECTION_OF_PANEL = {
  masthead: 'top', work: 'work', career: 'career', colophon: 'colophon', contact: 'contact',
};

let bootAttempts = 0;

async function start() {
  const { tier, reason } = decideTier();
  if (tier !== 'webgpu') { applyStatic(reason); return; }
  try {
    await startGpu();
  } catch (e) {
    console.warn('WebGPU unavailable, static tier:', e);
    applyStatic('no-gpu');
  }
}

async function startGpu() {
  bootAttempts++;
  const canvas = document.getElementById('gfx');

  const bust = V === 'dev' ? Date.now() : V; // dev never caches; deploys are stamped
  const [renderer, common, march, composite] = await Promise.all([
    Renderer.create(canvas),
    fetch(`wgsl/common.wgsl?v=${bust}`).then((r) => r.text()),
    fetch(`wgsl/march.wgsl?v=${bust}`).then((r) => r.text()),
    fetch(`wgsl/composite.wgsl?v=${bust}`).then((r) => r.text()),
  ]);
  await renderer.initPipelines(common, march, composite);

  // ---- session teardown: device.lost must not leave a zombie session
  // (duplicate listeners, second rAF loop, second readout interval) behind
  const ac = new AbortController();
  let disposed = false;
  let raf = 0;
  let readoutTimer = 0;
  function dispose() {
    disposed = true;
    ac.abort();
    if (raf) { cancelAnimationFrame(raf); raf = 0; }
    if (readoutTimer) clearInterval(readoutTimer);
  }

  renderer.device.lost.then((info) => {
    console.warn('GPU device lost:', info.message);
    if (info.reason !== 'destroyed') {
      dispose();
      if (bootAttempts < 2) startGpu().catch(() => applyStatic('no-gpu'));
      else applyStatic('no-gpu');
    }
  });

  const layout = new LayoutModel();
  const pool = new ScenePool();
  const animator = new Animator(layout, pool);
  const quality = new Quality();
  const globals = new Float32Array(GLOBALS_FLOATS);

  for (const entry of layout.discover()) {
    animator.addPanel(entry.name, entry, pool.alloc());
  }
  animator.measureAnchors();
  animator.settle();

  function doResize() {
    const dpr = Math.min(devicePixelRatio || 1, DPR_CAP);
    renderer.resize(canvas.clientWidth, canvas.clientHeight, dpr);
  }
  doResize();

  function remeasure() {
    layout.measure();
    animator.measureAnchors();
  }

  // ---- demand-driven loop (DESIGN_SPEC §4.5): rendering stops when the
  // reader stops; scroll/pointer/focus re-arm it; the readout narrates both.
  const t0 = performance.now();
  let running = false;
  let lastFocus = null;

  function frame(now) {
    if (disposed) return;
    raf = 0;
    quality.frame(now);
    const animating = animator.tick(now);
    animator.writeScene(globals, 0, 0, (now - t0) / 1000, animator.frameDt);
    renderer.render(globals, pool, quality.scale, (now - t0) / 1000);
    syncAriaCurrent();
    if (animating) {
      schedule();
    } else {
      running = false;
      quality.pause();
      updateReadouts();
    }
  }
  function schedule() {
    if (disposed) return;
    running = true;
    if (!raf && !document.hidden) raf = requestAnimationFrame(frame);
  }
  function invalidate() { schedule(); }
  function wake() { animator.input(); invalidate(); }

  const opts = { passive: true, signal: ac.signal };
  addEventListener('scroll', wake, opts);
  addEventListener('pointermove', (e) => {
    animator.pointer.x = e.clientX;
    animator.pointer.y = e.clientY;
    animator.pointer.inWindow = true;
    wake();
  }, opts);
  addEventListener('pointerdown', wake, opts);
  document.documentElement.addEventListener('pointerleave', () => {
    animator.pointer.inWindow = false;
    invalidate();
  }, { signal: ac.signal });
  addEventListener('focusin', wake, { signal: ac.signal });
  addEventListener('resize', () => {
    doResize();
    remeasure();
    wake();
  }, { signal: ac.signal });
  document.fonts?.ready.then(() => {
    if (disposed) return;
    remeasure();
    invalidate();
  });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      if (raf) { cancelAnimationFrame(raf); raf = 0; }
      quality.pause();
    } else {
      wake();
    }
  }, { signal: ac.signal });

  // nav spine mirrors the focus tracker via aria-current
  function syncAriaCurrent() {
    if (animator.focusName === lastFocus) return;
    lastFocus = animator.focusName;
    const section = SECTION_OF_PANEL[animator.focusName];
    for (const a of document.querySelectorAll('.spine a')) {
      if (a.getAttribute('href') === `#${section}`) a.setAttribute('aria-current', 'true');
      else a.removeAttribute('aria-current');
    }
  }

  // live readout, ~1/s — it keeps updating while idle (the proof the stop
  // happened). Doubles as the layout-staleness watchdog: text-only zoom and
  // font-size changes reflow without firing resize, so re-fit on height drift.
  let lastDocHeight = document.documentElement.scrollHeight;
  function updateReadouts() {
    const h = document.documentElement.scrollHeight;
    if (h !== lastDocHeight) {
      lastDocHeight = h;
      remeasure();
      invalidate();
    }
    let text;
    if (!running) {
      text = 'render   WEBGPU · idle — 0 draws/s · move to wake';
    } else {
      const prims = pool.count + LAMP_COUNT;
      // fps prints only once actually measured — never the seeded constant
      const fpsTxt = quality.samples >= 3 ? `${Math.round(quality.fps)} fps` : '… fps';
      text = `render   WEBGPU · ${prims} prims live · ${fpsTxt}` +
        ` · scale ${quality.scale.toFixed(2)} · tier ${quality.tier()}`;
      const remaining = animator.energyBudgetMs() - (performance.now() - animator.lastInput);
      if (!animator.reduced && remaining > 0 && remaining < 15000) {
        text += ` · idle in ${Math.ceil(remaining / 1000)} s`;
      }
    }
    for (const el of document.querySelectorAll('[data-readout]')) el.textContent = text;
  }
  readoutTimer = setInterval(updateReadouts, 1000);

  // first frame, then flip the copy: the live claim becomes true exactly here
  frame(performance.now());
  markGpuLive();
  updateReadouts();

  // dev introspection (harmless in prod; not a public API)
  window.__fab = { animator, pool, layout, quality, globals };
}

start();
