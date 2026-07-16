// common.wgsl — structs, SDF prims, foldSmooth material blending, lamp light
// fields, environment, map(), march, and all material shading.
// Ported from the banked v0.6 shader: every tuned material constant is
// preserved verbatim. Changes for v1: prim POOL replaces the hardcoded scene,
// lamps ride a uniform (CPU choreography), behind-glass march is capped
// (DESIGN_SPEC §8 step 4b), tonemap/dither moved to the composite pass.
//
// Material codes: code = class*10 + param*9
//   class 1 glass (param = frost 0..1) · 2 metal (param 0 chrome..1 gold)
//   3 lamp · 4 matte ink · 5 pearl
// A hit carries TWO material codes + a blend weight; neck pixels shade both and mix.

// ---------- Globals (mirrors js/gfx/scene-format.js — edit both or neither) ----------
// a: marchW, marchH, time, dt
// b: cssW, cssH, scrollYSmoothed, pointerPresent
// c: pointerScene.xy, primCount, idleEnergy
// lamps[3]: xyz (scene units) + intensity
struct Globals {
  a : vec4f,
  b : vec4f,
  c : vec4f,
  lamps : array<vec4f, 3>,
};
@group(0) @binding(0) var<uniform> u : Globals;

// ---------- Prim pool (mirrors js/gfx/scene-format.js — edit both or neither) ----------
// posRadius: xyz + radius · params: halfExt.xyz + cornerR · contentRect: calm zone
// meta: kind, flags, matClass, reserved · blend: k, swell, squish, matParam · aux: free
struct Prim {
  posRadius   : vec4f,
  params      : vec4f,
  contentRect : vec4f,
  tag         : vec4u,
  blend       : vec4f,
  aux         : vec4f,
};
@group(0) @binding(1) var<storage, read> prims : array<Prim>;

const LAMP_COUNT : i32 = 3;
const EMITTER_R : f32 = 0.17;

// ---------- material codes ----------
fn mkCode(cls : f32, prm : f32) -> f32 { return cls * 10.0 + clamp(prm, 0.0, 1.0) * 9.0; }
fn codeClass(code : f32) -> f32 { return floor(code / 10.0); }
fn codeParam(code : f32) -> f32 { return (code - codeClass(code) * 10.0) / 9.0; }

// ---------- scene hit ----------
struct Hit {
  d : f32,
  mA : f32,   // dominant material code
  mB : f32,   // secondary material code (the other side of a blend neck)
  w : f32,    // mB's shading share (0 = pure mA)
};

// ---------- sdf helpers ----------
fn sdSphere(p : vec3f, r : f32) -> f32 { return length(p) - r; }

// L4-norm squircle: continuous-curvature corners CSS border-radius can't make
fn sdSquircleBox(p : vec3f, b : vec3f, r : f32) -> f32 {
  let q = abs(p) - b;
  let qc = max(q, vec3f(0.0));
  let q2 = qc * qc;
  let len4 = pow(dot(q2, q2), 0.25);
  return len4 + min(max(q.x, max(q.y, q.z)), 0.0) - r;
}

// universal smooth fold: geometry smins; same class -> param blends continuously;
// different class -> carry both materials + the smin weight for dual shading
fn foldSmooth(a : Hit, d : f32, code : f32, k : f32) -> Hit {
  let h = clamp(0.5 + 0.5 * (d - a.d) / k, 0.0, 1.0);   // h = share of a
  let dist = mix(d, a.d, h) - k * h * (1.0 - h);
  var out : Hit;
  out.d = dist;
  if (codeClass(a.mA) == codeClass(code) && a.w < 0.02) {
    // same family: continuous parameter blend, stays a single material
    out.mA = mkCode(codeClass(code), mix(codeParam(code), codeParam(a.mA), h));
    out.mB = out.mA;
    out.w = 0.0;
    return out;
  }
  if (h > 0.5) {
    out.mA = a.mA; out.mB = code; out.w = 1.0 - h;
  } else {
    out.mA = code; out.mB = a.mA; out.w = h;
  }
  return out;
}

