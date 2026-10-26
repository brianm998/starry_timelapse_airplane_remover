// WGPUImageShaders.h — WGSL for the float-image operations the SIFT and AKAZE scale-space pyramids are
// built from (WGPUBackend.cpp). A port of the Metal kernels in StarCppBridge/GPUOps.swift
// (`upsample_linear_2x_f32`, `downsample_nearest_2x_f32`, `gaussian_row/column_f32`, `resize_area_f32`,
// `scharr_x/y_f32`, `pm_g2_f32`, `fed_step_f32`, `add_in_place_f32`).
//
// Images are tightly packed `array<f32>`, row-major, `width` floats a row: there are no textures here, so
// there is no format, tiling or texture-size limit to work around, only the storage-buffer binding size.
// Nothing in this file needs more than float32 or an ordering of operations: the pyramids are checked on
// behaviour (the keypoints they yield), not byte for byte, and a blur's weights are summed in the order
// OpenCV's separable filter sums them, which is all that matters to within float rounding.
//
// One bind group layout serves every entry point, and each entry point uses only the bindings it needs
// (the layout is derived from what it reaches): 0 parameters; 1 SRC, 2 DST, 3 AF (weights), 4 AI (area
// resize indices), 5 SRC2 (the second input of the two-input operations).
#pragma once

static const char *const kWgslImageSource = R"WGSL(
struct IP {
    w: u32, h: u32,          // the destination's size (and the size of an image updated in place)
    sw: u32, sh: u32,        // the source's size
    radius: i32,             // blur: half the kernel width
    replicate: u32,          // blur: BORDER_REPLICATE (AKAZE) rather than BORDER_REFLECT_101 (SIFT)
    yoff: u32,               // area resize: where the row tables start inside AF and AI
    pad0: u32,
    f0: f32, f1: f32, f2: f32, f3: f32,
};

@group(0) @binding(0) var<uniform> P: IP;
@group(0) @binding(1) var<storage, read> SRC: array<f32>;
@group(0) @binding(2) var<storage, read_write> DST: array<f32>;
@group(0) @binding(3) var<storage, read> AF: array<f32>;
@group(0) @binding(4) var<storage, read> AI: array<i32>;
@group(0) @binding(5) var<storage, read> SRC2: array<f32>;

// cv::BORDER_REFLECT_101, borderInterpolate's own loop: the repeat matters at the pyramid's last
// octaves, which are narrower than the kernel is wide.
fn reflect_101(p: i32, len: i32) -> i32 {
    if (len == 1) { return 0; }
    var q = p;
    while (q < 0 || q >= len) {
        q = select(2 * len - q - 2, -q, q < 0);
    }
    return q;
}

fn blur_border(p: i32, len: i32) -> i32 {
    return select(reflect_101(p, len), clamp(p, 0, len - 1), P.replicate != 0u);
}

fn at(x: u32, y: u32) -> u32 { return y * P.w + x; }

fn src_reflect(x: i32, y: i32) -> f32 {
    let xx = reflect_101(x, i32(P.w));
    let yy = reflect_101(y, i32(P.h));
    return SRC[u32(yy) * P.w + u32(xx)];
}

// Exact 2x nearest-neighbour downsample: buildGaussianPyramid's own INTER_NEAREST at an octave boundary.
@compute @workgroup_size(8, 8)
fn downsample_nearest_2x(@builtin(global_invocation_id) g: vec3<u32>) {
    if (g.x >= P.w || g.y >= P.h) { return; }
    DST[g.y * P.w + g.x] = SRC[(g.y * 2u) * P.sw + g.x * 2u];
}

