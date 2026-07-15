// v0.5 — dark studio · clear + frosted glass · crisp emissive lamps · squircle panel
// Materials: 1 = clear glass · 2 = chrome · 3 = emissive lamp · 4 = frosted glass

struct U {
  a : vec4f,  // res.x, res.y, time, dpr
  b : vec4f,  // mouse.x, mouse.y (pixels, smoothed), mouseDown, hover
};
@group(0) @binding(0) var<uniform> u : U;

// ---------- fullscreen triangle ----------
struct VSOut { @builtin(position) pos : vec4f };

@vertex
fn vs(@builtin(vertex_index) vi : u32) -> VSOut {
  var out : VSOut;
  let x = f32(i32(vi & 1u) * 4 - 1);
  let y = f32(i32(vi >> 1u) * 4 - 1);
  out.pos = vec4f(x, y, 0.0, 1.0);
  return out;
}

// ---------- sdf helpers ----------
fn smin(d1 : f32, d2 : f32, k : f32) -> f32 {
  let h = clamp(0.5 + 0.5 * (d2 - d1) / k, 0.0, 1.0);
  return mix(d2, d1, h) - k * h * (1.0 - h);
}
fn sdSphere(p : vec3f, r : f32) -> f32 { return length(p) - r; }

// continuous-curvature rounded slab (L4 norm corners — squircle, not circular arcs)
fn sdSquircleBox(p : vec3f, b : vec3f, r : f32) -> f32 {
  let q = abs(p) - b;
  let qc = max(q, vec3f(0.0));
  let q2 = qc * qc;
  let len4 = pow(dot(q2, q2), 0.25);   // (x^4+y^4+z^4)^(1/4)
  return len4 + min(max(q.x, max(q.y, q.z)), 0.0) - r;
}

// ---------- emitters (the "lamps") ----------
fn emitterPos(i : i32, t : f32) -> vec3f {
  if (i == 0) { return vec3f(sin(t * 0.21) * 1.8, cos(t * 0.16) * 1.0, -1.6); }
  if (i == 1) { return vec3f(cos(t * 0.17 + 1.5) * 2.0, sin(t * 0.25) * 1.2, -2.0); }
  return vec3f(sin(t * 0.12 + 3.9) * 1.4, cos(t * 0.21 + 1.0) * -1.1, -1.3);
}
fn emitterTint(i : i32) -> vec3f {
  if (i == 0) { return vec3f(1.0, 0.18, 0.65); }   // magenta
  if (i == 1) { return vec3f(0.15, 0.75, 1.0); }   // cyan
  return vec3f(1.0, 0.62, 0.18);                    // amber
}
const EMITTER_R : f32 = 0.17;

// ---------- scene ----------
// returns vec2(dist, materialId)
fn map(p : vec3f) -> vec2f {
  let t = u.a.z;

  let res = u.a.xy;
  let m = (u.b.xy / res * 2.0 - 1.0) * vec2f(res.x / res.y, -1.0);
  let mw = vec3f(m * 1.4, 0.0);

  // ---- glass group (one liquid body, mixed materials by nearest part) ----
  let p1 = vec3f(sin(t * 0.31) * 0.85, cos(t * 0.23) * 0.5, sin(t * 0.17) * 0.3);
  let p2 = vec3f(cos(t * 0.27) * 0.7, sin(t * 0.19) * -0.6, cos(t * 0.29) * 0.25);
  let p3 = vec3f(sin(t * 0.13 + 2.0) * 0.5, sin(t * 0.37) * 0.65, sin(t * 0.11) * 0.35);

  let dClear1 = sdSphere(p - p1, 0.42);                                   // clear drifting blob
  let chaseR = 0.30 + u.b.z * 0.06 + sin(t * 1.7) * 0.015;
  let dClear2 = sdSphere(p - mw, chaseR);                                 // clear pointer chaser
  let dFrost1 = sdSphere(p - p2, 0.34);
  let dFrost2 = sdSphere(p - p3, 0.28);
  let dPanel  = sdSquircleBox(p - vec3f(0.0, -0.05, -0.35), vec3f(1.15, 0.55, 0.02), 0.08);

  var g = dClear1;
  g = smin(g, dClear2, 0.42);
  g = smin(g, dFrost1, 0.35);
  g = smin(g, dFrost2, 0.35);
  g = smin(g, dPanel, 0.28);

  // nearest-part material for the group (clear=1, frosted=4)
  var gm = 1.0;
  var dNear = min(dClear1, dClear2);
  let dF = min(dFrost1, min(dFrost2, dPanel));
  if (dF < dNear) { gm = 4.0; }

  // ---- chrome satellite ----
  let cpos = vec3f(cos(t * 0.5) * 1.5, sin(t * 0.8) * 0.9, 0.45 + sin(t * 0.33) * 0.2);
  let c = sdSphere(p - cpos, 0.12);

  // ---- emissive lamps (crisp surfaces) ----
  var e = sdSphere(p - emitterPos(0, t), EMITTER_R);
  e = min(e, sdSphere(p - emitterPos(1, t), EMITTER_R));
  e = min(e, sdSphere(p - emitterPos(2, t), EMITTER_R));

  var d = g;
  var mat = gm;
  if (c < d) { d = c; mat = 2.0; }
  if (e < d) { d = e; mat = 3.0; }
  return vec2f(d, mat);
}