// ---------- lamps (positions/intensity CPU-choreographed via Globals) ----------
fn lampPos(i : i32) -> vec3f { return u.lamps[i].xyz; }
fn lampGain(i : i32) -> f32 { return u.lamps[i].w; }
fn emitterTint(i : i32) -> vec3f {
  if (i == 0) { return vec3f(1.0, 0.18, 0.65); }
  if (i == 1) { return vec3f(0.15, 0.75, 1.0); }
  return vec3f(1.0, 0.62, 0.18);
}
fn nearestLamp(p : vec3f) -> i32 {
  var id = 0;
  var best = 1e9;
  for (var i = 0; i < LAMP_COUNT; i++) {
    let d = length(p - lampPos(i));
    if (d < best) { best = d; id = i; }
  }
  return id;
}

// ---------- scene ----------
fn map(p : vec3f) -> Hit {
  var h : Hit;
  h.d = 1e9;
  h.mA = mkCode(1.0, 1.0);
  h.mB = h.mA;
  h.w = 0.0;

  let count = u32(u.c.z);
  for (var i = 0u; i < count; i++) {
    let pr = prims[i];
    let k = max(pr.blend.x, 1e-4);
    let rel = p - pr.posRadius.xyz;
    var bound : f32;
    if (pr.tag.x == 1u) { bound = length(pr.params.xyz) + pr.params.w; }
    else { bound = pr.posRadius.w; }
    // exact skip: beyond a.d + k the fold is the identity
    if (length(rel) - bound - k > h.d) { continue; }
    var d : f32;
    if (pr.tag.x == 1u) { d = sdSquircleBox(rel, pr.params.xyz, pr.params.w); }
    else { d = sdSphere(rel, pr.posRadius.w); }
    h = foldSmooth(h, d, mkCode(f32(pr.tag.z), pr.blend.w), k);
  }

  for (var i = 0; i < LAMP_COUNT; i++) {
    h = foldSmooth(h, sdSphere(p - lampPos(i), EMITTER_R), mkCode(3.0, 0.0), 0.10);
  }
  return h;
}

fn calcNormal(p : vec3f) -> vec3f {
  let e = vec2f(0.0007, -0.0007);
  return normalize(
    e.xyy * map(p + e.xyy).d +
    e.yyx * map(p + e.yyx).d +
    e.yxy * map(p + e.yxy).d +
    e.xxx * map(p + e.xxx).d);
}

// ---------- lamp light fields (closed-form line integrals — zero bloom passes) ----------
fn glowRay(ro : vec3f, rd : vec3f, tmax : f32, spread : f32) -> vec3f {
  var col = vec3f(0.0);
  for (var i = 0; i < LAMP_COUNT; i++) {
    let q = ro - lampPos(i);
    let b = dot(q, rd);
    let c = dot(q, q);
    let hh = max(c - b * b, 0.0) + 0.045 + spread;
    let s = inverseSqrt(hh);
    let u1 = b;
    let u2 = tmax + b;
    let f1 = u1 / (2.0 * hh * (u1 * u1 + hh)) + atan(u1 * s) * s / (2.0 * hh);
    let f2 = u2 / (2.0 * hh * (u2 * u2 + hh)) + atan(u2 * s) * s / (2.0 * hh);
    col += emitterTint(i) * lampGain(i) * 0.011 * max(f2 - f1, 0.0);
  }
  return col;
}

fn glowSpec(p : vec3f, n : vec3f, rd : vec3f, shininess : f32) -> vec3f {
  var col = vec3f(0.0);
  for (var i = 0; i < LAMP_COUNT; i++) {
    let l = lampPos(i) - p;
    let d2 = dot(l, l);
    let ln = l * inverseSqrt(d2);
    let hv = normalize(ln - rd);
    col += emitterTint(i) * lampGain(i) * pow(max(dot(n, hv), 0.0), shininess) / (1.0 + d2 * 0.3);
  }
  return col;
}