// cv::resize(src, dst, 2x, INTER_LINEAR) for float: each destination pixel maps to (d + 0.5) / 2 - 0.5 in
// the source, and a sample that falls off either end takes the edge pixel with no blend.
fn linear_2x_tap(d: u32, len: u32) -> vec3<f32> {   // (s0, s1, f)
    let fx = (f32(d) + 0.5) * 0.5 - 0.5;
    var s = i32(floor(fx));
    var f = fx - f32(s);
    if (s < 0) { s = 0; f = 0.0; }
    if (s >= i32(len) - 1) { s = i32(len) - 1; f = 0.0; }
    return vec3<f32>(f32(s), f32(min(s + 1, i32(len) - 1)), f);
}

@compute @workgroup_size(8, 8)
fn upsample_linear_2x(@builtin(global_invocation_id) g: vec3<u32>) {
    if (g.x >= P.w || g.y >= P.h) { return; }
    let tx = linear_2x_tap(g.x, P.sw);
    let ty = linear_2x_tap(g.y, P.sh);
    let x0 = u32(tx.x); let x1 = u32(tx.y); let y0 = u32(ty.x); let y1 = u32(ty.y);
    let r0 = SRC[y0 * P.sw + x0] * (1.0 - tx.z) + SRC[y0 * P.sw + x1] * tx.z;
    let r1 = SRC[y1 * P.sw + x0] * (1.0 - tx.z) + SRC[y1 * P.sw + x1] * tx.z;
    DST[g.y * P.w + g.x] = r0 * (1.0 - ty.z) + r1 * ty.z;
}

// One pass of cv::GaussianBlur's separable filter; AF holds the 2r+1 weights cv::getGaussianKernel gives.
// Rows first, then columns, as sepFilter2D does.
@compute @workgroup_size(8, 8)
fn gauss_row(@builtin(global_invocation_id) g: vec3<u32>) {
    if (g.x >= P.w || g.y >= P.h) { return; }
    var sum = 0.0;
    for (var k = -P.radius; k <= P.radius; k++) {
        let x = blur_border(i32(g.x) + k, i32(P.w));
        sum += AF[u32(k + P.radius)] * SRC[g.y * P.w + u32(x)];
    }
    DST[g.y * P.w + g.x] = sum;
}

@compute @workgroup_size(8, 8)
fn gauss_col(@builtin(global_invocation_id) g: vec3<u32>) {
    if (g.x >= P.w || g.y >= P.h) { return; }
    var sum = 0.0;
    for (var k = -P.radius; k <= P.radius; k++) {
        let y = blur_border(i32(g.y) + k, i32(P.h));
        sum += AF[u32(k + P.radius)] * SRC[u32(y) * P.w + g.x];
    }
    DST[g.y * P.w + g.x] = sum;
}

// cv::resize(..., INTER_AREA) for a downscale, through computeResizeAreaTab's own tables (built on the CPU
// in double: AKAZE's levels are (int)(size / 2^octave) of the original, so an odd dimension makes the
// scale 2.0006 rather than 2 and the taps drift a source pixel across the frame; a 2x2 average cannot
// follow it). Each destination pixel sums up to four source columns in each of up to four source rows,
// columns first and then rows, as ResizeArea_Invoker does. AI/AF: the column tables at [x * 4 + i], the
// row tables at [yoff + y * 4 + j]; an index of -1 ends a list.
@compute @workgroup_size(8, 8)
fn resize_area(@builtin(global_invocation_id) g: vec3<u32>) {
    if (g.x >= P.w || g.y >= P.h) { return; }
    var sum = 0.0;
    for (var j = 0u; j < 4u; j++) {
        let sy = AI[P.yoff + g.y * 4u + j];
        if (sy < 0) { break; }
        var row = 0.0;
        for (var i = 0u; i < 4u; i++) {
            let sx = AI[g.x * 4u + i];
            if (sx < 0) { break; }
            row += SRC[u32(sy) * P.sw + u32(sx)] * AF[g.x * 4u + i];
        }
        sum += AF[P.yoff + g.y * 4u + j] * row;
    }
    DST[g.y * P.w + g.x] = sum;
}