fn calcNormal(p : vec3f) -> vec3f {
  let e = vec2f(0.0007, -0.0007);
  return normalize(
    e.xyy * map(p + e.xyy).x +
    e.yyx * map(p + e.yyx).x +
    e.yxy * map(p + e.yxy).x +
    e.xxx * map(p + e.xxx).x);
}

// ---------- atmospheric halo around the lamps ----------
// quartic falloff integrated along the ray (~1/d^3): tight physically-plausible
// light spread hugging each lamp — the AIR glowing, not the lamp blurring.
// `spread` widens the falloff (used by frosted glass as its diffuser).
fn glowRay(ro : vec3f, rd : vec3f, tmax : f32, spread : f32) -> vec3f {
  let t = u.a.z;
  var col = vec3f(0.0);
  for (var i = 0; i < 3; i++) {
    let q = ro - emitterPos(i, t);
    let b = dot(q, rd);
    let c = dot(q, q);
    let h = max(c - b * b, 0.0) + 0.045 + spread;
    let s = inverseSqrt(h);
    let u1 = b;
    let u2 = tmax + b;
    let f1 = u1 / (2.0 * h * (u1 * u1 + h)) + atan(u1 * s) * s / (2.0 * h);
    let f2 = u2 / (2.0 * h * (u2 * u2 + h)) + atan(u2 * s) * s / (2.0 * h);
    col += emitterTint(i) * 0.011 * max(f2 - f1, 0.0);
  }
  return col;
}

// diffuse point-light from the lamps onto surfaces
fn glowDiffuse(p : vec3f, n : vec3f) -> vec3f {
  let t = u.a.z;
  var col = vec3f(0.0);
  for (var i = 0; i < 3; i++) {
    let l = emitterPos(i, t) - p;
    let d2 = dot(l, l);
    let ndl = max(dot(n, l * inverseSqrt(d2)), 0.0);
    col += emitterTint(i) * ndl / (1.0 + d2 * 0.6);
  }
  return col;
}

// ---------- procedural dark studio environment ----------
fn env(rd : vec3f) -> vec3f {
  var col = mix(vec3f(0.012, 0.014, 0.022), vec3f(0.05, 0.06, 0.09), rd.y * 0.5 + 0.5);
  let strip = smoothstep(0.55, 0.95, rd.y) * smoothstep(0.6, 0.0, abs(rd.x));
  col += vec3f(0.55, 0.6, 0.7) * strip * 0.6;
  let side = pow(max(dot(rd, normalize(vec3f(-0.8, 0.15, 0.4))), 0.0), 24.0);
  col += vec3f(0.4, 0.45, 0.6) * side * 0.35;
  return col;
}

// thin-film iridescence — accent only (frosted rims at grazing angles)
fn film(cosT : f32) -> vec3f {
  let phase = cosT * 5.5;
  return 0.5 + 0.5 * cos(6.28318 * phase + vec3f(0.0, 2.094, 4.188));
}

// ---------- ray march ----------
fn march(ro : vec3f, rd : vec3f) -> vec2f {
  var t = 0.0;
  var m = 0.0;
  for (var i = 0; i < 100; i++) {
    let p = ro + rd * t;
    let d = map(p);
    if (d.x < 0.0008 * t + 0.0004) { m = d.y; break; }
    t += d.x * 0.9;
    if (t > 12.0) { break; }
  }
  if (t > 12.0) { m = 0.0; }
  return vec2f(t, m);
}

fn ambOcc(p : vec3f, n : vec3f) -> f32 {
  var occ = 0.0;
  var w = 0.6;
  for (var i = 1; i <= 4; i++) {
    let h = 0.06 * f32(i);
    occ += (h - map(p + n * h).x) * w;
    w *= 0.65;
  }
  return clamp(1.0 - occ * 1.6, 0.0, 1.0);
}