fn glowDiffuse(p : vec3f, n : vec3f) -> vec3f {
  var col = vec3f(0.0);
  for (var i = 0; i < LAMP_COUNT; i++) {
    let l = lampPos(i) - p;
    let d2 = dot(l, l);
    let ndl = max(dot(n, l * inverseSqrt(d2)), 0.0);
    col += emitterTint(i) * lampGain(i) * ndl / (1.0 + d2 * 0.6);
  }
  return col;
}

fn glowBacklight(p : vec3f, rd : vec3f) -> vec3f {
  var col = vec3f(0.0);
  for (var i = 0; i < LAMP_COUNT; i++) {
    let l = lampPos(i) - p;
    let d2 = dot(l, l);
    let through = max(dot(rd, l * inverseSqrt(d2)), 0.0);
    col += emitterTint(i) * lampGain(i) * pow(through, 3.5) / (0.35 + d2 * 0.8);
  }
  return col;
}

// ---------- environment ----------
fn env(rd : vec3f) -> vec3f {
  var col = mix(vec3f(0.012, 0.014, 0.022), vec3f(0.05, 0.06, 0.09), rd.y * 0.5 + 0.5);
  let strip = smoothstep(0.55, 0.95, rd.y) * smoothstep(0.6, 0.0, abs(rd.x));
  col += vec3f(0.55, 0.6, 0.7) * strip * 0.6;
  let side = pow(max(dot(rd, normalize(vec3f(-0.8, 0.15, 0.4))), 0.0), 24.0);
  col += vec3f(0.4, 0.45, 0.6) * side * 0.35;
  return col;
}

fn film(cosT : f32) -> vec3f {
  let phase = cosT * 5.5;
  return 0.5 + 0.5 * cos(6.28318 * phase + vec3f(0.0, 2.094, 4.188));
}

// interleaved gradient noise, golden-ratio-cycled per frame
fn ign(p : vec2f, t : f32) -> f32 {
  let q = p + fract(t * 61.8034) * vec2f(23.14, 41.72);
  return fract(52.9829189 * fract(0.06711056 * q.x + 0.00583715 * q.y));
}

// ---------- ray march ----------
fn march(ro : vec3f, rd : vec3f) -> vec4f {   // (t, mA, mB, w); mA<0 = miss
  var t = 0.0;
  var h : Hit;
  var hitOk = -1.0;
  for (var i = 0; i < 80; i++) {
    let p = ro + rd * t;
    h = map(p);
    if (h.d < 0.0008 * t + 0.0004) { hitOk = 1.0; break; }
    t += h.d * 0.9;
    if (t > 9.0) { break; }
  }
  if (hitOk < 0.0 || t > 9.0) { return vec4f(t, -1.0, -1.0, 0.0); }
  return vec4f(t, h.mA, h.mB, h.w);
}

// capped behind-glass march (DESIGN_SPEC §8 step 4b): behind a reading panel a
// full-budget miss across the biggest panel on screen is the single worst
// pixel cost — cap steps and distance.
fn march2(ro : vec3f, rd : vec3f) -> vec4f {
  var t = 0.0;
  var h : Hit;
  var hitOk = -1.0;
  for (var i = 0; i < 32; i++) {
    let p = ro + rd * t;
    h = map(p);
    if (h.d < 0.0012 * t + 0.0006) { hitOk = 1.0; break; }
    t += h.d * 0.9;
    if (t > 4.0) { break; }
  }
  if (hitOk < 0.0 || t > 4.0) { return vec4f(t, -1.0, -1.0, 0.0); }
  return vec4f(t, h.mA, h.mB, h.w);
}

fn ambOcc(p : vec3f, n : vec3f) -> f32 {
  var occ = 0.0;
  var w = 0.6;
  for (var i = 1; i <= 3; i++) {
    let h = 0.06 * f32(i);
    occ += (h - map(p + n * h).d) * w;
    w *= 0.65;
  }
  return clamp(1.0 - occ * 1.6, 0.0, 1.0);
}

