// march.wgsl — Pass 1: primary march + shading into an rgba16float target at
// renderScale. Output alpha is the tonemap weight: 1 = HDR (composite
// tonemaps), 0 = display-referred (pure lamps bypass the tonemapper — real
// LEDs are saturated at display max; Reinhard was pastel-washing them).
// Camera is THE pinned formula shared with js/gfx/layout.js:
//   ro = (0,0,3.4) · rd = normalize(vec3(uv*0.62, -1))

struct VSOut { @builtin(position) pos : vec4f };

@vertex
fn vs(@builtin(vertex_index) vi : u32) -> VSOut {
  var out : VSOut;
  let x = f32(i32(vi & 1u) * 4 - 1);
  let y = f32(i32(vi >> 1u) * 4 - 1);
  out.pos = vec4f(x, y, 0.0, 1.0);
  return out;
}

@fragment
fn fs(in : VSOut) -> @location(0) vec4f {
  let res = u.a.xy;
  let frag = in.pos.xy;
  // aspect comes from the CSS viewport (u.b.xy), NOT the floored subrect
  // dims — floor() skews res.x/res.y at small renderScale and would drift
  // glass-to-text registration by ~1-2 CSS px
  let uv = (frag / res * 2.0 - 1.0) * vec2f(u.b.x / u.b.y, -1.0);

  let ro = vec3f(0.0, 0.0, 3.4);
  let rd = normalize(vec3f(uv * 0.62, -1.0));

  let hit = march(ro, rd);
  if (hit.y < 0.0) {
    // solid black void — plus the lamps' analytic halos drifting in it
    return vec4f(glowRay(ro, rd, 9.0, 0.0) * 2.5, 1.0);
  }

  let p = ro + rd * hit.x;
  let n = calcNormal(p);
  let jit = ign(frag, u.a.z);

  // pure lamp: display-referred, fully saturated, bypasses tonemap
  if (codeClass(hit.y) == 3.0 && hit.w < 0.02) {
    let cosT = clamp(dot(-rd, n), 0.0, 1.0);
    let tint = emitterTint(nearestLamp(p));
    return vec4f(tint * (1.0 - 0.12 * pow(1.0 - cosT, 3.0)), 0.0);
  }

  var col = shadeMaterial(p, n, rd, hit.y, jit);
  if (hit.w > 0.02) {
    // blend neck: shade the other material too and cross-fade
    let colB = shadeMaterial(p, n, rd, hit.z, jit);
    col = mix(col, colB, hit.w);
  }
  // lamp haze between camera and surface — light drifts around the layers
  col += glowRay(ro, rd, hit.x, 0.0) * 2.5;
  return vec4f(col, 1.0);
}
