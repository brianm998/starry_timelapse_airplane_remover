// WGPUShaders.h — the WGSL source for the wgpu-native backend (WGPUBackend.cpp).
//
// A port of the Metal kernels in StarCppBridge/GPUOps.swift (`warp_*`, `aligned_merge_*`): the same
// OpenCV 1/32-pixel fixed-point position, the same renormalised bilinear weights, the same
// sigma-clipped median. The Metal backend stays the reference for what they compute.
//
// What WGSL forces to be different from MSL:
//
//  * No 8- or 16-bit storage types. Every image is an `array<u32>` and a component is pulled out of its
//    word by shift and mask (`ld`). The pixel type is the pipeline constant BPC (1 or 2 bytes), so one
//    source serves both depths.
//  * No sub-word stores, and two threads writing different bytes of one word race. So a thread owns one
//    whole output word (4 u8 components or 2 u16 ones) and the destination is a packed buffer of
//    `out_words_per_row` words per row, which the C++ side copies out to the Mat's own row step.
//  * No arrays of bindings. The 17 possible sources are 17 separate bindings, picked with a switch
//    (`ld`), and the warp-only entry point uses `ld0` so its auto-derived layout needs just three.
//  * Scalars and the 16 inverse homographies live in one uniform buffer, so they do not count against
//    the per-stage storage-buffer limit the 17 sources already press on.
//  * Float arithmetic is not promised to stay in the order written. The Metal kernel carries the
//    projection in float-float ("double-float") arithmetic, whose error-free transforms need that
//    promise kept; through wgpu on Metal it was not — against an exact reference it got 0.40% of
//    pixels onto the wrong 1/32 step, the rate of a plain float projection — and Vulkan and Direct3D
//    compilers are no more controllable. So this kernel does not use it. The CPU gives every 16x16 tile
//    its origin's projected position exactly (double, as an integer step count plus a fraction), and
//    the shader adds only a small offset from that origin, in plain float:
//
//        (N0 + dN) / (W0 + dW)  =  q0 + (dN - q0 * dW) / (W0 + dW),    q0 = N0 / W0
//
//    Every term on the right is small, so nothing depends on how the compiler orders it and the
//    error is about 1e-4 of a 1/32 step, a rate of wrong steps far below OpenCV's own.
#pragma once

static const char *const kWgslSource = R"WGSL(
override BPC: u32 = 1u;          // bytes per component: 1 (8-bit) or 2 (16-bit)
override MAXV: f32 = 255.0;      // largest component value

struct Params {
    width: u32,
    height: u32,
    channels: u32,
    count: u32,                  // neighbours (aligned merge); unused by the warp
    include_all: u32,
    outlier: f32,
    out_words_per_row: u32,
    tiles_x: u32,                // tiles across: ceil(width / TS)
    tiles_per_neighbour: u32,    // tiles_x * ceil(height / TS)
    has_misses: u32,             // median merge: a misses plane is bound
    miss_step: u32,              // median merge: that plane's row step in bytes
    pad2: u32,
    steps: array<vec4<u32>, 5>,  // row step in BYTES of source i (0 = base / warp source, 1... = neighbours)
    hinv: array<vec4<f32>, 36>,  // per neighbour nine floats: the INVERSE homography, row-major
};

@group(0) @binding(0) var<uniform> P: Params;
@group(0) @binding(1) var<storage, read_write> OUT: array<u32>;
@group(0) @binding(2) var<storage, read> S0: array<u32>;
@group(0) @binding(3) var<storage, read> S1: array<u32>;
@group(0) @binding(4) var<storage, read> S2: array<u32>;
@group(0) @binding(5) var<storage, read> S3: array<u32>;
@group(0) @binding(6) var<storage, read> S4: array<u32>;
@group(0) @binding(7) var<storage, read> S5: array<u32>;
@group(0) @binding(8) var<storage, read> S6: array<u32>;
@group(0) @binding(9) var<storage, read> S7: array<u32>;
@group(0) @binding(10) var<storage, read> S8: array<u32>;
@group(0) @binding(11) var<storage, read> S9: array<u32>;
@group(0) @binding(12) var<storage, read> S10: array<u32>;
@group(0) @binding(13) var<storage, read> S11: array<u32>;
@group(0) @binding(14) var<storage, read> S12: array<u32>;
@group(0) @binding(15) var<storage, read> S13: array<u32>;
@group(0) @binding(16) var<storage, read> S14: array<u32>;
@group(0) @binding(17) var<storage, read> S15: array<u32>;
@group(0) @binding(18) var<storage, read> S16: array<u32>;
// Per neighbour, per 16x16 tile, five floats: the tile origin's projected column and row as
// (integer step count, fraction of a step) each, then W at the origin. W0 == 0 marks "uncovered".
@group(0) @binding(19) var<storage, read> TILES: array<f32>;
// The standalone median merge's coverage-misses plane: one byte a pixel, `miss_step` bytes a row.
@group(0) @binding(20) var<storage, read> MISS: array<u32>;

