// animator.js — springs, focus-frost tracking, lamp choreography, energy
// budget. One animation state; the GPU scene buffer is its only consumer in
// v1 (text never moves — the monograph scrolls natively).
//
// The core mechanic (DESIGN_SPEC §4.1): the section panel under the reading
// line (38% of viewport height) focuses — frost springs 0.95 -> 0.35; the
// outgoing panel relaxes back slower (afterglow). Peripheral rest frost is
// 0.95, NOT lower: it must sit at/above the shader's march-skip constant so
// the skip actually fires (tests/copy-lint.sh enforces the pair).

import { MAT_GLASS, G_A, G_B, G_C, G_LAMPS } from './scene-format.js';
import { cssPointToScene, cssLenToScene } from './layout.js';

export const FROST_REST = 0.95;
export const FROST_FOCUS = 0.35;
export const PANEL_Z = -0.35;
export const PANEL_HZ = 0.005;
export const PANEL_K = 0.28;
export const PANEL_CORNER_PX = 24;

const READING_LINE = 0.38;   // of viewport height
const HYSTERESIS = 0.08;     // of viewport height
const SUBSTEP = 1 / 120;     // fixed substeps — deterministic across frame rates

// critically-damped spring step
function springStep(s, target, omega, dt) {
  const a = -2 * omega * s.v - omega * omega * (s.x - target);
  s.v += a * dt;
  s.x += s.v * dt;
}

export class Animator {
  constructor(layout, pool) {
    this.layout = layout;
    this.pool = pool;
    this.reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
    this.coarse = matchMedia('(pointer: coarse)').matches;

    this.panels = [];       // { name, entry, slot, frost: {x,v}, focused }
    this.focusName = null;

    this.scroll = { x: scrollY, v: 0 };
    this.pointer = { x: innerWidth / 2, y: innerHeight / 2, present: 0, inWindow: false };
    this.lampBias = { x: { x: 0, v: 0 }, y: { x: 0, v: 0 } };

    this.lastInput = performance.now();
    this.driftT = Math.random() * 100;   // drift phase origin
    this.driftAmp = 1;

    this.anchors = { lens: null, masthead: null, contact: null };
    this.acc = 0;
    this.lastT = 0;
    this.frameDt = 0;
  }

  addPanel(name, entry, slot) {
    const frost0 = FROST_REST;
    this.panels.push({ name, entry, slot, frost: { x: frost0, v: 0 }, focused: false });
  }

  input() { this.lastInput = performance.now(); }

  // measured alongside layout.measure() — doc-space anchors for the lamp itinerary
  measureAnchors() {
    const sy = scrollY;
    const lens = document.getElementById('email-lens');
    if (lens) {
      const r = lens.getBoundingClientRect();
      this.anchors.lens = { x: r.left + r.width / 2, y: r.top + r.height / 2 + sy };
    }
    const mast = this.layout.get('masthead');
    if (mast) this.anchors.masthead = { ...mast.doc };
    const contact = this.layout.get('contact');
    if (contact) this.anchors.contact = { ...contact.doc };
  }

  energyBudgetMs() { return this.coarse ? 10000 : 20000; }

