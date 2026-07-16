// scene-format.js — THE buffer layout constants (single source of truth).
// WGSL structs in wgsl/common.wgsl carry a mirroring comment table; edit both
// or edit neither. Dev boot assertions live in main.js.

export const MAX_PRIMS = 24;

// Prim stride: 6 vec4s = 96 bytes = 24 floats.
//   posRadius   : vec4f  — xyz position (scene units), w radius (spheres)
//   params      : vec4f  — halfExtents.xyz + cornerR (slabs)
//   contentRect : vec4f  — calm zone, prim-local (0 = none; wired in a later step)
//   meta        : vec4u  — x kind, y flags, z materialClass, w reserved
//   blend       : vec4f  — x smin k, y swell, z squish, w materialParam
//   aux         : vec4f  — x roughness override (later), rest free
export const PRIM_FLOATS = 24;
export const PRIM_STRIDE = PRIM_FLOATS * 4;

// float offsets within one prim
export const OFF_POS = 0;      // x,y,z,radius
export const OFF_PARAMS = 4;   // hx,hy,hz,cornerR
export const OFF_CONTENT = 8;
export const OFF_META = 12;    // u32 view
export const OFF_BLEND = 16;   // k, swell, squish, matParam
export const OFF_AUX = 20;

export const KIND_SPHERE = 0;
export const KIND_SLAB = 1;
export const KIND_PILL = 2;

// material classes (shader codes: code = class*10 + param*9)
export const MAT_GLASS = 1;  // param = frost 0..1
export const MAT_METAL = 2;  // param = 0 chrome .. 1 gold
export const MAT_LAMP = 3;
export const MAT_INK = 4;

// Globals uniform: 6 vec4s = 96 bytes = 24 floats.
//   a: marchW, marchH, time, dt
//   b: cssW, cssH, scrollYSmoothed, pointerPresent
//   c: pointerSceneX, pointerSceneY, primCount, idleEnergy
//   lamps[3]: xyz (scene units) + intensity
export const GLOBALS_FLOATS = 24;
export const GLOBALS_SIZE = GLOBALS_FLOATS * 4;
export const G_A = 0;
export const G_B = 4;
export const G_C = 8;
export const G_LAMPS = 12;

export const LAMP_COUNT = 3;

// The clear-glass (refracted-bounce) path is skipped at/above this frost.
// 0.94, deliberately BELOW the 0.95 peripheral rest: the f32 material-code
// roundtrip reproduces 0.95 as 0.94999993, so a guard at 0.95 never fires.
// tests/copy-lint.sh cross-checks this constant == the wgsl guard, and
// FROST_REST (animator.js) >= it.
export const FROST_SKIP_THRESHOLD = 0.94;