const TS: u32 = 16u;

fn step_of(i: u32) -> u32 { return P.steps[i >> 2u][i & 3u]; }

fn hv(n: u32, k: u32) -> f32 {
    let idx = n * 9u + k;
    return P.hinv[idx >> 2u][idx & 3u];
}

// The component at byte address `a` of a word array, as an integer.
fn extract(w: u32, a: u32) -> u32 {
    let shift = (a & 3u) * 8u;
    let mask = select(0xffffu, 0xffu, BPC == 1u);
    return (w >> shift) & mask;
}

fn ld0(a: u32) -> u32 { return extract(S0[a >> 2u], a); }

fn ld(i: u32, a: u32) -> u32 {
    let w = a >> 2u;
    switch (i) {
        case 0u:  { return extract(S0[w], a); }
        case 1u:  { return extract(S1[w], a); }
        case 2u:  { return extract(S2[w], a); }
        case 3u:  { return extract(S3[w], a); }
        case 4u:  { return extract(S4[w], a); }
        case 5u:  { return extract(S5[w], a); }
        case 6u:  { return extract(S6[w], a); }
        case 7u:  { return extract(S7[w], a); }
        case 8u:  { return extract(S8[w], a); }
        case 9u:  { return extract(S9[w], a); }
        case 10u: { return extract(S10[w], a); }
        case 11u: { return extract(S11[w], a); }
        case 12u: { return extract(S12[w], a); }
        case 13u: { return extract(S13[w], a); }
        case 14u: { return extract(S14[w], a); }
        case 15u: { return extract(S15[w], a); }
        default:  { return extract(S16[w], a); }
    }
}

fn sample_valid(x: i32, y: i32) -> bool {
    return x >= 0 && x < i32(P.width) && y >= 0 && y < i32(P.height);
}

struct Tap {
    covered: bool,
    ix: i32, iy: i32,
    w00: f32, w10: f32, w01: f32, w11: f32, wsum: f32,
    v00: bool, v10: bool, v01: bool, v11: bool,
};

// Where destination pixel (px, py) samples neighbour `n`'s inverse homography, and whether it samples
// anything at all (`covered` is false exactly where BORDER_TRANSPARENT leaves the destination untouched).
// OpenCV's INTER_LINEAR does not interpolate at the exact fractional position: it rounds the position
// to one of 32 steps per pixel and splits that into pixel and step. Matching that quantisation is most
// of what makes this track OpenCV's output (see the file comment for how the position is computed).
fn warp_tap(n: u32, px: i32, py: i32) -> Tap {
    var t: Tap;
    t.covered = false;
    let ux = u32(px);
    let uy = u32(py);
    let base = (n * P.tiles_per_neighbour + (uy / TS) * P.tiles_x + (ux / TS)) * 5u;
    let w0 = TILES[base + 4u];
    if (w0 == 0.0) { return t; }
    let dx = f32(ux % TS);
    let dy = f32(uy % TS);
    let dw = hv(n, 6u) * dx + hv(n, 7u) * dy;
    let w = w0 + dw;
    if (abs(w) < 1e-12) { return t; }
    let inv_w = 1.0 / w;

    let ixq = TILES[base];
    let fxq = TILES[base + 1u];
    let iyq = TILES[base + 2u];
    let fyq = TILES[base + 3u];
    // the origin's position as a float only ever multiplies the small dw, so its ulp does not matter
    let qx = (ixq + fxq) * (1.0 / 32.0);
    let qy = (iyq + fyq) * (1.0 / 32.0);
    let cx = (hv(n, 0u) * dx + hv(n, 1u) * dy - qx * dw) * inv_w;
    let cy = (hv(n, 3u) * dx + hv(n, 4u) * dy - qy * dw) * inv_w;
    let rx = fxq + 32.0 * cx;
    let ry = fyq + 32.0 * cy;
    if (!(abs(rx) < 1.0e6) || !(abs(ry) < 1.0e6)) { return t; }

    // round(position * 32), ties to even (WGSL's round): the integer part is exact, so only the small
    // remainder is rounded
    let xq = i32(ixq) + i32(round(rx));
    let yq = i32(iyq) + i32(round(ry));
    let ix = xq >> 5u;
    let iy = yq >> 5u;
    let fx = f32(xq & 31) / 32.0;
    let fy = f32(yq & 31) / 32.0;

    t.w00 = (1.0 - fx) * (1.0 - fy);
    t.w10 = fx * (1.0 - fy);
    t.w01 = (1.0 - fx) * fy;
    t.w11 = fx * fy;
    t.v00 = sample_valid(ix, iy);
    t.v10 = sample_valid(ix + 1, iy);
    t.v01 = sample_valid(ix, iy + 1);
    t.v11 = sample_valid(ix + 1, iy + 1);
    if (!t.v00 && !t.v10 && !t.v01 && !t.v11) { return t; }

    t.wsum = select(0.0, t.w00, t.v00) + select(0.0, t.w10, t.v10)
           + select(0.0, t.w01, t.v01) + select(0.0, t.w11, t.v11);
    if (t.wsum <= 1e-6) { return t; }
    t.ix = ix;
    t.iy = iy;
    t.covered = true;
    return t;
}