fn thickness(p : vec3f, refr : vec3f, jit : f32) -> f32 {
  var tIn = 0.01;
  var tt = 0.02 + jit * 0.011;
  for (var i = 0; i < 16; i++) {
    let dp = map(p + refr * tt).d;
    if (dp > 0.0) { break; }
    tIn = tt;
    tt += max(-dp * 0.9, 0.008);
    if (tt > 3.0) { break; }
  }
  var a = tIn;
  var b = tt;
  for (var i = 0; i < 7; i++) {   // 7-step bisection: exit lands on the surface
    let m = 0.5 * (a + b);
    if (map(p + refr * m).d < 0.0) { a = m; } else { b = m; }
  }
  return 0.5 * (a + b);
}

// simplified shading for surfaces seen THROUGH clear glass (single material, no recursion)
fn shadeSimple(p : vec3f, n : vec3f, rd : vec3f, code : f32) -> vec3f {
  let cls = codeClass(code);
  let prm = codeParam(code);
  let cosT = clamp(dot(-rd, n), 0.0, 1.0);
  if (cls == 3.0) {
    return emitterTint(nearestLamp(p)) * 4.0;
  } else if (cls == 2.0) {
    let f0tint = mix(vec3f(0.95, 0.96, 0.97), vec3f(1.0, 0.72, 0.32), prm);
    return f0tint * (env(reflect(rd, n)) * 1.2 + glowSpec(p, n, rd, 100.0));
  } else if (cls == 4.0) {
    return vec3f(0.05, 0.052, 0.066) * (vec3f(0.10, 0.11, 0.14) * 2.0 + glowDiffuse(p, n));
  } else if (cls == 5.0) {
    return vec3f(0.72, 0.73, 0.76) * (vec3f(0.10, 0.11, 0.14) * 4.2 + glowDiffuse(p, n) * 1.5)
         + glowSpec(p, n, rd, 160.0) * 0.9;
  }
  // glass through glass: frosted approximation
  let fres = 0.04 + 0.96 * pow(1.0 - cosT, 5.0);
  return glowRay(p, refract(rd, n, 1.0 / 1.45), 8.0, 0.4) * 2.5
       + env(reflect(rd, n)) * fres
       + vec3f(0.04, 0.045, 0.055) * glowDiffuse(p, n);
}

