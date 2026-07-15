// v0 prototype — dark studio · liquid glass · drifting emissive glows
// Fullscreen ray-marched SDF scene, WGSL.

struct U {
  // res.x, res.y, time, dpr
  a : vec4f,
  // mouse.x, mouse.y (pixels, smoothed), mouseDown, hover
  b : vec4f,
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
fn sdRoundBox(p : vec3f, b : vec3f, r : f32) -> f32 {
  let q = abs(p) - b;
  return length(max(q, vec3f(0.0))) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
}

// ---------- scene ----------
// returns vec2(dist, materialId): 1 = glass, 2 = chrome
fn map(p : vec3f) -> vec2f {
  let t = u.a.z;

  // pointer in world-ish space
  let res = u.a.xy;
  let m = (u.b.xy / res * 2.0 - 1.0) * vec2f(res.x / res.y, -1.0);
  let mw = vec3f(m * 1.4, 0.0);

  // glass cluster: three drifting blobs + one pointer-chaser + a soft slab
  let p1 = vec3f(sin(t * 0.31) * 0.85, cos(t * 0.23) * 0.5, sin(t * 0.17) * 0.3);
  let p2 = vec3f(cos(t * 0.27) * 0.7, sin(t * 0.19) * -0.6, cos(t * 0.29) * 0.25);
  let p3 = vec3f(sin(t * 0.13 + 2.0) * 0.5, sin(t * 0.37) * 0.65, sin(t * 0.11) * 0.35);

  var g = sdSphere(p - p1, 0.42);
  g = smin(g, sdSphere(p - p2, 0.34), 0.35);
  g = smin(g, sdSphere(p - p3, 0.28), 0.35);
  // pointer chaser — swells slightly on press
  let chaseR = 0.30 + u.b.z * 0.06 + sin(t * 1.7) * 0.015;
  g = smin(g, sdSphere(p - mw, chaseR), 0.42);
  // a whisper of a panel slab behind, part of the same liquid body
  g = smin(g, sdRoundBox(p - vec3f(0.0, -0.05, -0.55), vec3f(1.1, 0.5, 0.015), 0.06), 0.24);

  // small chrome satellite
  let cpos = vec3f(cos(t * 0.5) * 1.5, sin(t * 0.8) * 0.9, 0.45 + sin(t * 0.33) * 0.2);
  let c = sdSphere(p - cpos, 0.12);

  if (c < g) { return vec2f(c, 2.0); }
  return vec2f(g, 1.0);
}

fn calcNormal(p : vec3f) -> vec3f {
  let e = vec2f(0.0007, -0.0007);
  return normalize(
    e.xyy * map(p + e.xyy).x +
    e.yyx * map(p + e.yyx).x +
    e.yxy * map(p + e.yxy).x +
    e.xxx * map(p + e.xxx).x);
}

// ---------- emissive glow field (analytic volumetric integral) ----------
// emitters drift BEHIND the glass; light integrates along any ray:
//   integral of k / ((t+B)^2 + h) dt = k/sqrt(h) * (atan((T+B)/S) - atan(B/S))
fn glowRay(ro : vec3f, rd : vec3f, tmax : f32) -> vec3f {
  let t = u.a.z;
  var col = vec3f(0.0);

  // three drifting emitters: magenta, cyan, amber
  var pos : array<vec3f, 3>;
  var tint : array<vec3f, 3>;
  pos[0] = vec3f(sin(t * 0.21) * 1.8, cos(t * 0.16) * 1.0, -1.6);
  tint[0] = vec3f(1.0, 0.18, 0.65) * 0.030;                      // magenta
  pos[1] = vec3f(cos(t * 0.17 + 1.5) * 2.0, sin(t * 0.25) * 1.2, -2.0);
  tint[1] = vec3f(0.15, 0.75, 1.0) * 0.026;                      // cyan
  pos[2] = vec3f(sin(t * 0.12 + 3.9) * 1.4, cos(t * 0.21 + 1.0) * -1.1, -1.3);
  tint[2] = vec3f(1.0, 0.62, 0.18) * 0.022;                      // amber

  // quartic emitter: k / (d^2 + r^2)^2 integrated along the ray (falls ~1/d^3:
  // tight bokeh cores, no scene-wide haze).
  //   f(u) = u / (2h(u^2+h)) + atan(u/sqrt(h)) / (2h*sqrt(h));  g = f(T+b) - f(b)
  for (var i = 0; i < 3; i++) {
    let q = ro - pos[i];
    let b = dot(q, rd);
    let c = dot(q, q);
    let h = max(c - b * b, 0.0) + 0.075;
    let s = inverseSqrt(h);
    let u1 = b;
    let u2 = tmax + b;
    let f1 = u1 / (2.0 * h * (u1 * u1 + h)) + atan(u1 * s) * s / (2.0 * h);
    let f2 = u2 / (2.0 * h * (u2 * u2 + h)) + atan(u2 * s) * s / (2.0 * h);
    col += tint[i] * max(f2 - f1, 0.0);
  }
  return col;
}

// ---------- procedural dark studio environment ----------
fn env(rd : vec3f) -> vec3f {
  // deep ink gradient
  var col = mix(vec3f(0.012, 0.014, 0.022), vec3f(0.05, 0.06, 0.09), rd.y * 0.5 + 0.5);
  // two soft area lights (overhead strip + side fill)
  let strip = smoothstep(0.55, 0.95, rd.y) * smoothstep(0.6, 0.0, abs(rd.x));
  col += vec3f(0.55, 0.6, 0.7) * strip * 0.6;
  let side = pow(max(dot(rd, normalize(vec3f(-0.8, 0.15, 0.4))), 0.0), 24.0);
  col += vec3f(0.4, 0.45, 0.6) * side * 0.35;
  return col;
}

// diffuse point-light contribution from the drifting emitters (lights the skins)
fn glowDiffuse(p : vec3f, n : vec3f) -> vec3f {
  let t = u.a.z;
  var pos : array<vec3f, 3>;
  var tint : array<vec3f, 3>;
  pos[0] = vec3f(sin(t * 0.21) * 1.8, cos(t * 0.16) * 1.0, -1.6);
  tint[0] = vec3f(1.0, 0.18, 0.65);
  pos[1] = vec3f(cos(t * 0.17 + 1.5) * 2.0, sin(t * 0.25) * 1.2, -2.0);
  tint[1] = vec3f(0.15, 0.75, 1.0);
  pos[2] = vec3f(sin(t * 0.12 + 3.9) * 1.4, cos(t * 0.21 + 1.0) * -1.1, -1.3);
  tint[2] = vec3f(1.0, 0.62, 0.18);
  var col = vec3f(0.0);
  for (var i = 0; i < 3; i++) {
    let l = pos[i] - p;
    let d2 = dot(l, l);
    let ndl = max(dot(n, l * inverseSqrt(d2)), 0.0);
    col += tint[i] * ndl / (1.0 + d2 * 0.6);
  }
  return col;
}

// thin-film iridescence tint
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

fn softShadowAO(p : vec3f, n : vec3f) -> f32 {
  // cheap AO from a few sdf samples along the normal
  var occ = 0.0;
  var w = 0.6;
  for (var i = 1; i <= 4; i++) {
    let h = 0.06 * f32(i);
    occ += (h - map(p + n * h).x) * w;
    w *= 0.65;
  }
  return clamp(1.0 - occ * 1.6, 0.0, 1.0);
}

@fragment
fn fs(in : VSOut) -> @location(0) vec4f {
  let res = u.a.xy;
  let frag = in.pos.xy;
  let uv = (frag / res * 2.0 - 1.0) * vec2f(res.x / res.y, -1.0);

  // camera
  let ro = vec3f(0.0, 0.0, 3.4);
  let rd = normalize(vec3f(uv * 0.62, -1.0));

  // background: env + naked glow field (the drifting lights themselves)
  var col = env(rd) * 0.35 + glowRay(ro, rd, 12.0);

  let hit = march(ro, rd);
  if (hit.y > 0.5) {
    let p = ro + rd * hit.x;
    let n = calcNormal(p);
    let cosT = clamp(dot(-rd, n), 0.0, 1.0);
    let ao = softShadowAO(p, n);

    if (hit.y < 1.5) {
      // ---- liquid glass ----
      let f0 = 0.04;
      var fres = f0 + (1.0 - f0) * pow(1.0 - cosT, 5.0);
      let irid = film(cosT);
      let refl = reflect(rd, n);
      let refr = refract(rd, n, 1.0 / 1.45);

      // reflection: studio env + glows
      let reflCol = (env(refl) + glowRay(p + n * 0.01, refl, 8.0)) * mix(vec3f(1.0), irid, 0.55);

      // transmission: glow field seen THROUGH the body + faint env, tinted by depth
      var thick = 0.25;
      {
        // estimate thickness with a short inside-march
        var tt = 0.02;
        for (var i = 0; i < 12; i++) {
          let dp = map(p + refr * tt).x;
          if (dp > 0.001) { break; }
          tt += max(-dp, 0.015);
        }
        thick = tt;
      }
      let absorb = exp(-vec3f(0.55, 0.28, 0.18) * thick * 2.6);   // inky teal-ish body
      let exitP = p + refr * (thick + 0.01);
      let refrCol = (glowRay(exitP, refr, 10.0) * 2.0 + env(refr) * 0.22) * absorb;

      col = mix(refrCol, reflCol, clamp(fres * 1.6, 0.0, 1.0));
      // the drifting lights kiss the glass skin
      col += glowDiffuse(p, n) * 0.10 * mix(vec3f(1.0), irid, 0.4);
      // bright fresnel rim kissed with iridescence
      col += irid * pow(1.0 - cosT, 3.0) * 0.28;
      col *= mix(0.75, 1.0, ao);
    } else {
      // ---- chrome ----
      let refl = reflect(rd, n);
      col = (env(refl) * 1.4 + glowRay(p + n * 0.01, refl, 8.0) * 3.0);
      col += glowDiffuse(p, n) * 0.06;
      col += vec3f(pow(1.0 - cosT, 4.0)) * 0.15;
      col *= mix(0.6, 1.0, ao);
    }
  }

  // tonemap + gamma + vignette
  col = col / (col + vec3f(0.85));                 // reinhard-ish
  col = pow(col, vec3f(1.0 / 2.2));
  let vig = 1.0 - 0.35 * dot(uv * 0.55, uv * 0.55);
  col *= vig;

  return vec4f(col, 1.0);
}
