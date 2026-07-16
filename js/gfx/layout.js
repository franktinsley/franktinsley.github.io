// layout.js — LayoutModel: DOM measurement -> document-space rects -> scene units.
// The DOM owns layout; SDF prims are fitted to DOM rects, never the reverse.
//
// THE camera formula (CRITIQUE fix 6 — this is the single source of truth,
// mirrored by wgsl/march.wgsl):
//   ro = (0, 0, 3.4)
//   rd = normalize(vec3(uv * 0.62, -1))
//   uv = ((cssPoint - viewportCenter) * (1, -1)) / (viewportHeight / 2)
// A point on the z = Z plane therefore sits at scene.xy = uv * 0.62 * (3.4 - Z),
// so one CSS pixel spans  2 * 0.62 * (3.4 - Z) / viewportHeight  scene units.
// Independent of devicePixelRatio and renderScale by construction: the shader
// derives the same uv from its own resolution, so text/glass registration
// cannot depend on backing resolution.

export const CAMERA = { z: 3.4, fov: 0.62 };

export function sceneUnitsPerCssPx(z, vpH) {
  return (2 * CAMERA.fov * (CAMERA.z - z)) / vpH;
}

export function cssPointToScene(x, y, z, vpW, vpH) {
  const s = sceneUnitsPerCssPx(z, vpH);
  return [(x - vpW / 2) * s, -(y - vpH / 2) * s];
}

export function cssLenToScene(px, z, vpH) {
  return px * sceneUnitsPerCssPx(z, vpH);
}

// Fitted prims get their half-extents padded by this much (scene units), so
// the glass bleeds slightly past the text block (BUILD_PLAN §1.8).
export const FIT_BLEED = 0.015;

export class LayoutModel {
  constructor() {
    this.entries = [];       // { name, el, doc: {left, top, w, h} }
    this.vpW = innerWidth;
    this.vpH = innerHeight;
  }

  discover() {
    this.entries = [...document.querySelectorAll('[data-sdf]')].map((el) => ({
      name: el.dataset.sdf,
      el,
      doc: { left: 0, top: 0, w: 0, h: 0 },
    }));
    this.measure();
    return this.entries;
  }

  // Measure RARELY: boot, resize, fonts.ready — never in a scroll handler.
  // Rects are stored in document space (viewport rect + scrollY).
  measure() {
    this.vpW = innerWidth;
    this.vpH = innerHeight;
    const sy = scrollY;
    for (const e of this.entries) {
      const r = e.el.getBoundingClientRect();
      e.doc = { left: r.left, top: r.top + sy, w: r.width, h: r.height };
    }
  }

  get(name) {
    return this.entries.find((e) => e.name === name);
  }

  // Per frame, compute cheaply: document rect -> scene-space center +
  // half-extents at plane z, using the SMOOTHED scroll value (glass follows
  // the spring; the DOM scrolls natively).
  sceneRect(entry, smoothScrollY, z) {
    const { doc } = entry;
    const cx = doc.left + doc.w / 2;
    const cy = doc.top + doc.h / 2 - smoothScrollY;
    const [x, y] = cssPointToScene(cx, cy, z, this.vpW, this.vpH);
    const hx = cssLenToScene(doc.w / 2, z, this.vpH) + FIT_BLEED;
    const hy = cssLenToScene(doc.h / 2, z, this.vpH) + FIT_BLEED;
    return { x, y, hx, hy };
  }
}