// interior thickness estimate (shared by both glasses)
fn thickness(p : vec3f, refr : vec3f) -> f32 {
  var tt = 0.02;
  for (var i = 0; i < 12; i++) {
    let dp = map(p + refr * tt).x;
    if (dp > 0.001) { break; }
    tt += max(-dp, 0.015);
  }
  return tt;
}

@fragment
fn fs(in : VSOut) -> @location(0) vec4f {
  let res = u.a.xy;
  let frag = in.pos.xy;
  let uv = (frag / res * 2.0 - 1.0) * vec2f(res.x / res.y, -1.0);

  let ro = vec3f(0.0, 0.0, 3.4);
  let rd = normalize(vec3f(uv * 0.62, -1.0));

  // background: ink studio + the lamps' atmospheric halos
  var col = env(rd) * 0.35 + glowRay(ro, rd, 12.0, 0.0);

  let hit = march(ro, rd);
  if (hit.y > 0.5) {
    let p = ro + rd * hit.x;
    let n = calcNormal(p);
    let cosT = clamp(dot(-rd, n), 0.0, 1.0);
    let ao = ambOcc(p, n);
    let f0 = 0.04;
    let fres = f0 + (1.0 - f0) * pow(1.0 - cosT, 5.0);

    if (hit.y < 1.5) {
      // ---- CLEAR glass: water-clear, sharply refractive ----
      let refl = reflect(rd, n);
      let refr = refract(rd, n, 1.0 / 1.45);
      let reflCol = env(refl) + glowRay(p + n * 0.01, refl, 8.0, 0.0);

      let thick = thickness(p, refr);
      let absorb = exp(-vec3f(0.10, 0.06, 0.05) * thick * 2.0);   // barely-there tint
      let exitP = p + refr * (thick + 0.01);
      // crisp transmission: sharp halo sampling, no spread
      let refrCol = (glowRay(exitP, refr, 10.0, 0.0) * 2.4 + env(refr) * 0.5) * absorb;

      col = mix(refrCol, reflCol, clamp(fres * 1.5, 0.0, 1.0));
      col += vec3f(1.0) * pow(1.0 - cosT, 4.0) * 0.06;            // neutral rim, no rainbow
      col *= mix(0.85, 1.0, ao);

    } else if (hit.y < 2.5) {
      // ---- chrome ----
      let refl = reflect(rd, n);
      col = env(refl) * 1.4 + glowRay(p + n * 0.01, refl, 8.0, 0.0) * 3.0;
      col += glowDiffuse(p, n) * 0.05;
      col += vec3f(pow(1.0 - cosT, 4.0)) * 0.12;
      col *= mix(0.6, 1.0, ao);

    } else if (hit.y < 3.5) {
      // ---- emissive lamp: evenly-lit diffused surface, crisp silhouette ----
      var id = 0;
      var best = 1e9;
      let t = u.a.z;
      for (var i = 0; i < 3; i++) {
        let d = length(p - emitterPos(i, t));
        if (d < best) { best = d; id = i; }
      }
      // uniform emission with a whisper of limb softening — like an LED behind a diffuser
      col = emitterTint(id) * (2.6 * (0.84 + 0.16 * cosT));

    } else {
      // ---- FROSTED glass: even, milky transmission (the diffuser panel) ----
      let refl = reflect(rd, n);
      let refr = refract(rd, n, 1.0 / 1.45);

      let thick = thickness(p, refr);
      let absorb = exp(-vec3f(0.30, 0.22, 0.18) * thick * 1.6);
      let exitP = p + refr * (thick + 0.01);
      // WIDE spread = the frosting: lamp light smears evenly through the body
      let refrCol = (glowRay(exitP, refr, 10.0, 0.55) * 3.2 + env(refr) * 0.3) * absorb;

      // milk: soft ambient body + lamp diffuse on the surface
      let milk = vec3f(0.055, 0.06, 0.075) * ao + glowDiffuse(p, n) * 0.16;

      // soft, broad reflection only (no mirror sharpness on frosted)
      let reflCol = env(refl) * 0.5 + glowRay(p + n * 0.01, refl, 8.0, 0.30) * 0.8;

      col = refrCol + milk + reflCol * clamp(fres, 0.0, 1.0) * 0.7;
      // iridescence lives HERE only: subtle grazing accent
      col += film(cosT) * pow(1.0 - cosT, 4.0) * 0.055;
      col *= mix(0.8, 1.0, ao);
    }
  }

  // tonemap + gamma + vignette
  col = col / (col + vec3f(0.85));
  col = pow(col, vec3f(1.0 / 2.2));
  let vig = 1.0 - 0.35 * dot(uv * 0.55, uv * 0.55);
  col *= vig;

  return vec4f(col, 1.0);
}