  // returns true while another frame is needed
  tick(nowMs) {
    if (!this.lastT) this.lastT = nowMs;
    let dt = Math.min((nowMs - this.lastT) / 1000, 0.05);
    this.lastT = nowMs;
    this.frameDt = dt;

    // energy budget: full drift for 20 s (10 s coarse) after last input, then
    // amplitude eases to zero over 5 s and the loop stops entirely
    const idleMs = nowMs - this.lastInput;
    const over = idleMs - this.energyBudgetMs();
    this.driftAmp = this.reduced ? 0 : 1 - Math.min(Math.max(over / 5000, 0), 1);
    this.driftT += dt * this.driftAmp;

    // pointer presence ramp: 0->1 in 150 ms, 1->0 in 600 ms
    const pTarget = this.pointer.inWindow ? 1 : 0;
    const rate = pTarget > this.pointer.present ? dt / 0.15 : dt / 0.6;
    this.pointer.present += Math.sign(pTarget - this.pointer.present) *
      Math.min(rate, Math.abs(pTarget - this.pointer.present));

    // focus determination from the SMOOTHED scroll (hysteresis kills breathing)
    this.updateFocus();

    // fixed-substep springs
    this.acc += dt;
    let moving = false;
    while (this.acc >= SUBSTEP) {
      this.acc -= SUBSTEP;
      springStep(this.scroll, scrollY, 10, SUBSTEP);
      for (const p of this.panels) {
        const target = p.focused ? FROST_FOCUS : FROST_REST;
        if (this.reduced) {
          // 100 ms linear fade — feedback is accessibility, motion is not
          const step = SUBSTEP / 0.1 * (FROST_REST - FROST_FOCUS);
          p.frost.x += Math.sign(target - p.frost.x) * Math.min(step, Math.abs(target - p.frost.x));
          p.frost.v = 0;
        } else {
          springStep(p.frost, target, p.focused ? 8 : 5.5, SUBSTEP);
          p.frost.x = Math.min(Math.max(p.frost.x, FROST_FOCUS - 0.05), FROST_REST + 0.02);
        }
      }
    }

    if (Math.abs(this.scroll.v) > 0.5 || Math.abs(this.scroll.x - scrollY) > 0.5) moving = true;
    for (const p of this.panels) {
      const target = p.focused ? FROST_FOCUS : FROST_REST;
      if (Math.abs(p.frost.x - target) > 0.001 || Math.abs(p.frost.v) > 0.001) moving = true;
    }
    if (Math.abs(this.pointer.present - pTarget) > 0.001) moving = true;

    return moving || this.driftAmp > 0;
  }

  updateFocus() {
    const vpH = this.layout.vpH;
    const line = this.scroll.x + READING_LINE * vpH;
    const hys = HYSTERESIS * vpH;

    // the last panel (contact — the conversion surface) can be too short to
    // ever reach the reading line: once it is fully inside the viewport, it
    // takes focus outright
    const last = this.panels[this.panels.length - 1];
    if (last) {
      const top = last.entry.doc.top;
      const bottom = top + last.entry.doc.h;
      if (top >= this.scroll.x && bottom <= this.scroll.x + vpH) {
        this.applyFocus(last.name);
        return;
      }
    }

    const current = this.panels.find((p) => p.name === this.focusName);
    if (current) {
      const top = current.entry.doc.top;
      const bottom = top + current.entry.doc.h;
      if (line >= top - hys && line <= bottom + hys) {
        this.applyFocus(this.focusName);
        return;
      }
    }
    for (const p of this.panels) {
      if (line >= p.entry.doc.top && line <= p.entry.doc.top + p.entry.doc.h) {
        this.applyFocus(p.name);
        return;
      }
    }
    // in a gap between panels: keep the last focus (calmer than dropping it)
    this.applyFocus(this.focusName);
  }

  applyFocus(name) {
    this.focusName = name;
    for (const p of this.panels) p.focused = p.name === name;
  }

  // start settled: masthead focused at its final pose (no condense-on-load)
  settle() {
    this.scroll.x = scrollY;
    this.scroll.v = 0;
    this.updateFocus();
    for (const p of this.panels) {
      p.frost.x = p.focused ? FROST_FOCUS : FROST_REST;
      p.frost.v = 0;
    }
  }

