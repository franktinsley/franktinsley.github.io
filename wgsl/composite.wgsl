// composite.wgsl — Pass 2: upsample the march subrect to the swapchain,
// tonemap (same transfer as the banked v0.6 look: Reinhard shoulder + 2.2
// gamma), and dither in OUTPUT space (a dark-gradient site on 8-bit panels
// WILL band — the dither is non-negotiable).
// Self-contained: no common.wgsl include.

struct CU {
  s : vec4f,  // uvScale.x, uvScale.y, invCanvasW, invCanvasH
  t : vec4f,  // clampU, clampV, time, unused
};
@group(0) @binding(0) var<uniform> cu : CU;
@group(0) @binding(1) var srcTex : texture_2d<f32>;
@group(0) @binding(2) var samp : sampler;

struct VSOut { @builtin(position) pos : vec4f };

@vertex
fn vs(@builtin(vertex_index) vi : u32) -> VSOut {
  var out : VSOut;
  let x = f32(i32(vi & 1u) * 4 - 1);
  let y = f32(i32(vi >> 1u) * 4 - 1);
  out.pos = vec4f(x, y, 0.0, 1.0);
  return out;
}

fn hash12(p : vec2f) -> f32 {
  var p3 = fract(vec3f(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

@fragment
fn fs(in : VSOut) -> @location(0) vec4f {
  let frag = in.pos.xy;
  let uv01 = frag * cu.s.zw;
  // sample inside the live subrect only; clamp keeps the bilinear tap from
  // reading stale texels beyond it
  let tuv = min(uv01 * cu.s.xy, cu.t.xy);
  let c = textureSampleLevel(srcTex, samp, tuv, 0.0);

  // alpha = tonemap weight: 1 -> Reinhard + gamma; 0 -> display-referred lamps pass through
  let mapped = pow(c.rgb / (c.rgb + vec3f(0.85)), vec3f(1.0 / 2.2));
  var col = mix(c.rgb, mapped, c.a);

  // output-space dither, time-cycled
  col += vec3f(hash12(frag + fract(cu.t.z * 61.8034) * vec2f(37.71, 91.13)) - 0.5) / 255.0;
  return vec4f(col, 1.0);
}