// 3x3 Scharr, cv::Scharr(src, dst, CV_32F, 1, 0, 1, 0, BORDER_DEFAULT): Gx = [-3 0 3; -10 0 10; -3 0 3].
@compute @workgroup_size(8, 8)
fn scharr_x(@builtin(global_invocation_id) g: vec3<u32>) {
    if (g.x >= P.w || g.y >= P.h) { return; }
    let x = i32(g.x); let y = i32(g.y);
    DST[g.y * P.w + g.x] =
        -3.0 * src_reflect(x - 1, y - 1) + 3.0 * src_reflect(x + 1, y - 1)
        - 10.0 * src_reflect(x - 1, y) + 10.0 * src_reflect(x + 1, y)
        - 3.0 * src_reflect(x - 1, y + 1) + 3.0 * src_reflect(x + 1, y + 1);
}

// Gy = [-3 -10 -3; 0 0 0; 3 10 3].
@compute @workgroup_size(8, 8)
fn scharr_y(@builtin(global_invocation_id) g: vec3<u32>) {
    if (g.x >= P.w || g.y >= P.h) { return; }
    let x = i32(g.x); let y = i32(g.y);
    DST[g.y * P.w + g.x] =
        -3.0 * src_reflect(x - 1, y - 1) - 10.0 * src_reflect(x, y - 1) - 3.0 * src_reflect(x + 1, y - 1)
        + 3.0 * src_reflect(x - 1, y + 1) + 10.0 * src_reflect(x, y + 1) + 3.0 * src_reflect(x + 1, y + 1);
}

// Perona-Malik G2 diffusivity, pm_g2 in AKAZEDetector.cpp: 1 / (1 + (Lx^2 + Ly^2) / k^2). SRC = Lx,
// SRC2 = Ly, f0 = k.
@compute @workgroup_size(8, 8)
fn pm_g2(@builtin(global_invocation_id) g: vec3<u32>) {
    if (g.x >= P.w || g.y >= P.h) { return; }
    let i = g.y * P.w + g.x;
    let x = SRC[i]; let y = SRC2[i];
    DST[i] = 1.0 / (1.0 + (x * x + y * y) / (P.f0 * P.f0));
}

// One Fast Explicit Diffusion step, a direct port of nldStepScalar (AKAZEDetector.cpp): a five-point
// forward-Euler stencil with Neumann (no-flux) boundaries -- a border pixel omits the term reaching outside
// the image -- and AKAZE's literal four-corner special case (frozen at exactly 0, not a 2-term partial
// stencil). SRC = Lt, SRC2 = the flow (diffusivity), f0 = the step size, DST = Lstep.
@compute @workgroup_size(8, 8)
fn fed_step(@builtin(global_invocation_id) g: vec3<u32>) {
    let w = P.w; let h = P.h;
    if (g.x >= w || g.y >= h) { return; }
    let x = g.x; let y = g.y;
    let i = y * w + x;
    if ((y == 0u || y == h - 1u) && (x == 0u || x == w - 1u)) { DST[i] = 0.0; return; }
    let ltc = SRC[i]; let lfc = SRC2[i];
    var acc = 0.0;
    if (x < w - 1u) { acc += (lfc + SRC2[i + 1u]) * (SRC[i + 1u] - ltc); }
    if (x > 0u)     { acc += (lfc + SRC2[i - 1u]) * (SRC[i - 1u] - ltc); }
    if (y < h - 1u) { acc += (lfc + SRC2[i + w]) * (SRC[i + w] - ltc); }
    if (y > 0u)     { acc += (lfc + SRC2[i - w]) * (SRC[i - w] - ltc); }
    DST[i] = acc * P.f0;
}

// Elementwise Lt += Lstep, in place: DST is read and written, SRC is the step.
@compute @workgroup_size(8, 8)
fn add_in_place(@builtin(global_invocation_id) g: vec3<u32>) {
    if (g.x >= P.w || g.y >= P.h) { return; }
    let i = g.y * P.w + g.x;
    DST[i] = DST[i] + SRC[i];
}
)WGSL";