fn addr_of(step: u32, x: u32, y: u32, c: u32) -> u32 {
    return y * step + (x * P.channels + c) * BPC;
}

// Channel c of a covered tap on source `src`: the bilinear sample renormalised by the corners that exist,
// rounded to the pixel type. `src` selects through ld(); the warp entry point calls tap_value0 instead.
fn tap_value(src: u32, t: Tap, c: u32) -> f32 {
    let step = step_of(src);
    let ux = u32(t.ix);
    let uy = u32(t.iy);
    var acc = 0.0;
    if (t.v00) { acc += t.w00 * f32(ld(src, addr_of(step, ux,      uy,      c))); }
    if (t.v10) { acc += t.w10 * f32(ld(src, addr_of(step, ux + 1u, uy,      c))); }
    if (t.v01) { acc += t.w01 * f32(ld(src, addr_of(step, ux,      uy + 1u, c))); }
    if (t.v11) { acc += t.w11 * f32(ld(src, addr_of(step, ux + 1u, uy + 1u, c))); }
    return floor(clamp(acc / t.wsum + 0.5, 0.0, MAXV));
}

fn tap_value0(t: Tap, c: u32) -> f32 {
    let step = step_of(0u);
    let ux = u32(t.ix);
    let uy = u32(t.iy);
    var acc = 0.0;
    if (t.v00) { acc += t.w00 * f32(ld0(addr_of(step, ux,      uy,      c))); }
    if (t.v10) { acc += t.w10 * f32(ld0(addr_of(step, ux + 1u, uy,      c))); }
    if (t.v01) { acc += t.w01 * f32(ld0(addr_of(step, ux,      uy + 1u, c))); }
    if (t.v11) { acc += t.w11 * f32(ld0(addr_of(step, ux + 1u, uy + 1u, c))); }
    return floor(clamp(acc / t.wsum + 0.5, 0.0, MAXV));
}

// Sorts v[0, n) ascending and returns the sample medianMergeTyped (ImageAligner.cpp) selects: the first
// `miss` entries are no-data zeros skipped by count alone (the CoverageMisses contract), the rest is
// sigma-clipped at mean + outlier * stddev, and the midpoint of what survives wins.
fn sigma_clipped_median(v: ptr<function, array<f32, 17>>, n: u32, miss: u32, include_all: bool,
                        outlier: f32) -> f32 {
    for (var i = 1u; i < n; i++) {
        let key = (*v)[i];
        var j = i32(i) - 1;
        while (j >= 0 && (*v)[j] > key) {
            (*v)[j + 1] = (*v)[j];
            j -= 1;
        }
        (*v)[j + 1] = key;
    }

    let min_index = select(min(miss, n), 0u, include_all);
    let first = select(min(min_index, n - 1u), 0u, include_all);
    let cnt = n - first;

    var sum = 0.0;
    for (var i = first; i < n; i++) { sum += (*v)[i]; }
    let mean = sum / f32(cnt);
    var m2 = 0.0;
    for (var i = first; i < n; i++) { let d = (*v)[i] - mean; m2 += d * d; }
    let threshold = mean + outlier * sqrt(m2 / f32(cnt));

    var max_index = n;
    if (!include_all) {
        for (var z = first; z < n; z++) {
            if ((*v)[z] < threshold) { max_index = z; } else { break; }
        }
    }
    var idx = (min_index + max_index) / 2u;
    if (idx >= n) { idx = n - 1u; }
    if (idx < first) { idx = first; }
    return (*v)[idx];
}