// full shading for one material code at a primary hit (returns linear HDR)
fn shadeMaterial(p : vec3f, n : vec3f, rd : vec3f, code : f32, jit : f32) -> vec3f {
  let cls = codeClass(code);
  let prm = codeParam(code);
  let cosT = clamp(dot(-rd, n), 0.0, 1.0);
  let ao = ambOcc(p, n);
  let f0 = 0.04;
  let fres = f0 + (1.0 - f0) * pow(1.0 - cosT, 5.0);
  var col = vec3f(0.0);

  if (cls == 1.0) {
    // ---- GLASS: frost in [0,1] blends clear -> diffuser ----
    let frost = prm;
    let refl = reflect(rd, n);
    let refr = refract(rd, n, 1.0 / 1.45);

    let thick = thickness(p, refr, jit);
    let absorbK = mix(vec3f(0.10, 0.06, 0.05) * 1.2, vec3f(0.30, 0.22, 0.18) * 1.6, frost);
    let absorb = exp(-absorbK * thick);
    let exitP = p + refr * thick;

    var clearCol = vec3f(0.0);
    // march-skip threshold: past it the glass is a pure diffuser. 0.94, a
    // margin BELOW the 0.95 rest frost: the f32 mkCode/codeParam roundtrip
    // reproduces 0.95 as 0.94999993, so a guard AT 0.95 would never fire —
    // the skip must actually skip, not just visually fade.
    if (frost < 0.94) {
      let nExit = calcNormal(exitP);
      let rr = reflect(refr, nExit);
      let tirCol = glowRay(exitP, rr, 8.0, 0.1) * 2.0 + env(rr) * 0.3;
      let cosX = clamp(dot(refr, nExit), 0.0, 1.0);
      let k = 1.0 - 1.45 * 1.45 * (1.0 - cosX * cosX);
      if (k > 0.0) {
        let refr2 = normalize(refract(refr, -nExit, 1.45));
        let ro2 = exitP + nExit * 0.02 + refr2 * 0.01;
        let h2 = march2(ro2, refr2);
        var marched = glowRay(ro2, refr2, 4.0, 0.0) * 2.5;   // void behind: still the lamps' halos
        if (h2.y > 0.0) {
          let p2 = ro2 + refr2 * h2.x;
          marched = shadeSimple(p2, calcNormal(p2), refr2, h2.y)
                  + glowRay(ro2, refr2, h2.x, 0.0) * 2.5;
        }
        clearCol = mix(tirCol, marched, smoothstep(0.0, 0.12, k));
      } else {
        clearCol = tirCol;
      }
    }

    let frostCol = glowRay(exitP, refr, 10.0, 0.55) * 4.6 + env(refr) * 0.3;
    let refrCol = mix(clearCol, frostCol, smoothstep(0.05, 0.95, frost)) * absorb;
    let backlight = glowBacklight(p, rd) * frost * 0.85;
    let reflCol = env(refl) * mix(1.0, 0.5, frost)
                + glowRay(p + n * 0.01, refl, 8.0, frost * 0.30) * mix(1.0, 0.8, frost);
    let milk = (vec3f(0.055, 0.06, 0.075) * ao + glowDiffuse(p, n) * 0.16) * frost;

    col = mix(refrCol, reflCol, clamp(fres * mix(1.5, 0.9, frost), 0.0, 1.0)) + milk + backlight;
    // rim; the glint tracks the pointer (masthead liveness proof)
    let pd = p.xy - u.c.xy;
    let glint = exp(-dot(pd, pd) * 6.0) * u.b.w;
    let rimW = pow(1.0 - cosT, 4.0);
    col += mix(vec3f(1.0) * 0.06, film(cosT) * 0.055, frost) * rimW * (1.0 + glint * 1.5);
    col *= mix(mix(0.85, 0.8, frost), 1.0, ao);

  } else if (cls == 2.0) {
    // ---- METAL: chrome -> satin gold ----
    let rough = mix(0.05, 0.35, prm);
    let f0tint = mix(vec3f(0.95, 0.96, 0.97), vec3f(1.0, 0.72, 0.32), prm);
    let refl = reflect(rd, n);
    let envAvg = vec3f(0.035, 0.04, 0.055);
    let reflCol = mix(env(refl), envAvg, clamp(rough * 1.8, 0.0, 1.0))
                + glowRay(p + n * 0.01, refl, 8.0, rough * 0.5) * mix(3.0, 2.0, prm);
    col = f0tint * reflCol * mix(1.4, 2.4, prm);
    col += f0tint * glowSpec(p, n, rd, mix(420.0, 48.0, rough)) * mix(1.2, 0.9, rough);
    col += f0tint * glowDiffuse(p, n) * 0.05;
    col += f0tint * pow(1.0 - cosT, 5.0) * 0.15;
    col *= mix(0.6, 1.0, ao);

  } else if (cls == 3.0) {
    // ---- LAMP as HDR emissive (blend-zone path; pure lamps early-return in fs) ----
    col = emitterTint(nearestLamp(p)) * 6.0 * (1.0 - 0.12 * pow(1.0 - cosT, 3.0));

  } else if (cls == 4.0) {
    // ---- MATTE INK ----
    let albedo = vec3f(0.05, 0.052, 0.066);
    let amb = vec3f(0.10, 0.11, 0.14);
    col = albedo * (amb * 2.0 * ao + glowDiffuse(p, n) * 1.1);
    col += vec3f(0.6, 0.65, 0.75) * pow(1.0 - cosT, 3.5) * 0.045;
    col += glowSpec(p, n, rd, 24.0) * 0.045;
    col *= mix(0.7, 1.0, ao);

  } else {
    // ---- PEARL ----
    let base = vec3f(0.72, 0.73, 0.76);
    col = base * (vec3f(0.10, 0.11, 0.14) * 4.2 * ao + glowDiffuse(p, n) * 1.5);
    col += glowSpec(p, n, rd, 160.0) * 0.9;
    col += env(reflect(rd, n)) * 0.18;
    col += film(cosT) * pow(1.0 - cosT, 2.5) * 0.06;
    col *= mix(0.8, 1.0, ao);
  }
  return col;
}