  // ---- lamp itinerary (DESIGN_SPEC §4.2) --------------------------------
  // masthead: idles near the scroll cue with a margin-confined lazy pointer
  // bias; departs with the reader down the right margin lane; docked behind
  // the email lens before #contact enters view. Reduced motion: always docked.
  // All poses are computed in DOCUMENT space, converted to viewport at the end.
  lampPositions(dt) {
    const { vpW, vpH } = this.layout;
    const sy = this.scroll.x;
    const m = this.anchors.masthead;
    const lens = this.anchors.lens;
    const contact = this.anchors.contact;

    const out = [];
    const ss = (a, b, x) => {
      const t = Math.min(Math.max((x - a) / (b - a), 0), 1);
      return t * t * (3 - 2 * t);
    };

    // --- primary (magenta) ---
    let cssX, cssY, z;
    if (!m || !lens || !contact) {
      cssX = vpW * 0.8; cssY = vpH * 0.8; z = -1.3;
    } else {
      const mastheadRight = m.left + m.w;
      const laneX = Math.min(mastheadRight + (vpW - mastheadRight) * 0.5, vpW - 32);
      const cueDocY = m.top + m.h + 0.05 * vpH;
      const dockEnd = Math.max(contact.top - vpH, cueDocY + 1);
      const travelStart = 0.3 * vpH;
      let prog = (sy - travelStart) / Math.max(dockEnd - travelStart, 1);
      prog = Math.min(Math.max(prog, 0), 1);
      if (this.reduced) prog = 1;

      const toLane = ss(0, 0.25, prog);
      const toLens = ss(0.8, 1, prog);

      // idle pose near the cue (doc space) + drift + lazy pointer bias
      let ix = vpW / 2 + Math.sin(this.driftT * 0.5) * 30 * this.driftAmp;
      let iy = cueDocY + Math.cos(this.driftT * 0.37) * 18 * this.driftAmp;
      const pointerDocX = this.pointer.x;
      const pointerDocY = this.pointer.y + sy;
      const biasW = (1 - ss(0, 0.2, prog)) * this.pointer.present * (this.coarse ? 0 : 1);
      springStep(this.lampBias.x, (pointerDocX - ix) * 0.35 * biasW, 3, dt);
      springStep(this.lampBias.y, (pointerDocY - iy) * 0.25 * biasW, 3, dt);
      ix += this.lampBias.x.x;
      iy += this.lampBias.y.x;
      // margin confinement: while over the masthead block the lamp may not
      // enter the text column — it stays in the right margin lane
      if (iy < m.top + m.h) {
        ix = Math.max(ix, mastheadRight + 24);
      }

      const docX = ix + (laneX - ix) * toLane + (lens.x - laneX) * toLens;
      const docY = iy + (lens.y - iy) * prog;
      cssX = docX;
      cssY = docY - sy;
      z = -1.3 + (-0.55 - -1.3) * ss(0.7, 1, prog);
    }
    const [px, py] = cssPointToScene(cssX, cssY, z, vpW, vpH);
    out.push([px, py, z, 1.0]);

    // --- ambient pair: deep, dim, slow Lissajous, margins only ---
    // never near the text column: on narrow viewports they slide past the
    // viewport edge and only their halos bleed in
    const zc = -1.9, za = -1.6;
    const halfWc = cssLenToScene(vpW / 2, zc, vpH);
    const halfWa = cssLenToScene(vpW / 2, za, vpH);
    const colC = m ? cssLenToScene(m.w / 2 + 40, zc, vpH) + 0.55 : 0;
    const colA = m ? cssLenToScene(m.w / 2 + 40, za, vpH) + 0.5 : 0;
    const t = this.driftT;
    out.push([
      -Math.max(halfWc * 0.85, colC) + Math.sin(t * 0.17) * 0.35,
      0.1 + Math.cos(t * 0.23) * 0.55,
      zc, 0.8,
    ]);
    out.push([
      Math.max(halfWa * 0.85, colA) + Math.cos(t * 0.13 + 2.1) * 0.3,
      -0.3 + Math.sin(t * 0.19 + 0.7) * 0.5,
      za, 0.7,
    ]);
    return out;
  }

  // pack everything the GPU consumes this frame
  writeScene(globals, marchW, marchH, time, dt) {
    const { vpW, vpH } = this.layout;
    globals[G_A] = marchW;
    globals[G_A + 1] = marchH;
    globals[G_A + 2] = time;
    globals[G_A + 3] = dt;
    globals[G_B] = vpW;
    globals[G_B + 1] = vpH;
    globals[G_B + 2] = this.scroll.x;
    globals[G_B + 3] = this.pointer.present;
    const [psx, psy] = cssPointToScene(this.pointer.x, this.pointer.y, PANEL_Z, vpW, vpH);
    globals[G_C] = psx;
    globals[G_C + 1] = psy;
    globals[G_C + 2] = this.pool.count;
    globals[G_C + 3] = this.driftAmp;

    const lamps = this.lampPositions(dt);
    for (let i = 0; i < 3; i++) {
      globals[G_LAMPS + i * 4] = lamps[i][0];
      globals[G_LAMPS + i * 4 + 1] = lamps[i][1];
      globals[G_LAMPS + i * 4 + 2] = lamps[i][2];
      globals[G_LAMPS + i * 4 + 3] = lamps[i][3];
    }

    // fit panels to their DOM rects at the smoothed scroll
    const cornerR = cssLenToScene(PANEL_CORNER_PX, PANEL_Z, vpH);
    for (const p of this.panels) {
      const r = this.layout.sceneRect(p.entry, this.scroll.x, PANEL_Z);
      this.pool.setSlab(p.slot, r.x, r.y, PANEL_Z, r.hx, r.hy, PANEL_HZ,
        cornerR, PANEL_K, MAT_GLASS, p.frost.x);
    }
  }
}