fn aligned_component(x: u32, y: u32, c: u32) -> u32 {
    let n = P.count + 1u;
    let include_all = P.include_all != 0u;
    var v: array<f32, 17>;
    v[0] = f32(ld(0u, addr_of(step_of(0u), x, y, c)));
    var miss = 0u;
    for (var i = 0u; i < P.count; i++) {
        let t = warp_tap(i, i32(x), i32(y));
        if (t.covered) {
            v[i + 1u] = tap_value(i + 1u, t, c);
        } else {
            v[i + 1u] = 0.0;
            miss += 1u;
        }
    }
    let picked = sigma_clipped_median(&v, n, select(miss, 0u, include_all), include_all, P.outlier);
    return u32(clamp(picked, 0.0, MAXV));
}

// The standalone merge: `count + 1` same-shaped sources (0 is the base) and, unless include_all, the plane
// of per-pixel counts of how many of the FIRST misses[...] sources have no sample there (the CoverageMisses
// contract of medianMergeTyped, which is what stops black borders on edge frames).
fn median_component(x: u32, y: u32, c: u32) -> u32 {
    let n = P.count + 1u;
    let include_all = P.include_all != 0u;
    var v: array<f32, 17>;
    for (var i = 0u; i < n; i++) { v[i] = f32(ld(i, addr_of(step_of(i), x, y, c))); }
    var miss = 0u;
    if (!include_all && P.has_misses != 0u) {
        let a = y * P.miss_step + x;
        miss = (MISS[a >> 2u] >> ((a & 3u) * 8u)) & 0xffu;
    }
    let picked = sigma_clipped_median(&v, n, miss, include_all, P.outlier);
    return u32(clamp(picked, 0.0, MAXV));
}

fn warp_component(x: u32, y: u32, c: u32) -> u32 {
    let t = warp_tap(0u, i32(x), i32(y));
    if (!t.covered) { return 0u; }
    return u32(tap_value0(t, c));
}

// One thread per output WORD: `word` is the index inside the row, gid.y the row. Two copies, not one
// function with a flag: an entry point's auto-derived bind group layout holds every binding its call
// graph can reach, and a runtime flag would make the warp reach all 17 sources.
fn pack_word_aligned(word: u32, y: u32) -> u32 {
    let per_word = 4u / BPC;
    let total = P.width * P.channels;
    var out = 0u;
    for (var j = 0u; j < per_word; j++) {
        let k = word * per_word + j;
        if (k >= total) { break; }
        out |= aligned_component(k / P.channels, y, k % P.channels) << (j * 8u * BPC);
    }
    return out;
}

fn pack_word_median(word: u32, y: u32) -> u32 {
    let per_word = 4u / BPC;
    let total = P.width * P.channels;
    var out = 0u;
    for (var j = 0u; j < per_word; j++) {
        let k = word * per_word + j;
        if (k >= total) { break; }
        out |= median_component(k / P.channels, y, k % P.channels) << (j * 8u * BPC);
    }
    return out;
}

fn pack_word_warp(word: u32, y: u32) -> u32 {
    let per_word = 4u / BPC;
    let total = P.width * P.channels;
    var out = 0u;
    for (var j = 0u; j < per_word; j++) {
        let k = word * per_word + j;
        if (k >= total) { break; }
        out |= warp_component(k / P.channels, y, k % P.channels) << (j * 8u * BPC);
    }
    return out;
}

@compute @workgroup_size(8, 8)
fn aligned_main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= P.out_words_per_row || gid.y >= P.height) { return; }
    OUT[gid.y * P.out_words_per_row + gid.x] = pack_word_aligned(gid.x, gid.y);
}

@compute @workgroup_size(8, 8)
fn median_main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= P.out_words_per_row || gid.y >= P.height) { return; }
    OUT[gid.y * P.out_words_per_row + gid.x] = pack_word_median(gid.x, gid.y);
}

@compute @workgroup_size(8, 8)
fn warp_main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= P.out_words_per_row || gid.y >= P.height) { return; }
    OUT[gid.y * P.out_words_per_row + gid.x] = pack_word_warp(gid.x, gid.y);
}
)WGSL";
