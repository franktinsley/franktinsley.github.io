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
// smin that also blends a material parameter with the SAME weight as the geometry
// (Shapes-style: the material transitions across the blend neck, no seams)
fn sminMat(d1 : f32, m1 : f32, d2 : f32, m2 : f32, k : f32) -> vec2f {
  let h = clamp(0.5 + 0.5 * (d2 - d1) / k, 0.0, 1.0);
  let d = mix(d2, d1, h) - k * h * (1.0 - h);
  let m = mix(m2, m1, h);
  return vec2f(d, m);
}

// returns vec3(dist, materialClass, frost)  — class: 1 glass, 2 chrome, 3 lamp
fn map(p : vec3f) -> vec3f {
  let t = u.a.z;

  let res = u.a.xy;
  let m = (u.b.xy / res * 2.0 - 1.0) * vec2f(res.x / res.y, -1.0);
  let mw = vec3f(m * 1.4, 0.0);

  // ---- one liquid glass body; frost is a continuously blended parameter ----
  let p1 = vec3f(sin(t * 0.31) * 0.85, cos(t * 0.23) * 0.5, sin(t * 0.17) * 0.3);
  let p2 = vec3f(cos(t * 0.27) * 0.7, sin(t * 0.19) * -0.6, cos(t * 0.29) * 0.25);
  let p3 = vec3f(sin(t * 0.13 + 2.0) * 0.5, sin(t * 0.37) * 0.65, sin(t * 0.11) * 0.35);

  let dClear1 = sdSphere(p - p1, 0.42);                                   // frost 0
  let chaseR = 0.30 + u.b.z * 0.06 + sin(t * 1.7) * 0.015;
  let dClear2 = sdSphere(p - mw, chaseR);                                 // frost 0
  let dFrost1 = sdSphere(p - p2, 0.34);                                   // frost 1
  let dFrost2 = sdSphere(p - p3, 0.28);                                   // frost 1
  let dPanel  = sdSquircleBox(p - vec3f(0.0, -0.05, -0.35), vec3f(1.08, 0.48, 0.005), 0.15); // frost 0 — clear slab

  var g = vec2f(dClear1, 0.0);
  g = sminMat(g.x, g.y, dClear2, 0.0, 0.42);
  g = sminMat(g.x, g.y, dFrost1, 1.0, 0.35);
  g = sminMat(g.x, g.y, dFrost2, 1.0, 0.35);
  g = sminMat(g.x, g.y, dPanel,  0.0, 0.28);

  // ---- satellites: a small family of physical materials ----
  // chrome (metal 0) and satin gold (metal 1) share one parametric metal path
  let cpos = vec3f(cos(t * 0.5) * 1.5, sin(t * 0.8) * 0.9, 0.45 + sin(t * 0.33) * 0.2);
  let dChrome = sdSphere(p - cpos, 0.12);
  let gpos = vec3f(cos(t * 0.23 + 2.5) * 1.9, sin(t * 0.31 + 1.0) * 1.1, 0.3 + cos(t * 0.19) * 0.3);
  let dGold = sdSphere(p - gpos, 0.16);
  // matte ink ceramic — soft velvet dark
  let ipos = vec3f(sin(t * 0.15 + 4.5) * 1.7, -0.9 + sin(t * 0.22) * 0.3, 0.1);
  let dInk = sdSphere(p - ipos, 0.22);
  // small pearl
  let ppos = vec3f(sin(t * 0.4 + 1.0) * 1.2, 0.85 + cos(t * 0.27) * 0.25, 0.5);
  let dPearl = sdSphere(p - ppos, 0.09);

  // ---- emissive lamps (crisp surfaces) ----
  var e = sdSphere(p - emitterPos(0, t), EMITTER_R);
  e = min(e, sdSphere(p - emitterPos(1, t), EMITTER_R));
  e = min(e, sdSphere(p - emitterPos(2, t), EMITTER_R));

  var out = vec3f(g.x, 1.0, g.y);
  if (dChrome < out.x) { out = vec3f(dChrome, 2.0, 0.0); }
  if (dGold   < out.x) { out = vec3f(dGold,   2.0, 1.0); }
  if (dInk    < out.x) { out = vec3f(dInk,    4.0, 0.0); }
  if (dPearl  < out.x) { out = vec3f(dPearl,  5.0, 0.0); }
  if (e < out.x) { out = vec3f(e, 3.0, 0.0); }
  return out;
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

// specular highlights from the lamps (Blinn) — the hot sparkle that sells "physical"
fn glowSpec(p : vec3f, n : vec3f, rd : vec3f, shininess : f32) -> vec3f {
  let t = u.a.z;
  var col = vec3f(0.0);
  for (var i = 0; i < 3; i++) {
    let l = emitterPos(i, t) - p;
    let d2 = dot(l, l);
    let ln = l * inverseSqrt(d2);
    let hv = normalize(ln - rd);
    col += emitterTint(i) * pow(max(dot(n, hv), 0.0), shininess) / (1.0 + d2 * 0.3);
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

// simplified shading for surfaces seen THROUGH clear glass (no recursion)
fn shadeSimple(p : vec3f, n : vec3f, rd : vec3f, cls : f32, prm : f32) -> vec3f {
  let cosT = clamp(dot(-rd, n), 0.0, 1.0);
  if (cls > 2.5 && cls < 3.5) {
    // lamp: stays vivid through the glass
    var id = 0;
    var best = 1e9;
    let t = u.a.z;
    for (var i = 0; i < 3; i++) {
      let d = length(p - emitterPos(i, t));
      if (d < best) { best = d; id = i; }
    }
    return emitterTint(id) * 4.0;
  } else if (cls > 1.5 && cls < 2.5) {
    let f0tint = mix(vec3f(0.95, 0.96, 0.97), vec3f(1.0, 0.72, 0.32), prm);
    return f0tint * (env(reflect(rd, n)) * 1.2 + glowSpec(p, n, rd, 100.0));
  } else if (cls > 3.5 && cls < 4.5) {
    return vec3f(0.05, 0.052, 0.066) * (vec3f(0.10, 0.11, 0.14) * 2.0 + glowDiffuse(p, n));
  } else if (cls > 4.5) {
    return vec3f(0.72, 0.73, 0.76) * (vec3f(0.10, 0.11, 0.14) * 4.2 + glowDiffuse(p, n) * 1.5)
         + glowSpec(p, n, rd, 160.0) * 0.9;
  }
  // glass seen through glass: frosted approximation, no recursion
  let fres = 0.04 + 0.96 * pow(1.0 - cosT, 5.0);
  return glowRay(p, refract(rd, n, 1.0 / 1.45), 8.0, 0.4) * 2.5
       + env(reflect(rd, n)) * fres
       + vec3f(0.04, 0.045, 0.055) * glowDiffuse(p, n);
}

fn hash12(p : vec2f) -> f32 {
  var p3 = fract(vec3f(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

// ---------- ray march ----------
fn march(ro : vec3f, rd : vec3f) -> vec3f {
  var t = 0.0;
  var m = 0.0;
  var fr = 0.0;
  for (var i = 0; i < 80; i++) {
    let p = ro + rd * t;
    let d = map(p);
    if (d.x < 0.0008 * t + 0.0004) { m = d.y; fr = d.z; break; }
    t += d.x * 0.9;
    if (t > 9.0) { break; }
  }
  if (t > 9.0) { m = 0.0; }
  return vec3f(t, m, fr);
}

fn ambOcc(p : vec3f, n : vec3f) -> f32 {
  var occ = 0.0;
  var w = 0.6;
  for (var i = 1; i <= 3; i++) {
    let h = 0.06 * f32(i);
    occ += (h - map(p + n * h).x) * w;
    w *= 0.65;
  }
  return clamp(1.0 - occ * 1.6, 0.0, 1.0);
}

// interior crossing: adaptive march + bisection so the exit lands ON the surface
// (coarse fixed steps quantize the exit point -> banding rings in refractions)
fn thickness(p : vec3f, refr : vec3f, jit : f32) -> f32 {
  var tIn = 0.01;
  var tt = 0.02 + jit * 0.014;
  for (var i = 0; i < 16; i++) {
    let dp = map(p + refr * tt).x;
    if (dp > 0.0) { break; }
    tIn = tt;
    tt += max(-dp * 0.9, 0.008);
    if (tt > 3.0) { break; }
  }
  var a = tIn;
  var b = tt;
  for (var i = 0; i < 7; i++) {
    let m = 0.5 * (a + b);
    if (map(p + refr * m).x < 0.0) { a = m; } else { b = m; }
  }
  return 0.5 * (a + b);
}

@fragment
fn fs(in : VSOut) -> @location(0) vec4f {
  let res = u.a.xy;
  let frag = in.pos.xy;
  let uv = (frag / res * 2.0 - 1.0) * vec2f(res.x / res.y, -1.0);

  let ro = vec3f(0.0, 0.0, 3.4);
  let rd = normalize(vec3f(uv * 0.62, -1.0));

  // background: solid black — pure void; only objects and light exist.
  var col = vec3f(0.0);

  let hit = march(ro, rd);
  if (hit.y > 0.5) {
    let p = ro + rd * hit.x;
    let n = calcNormal(p);
    let cosT = clamp(dot(-rd, n), 0.0, 1.0);
    let ao = ambOcc(p, n);
    let f0 = 0.04;
    let fres = f0 + (1.0 - f0) * pow(1.0 - cosT, 5.0);

    if (hit.y < 1.5) {
      // ---- GLASS: one shading path, `frost` blends clear -> frosted continuously ----
      let frost = clamp(hit.z, 0.0, 1.0);
      let refl = reflect(rd, n);
      let refr = refract(rd, n, 1.0 / 1.45);

      let jit = hash12(frag + fract(u.a.z) * 61.7);
      let thick = thickness(p, refr, jit);
      let absorbK = mix(vec3f(0.10, 0.06, 0.05) * 1.2, vec3f(0.30, 0.22, 0.18) * 1.6, frost);
      let absorb = exp(-absorbK * thick);
      let exitP = p + refr * thick;

      // CLEAR transmission: true transparency — exit the body and march the scene behind
      var clearCol = vec3f(0.0);
      if (frost < 0.95) {
        let nExit = calcNormal(exitP);
        // internal-reflection estimate (used fully past the critical angle)
        let rr = reflect(refr, nExit);
        let tirCol = glowRay(exitP, rr, 8.0, 0.1) * 2.0 + env(rr) * 0.3;
        // smooth transition across the critical angle instead of a binary switch
        let cosX = clamp(dot(refr, nExit), 0.0, 1.0);
        let k = 1.0 - 1.45 * 1.45 * (1.0 - cosX * cosX);
        if (k > 0.0) {
          let refr2 = normalize(refract(refr, -nExit, 1.45));
          // push off along the exit NORMAL so the secondary ray starts cleanly outside
          let ro2 = exitP + nExit * 0.02 + refr2 * 0.01;
          let h2 = march(ro2, refr2);
          var marched = vec3f(0.0);
          if (h2.y > 0.5) {
            let p2 = ro2 + refr2 * h2.x;
            marched = shadeSimple(p2, calcNormal(p2), refr2, h2.y, h2.z);
          }
          clearCol = mix(tirCol, marched, smoothstep(0.0, 0.12, k));
        } else {
          clearCol = tirCol;
        }
      }

      // FROSTED transmission: the diffuser — lamp light spread wide and even
      let frostCol = glowRay(exitP, refr, 10.0, 0.55) * 4.6 + env(refr) * 0.3;

      let refrCol = mix(clearCol, frostCol, smoothstep(0.05, 0.95, frost)) * absorb;

      // backlight: a lamp BEHIND a diffuse body blooms through it toward the viewer
      var backlight = vec3f(0.0);
      {
        let tt = u.a.z;
        for (var i = 0; i < 3; i++) {
          let l = emitterPos(i, tt) - p;
          let d2 = dot(l, l);
          let through = max(dot(rd, l * inverseSqrt(d2)), 0.0);
          backlight += emitterTint(i) * pow(through, 3.5) / (0.35 + d2 * 0.8);
        }
        backlight *= frost * 0.85;
      }

      // reflection: sharp when clear, broad and dimmed when frosted
      let reflCol = env(refl) * mix(1.0, 0.5, frost)
                  + glowRay(p + n * 0.01, refl, 8.0, frost * 0.30) * mix(1.0, 0.8, frost);

      // milk: only as frost rises
      let milk = (vec3f(0.055, 0.06, 0.075) * ao + glowDiffuse(p, n) * 0.16) * frost;

      col = mix(refrCol, reflCol, clamp(fres * mix(1.5, 0.9, frost), 0.0, 1.0)) + milk + backlight;
      // rim: neutral on clear, faint iridescent accent emerging with frost
      let rimW = pow(1.0 - cosT, 4.0);
      col += mix(vec3f(1.0) * 0.06, film(cosT) * 0.055, frost) * rimW;
      col *= mix(mix(0.85, 0.8, frost), 1.0, ao);

    } else if (hit.y < 2.5) {
      // ---- METAL: parametric — 0 = polished chrome, 1 = satin gold ----
      let metal = clamp(hit.z, 0.0, 1.0);
      let rough = mix(0.05, 0.35, metal);
      let f0tint = mix(vec3f(0.95, 0.96, 0.97), vec3f(1.0, 0.72, 0.32), metal);
      let refl = reflect(rd, n);

      // roughness fades sharp env reflection toward a soft ambient, and widens lamp glints
      let envAvg = vec3f(0.035, 0.04, 0.055);
      let reflCol = mix(env(refl), envAvg, clamp(rough * 1.8, 0.0, 1.0))
                  + glowRay(p + n * 0.01, refl, 8.0, rough * 0.5) * mix(3.0, 2.0, metal);
      col = f0tint * reflCol * mix(1.4, 2.4, metal);   // satin needs more gain than mirror
      col += f0tint * glowSpec(p, n, rd, mix(420.0, 48.0, rough)) * mix(1.2, 0.9, rough);
      col += f0tint * glowDiffuse(p, n) * 0.05;
      col += f0tint * pow(1.0 - cosT, 5.0) * 0.15;
      col *= mix(0.6, 1.0, ao);

    } else if (hit.y < 3.5) {
      // ---- emissive lamp: display-referred (bypasses tonemap below) ----
      var id = 0;
      var best = 1e9;
      let t = u.a.z;
      for (var i = 0; i < 3; i++) {
        let d = length(p - emitterPos(i, t));
        if (d < best) { best = d; id = i; }
      }
      // fully saturated, evenly lit, faint limb softening — a diffused LED at full brightness
      let lampCol = emitterTint(id) * (1.0 - 0.12 * pow(1.0 - cosT, 3.0));
      return vec4f(lampCol, 1.0);

    } else if (hit.y < 4.5) {
      // ---- MATTE INK ceramic: velvet dark, lit only by lamps + soft sheen ----
      let albedo = vec3f(0.05, 0.052, 0.066);
      let amb = vec3f(0.10, 0.11, 0.14);
      col = albedo * (amb * 2.0 * ao + glowDiffuse(p, n) * 1.1);
      col += vec3f(0.6, 0.65, 0.75) * pow(1.0 - cosT, 3.5) * 0.045;   // velvet sheen rim
      col += glowSpec(p, n, rd, 24.0) * 0.045;                         // broad soft glints
      col *= mix(0.7, 1.0, ao);

    } else {
      // ---- PEARL: soft white, tight glints, whisper of nacre ----
      let base = vec3f(0.72, 0.73, 0.76);
      col = base * (vec3f(0.10, 0.11, 0.14) * 4.2 * ao + glowDiffuse(p, n) * 1.5);
      col += glowSpec(p, n, rd, 160.0) * 0.9;
      col += env(reflect(rd, n)) * 0.18;
      col += film(cosT) * pow(1.0 - cosT, 2.5) * 0.06;                 // nacre accent
      col *= mix(0.8, 1.0, ao);
    }
  }

  // tonemap + gamma (no vignette — flat background stays flat)
  col = col / (col + vec3f(0.85));
  col = pow(col, vec3f(1.0 / 2.2));

  return vec4f(col, 1.0);
}
