// boot.js — tier decision tree (DESIGN_SPEC §7). Two tiers in v1:
//   WEBGPU — the live substrate (starts Low, adapts up)
//   STATIC — the CSS-card monograph (also the JS-off experience)
// No WebGL2 tier (CRITIQUE cut #1). No runtime WEBGPU->STATIC demotion except
// freeze-to-frame. Preference overrides (forced-colors, prefers-contrast,
// prefers-reduced-transparency) mean canvas-off: that's what the settings ask for.

export function decideTier() {
  const forced = new URLSearchParams(location.search).get('tier');
  if (forced === 'static') return { tier: 'static', reason: 'forced' };
  for (const mq of [
    '(forced-colors: active)',
    '(prefers-contrast: more)',
    '(prefers-reduced-transparency: reduce)',
  ]) {
    if (matchMedia(mq).matches) return { tier: 'static', reason: 'preference' };
  }
  if (forced === 'webgpu') return { tier: 'webgpu', reason: 'forced' };
  if (!navigator.gpu) return { tier: 'static', reason: 'no-gpu' };
  return { tier: 'webgpu', reason: 'capable' }; // any failure downstream falls back to static
}

// The readout is the page's most trust-critical element: it must state the
// TRUE reason this visitor sees the static tier, not assume missing WebGPU.
const STATIC_READOUTS = {
  'no-gpu': 'render   STATIC — no WebGPU here. The live version draws itself in a WebGPU browser. Text is HTML either way.',
  preference: 'render   STATIC — canvas off, as your display preferences request. Text is HTML either way.',
  forced: 'render   STATIC — forced via ?tier=static. The live version draws itself in a WebGPU browser. Text is HTML either way.',
};

export function applyStatic(reason = 'no-gpu') {
  document.documentElement.classList.remove('gpu', 'tier-webgpu');
  document.documentElement.classList.add('tier-static');
  const line = STATIC_READOUTS[reason] || STATIC_READOUTS['no-gpu'];
  for (const el of document.querySelectorAll('[data-readout]')) {
    el.textContent = line;
  }
}

// called only after the first live frame has actually been submitted — the
// copy may claim "drawn by my own renderer" only once that is true
export function markGpuLive() {
  document.documentElement.classList.remove('tier-static');
  document.documentElement.classList.add('gpu', 'tier-webgpu');
}
