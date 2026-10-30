// ExactWarp.hpp — cv::warpPerspective(src, dst, H, src.size(), INTER_LINEAR, BORDER_TRANSPARENT)
// for 16-bit one- and three-channel frames, byte for byte, without what OpenCV spends on the way.
//
// What the merge asks of OpenCV for every neighbour of every frame is this one call, and
// the profile of a run (plans/CORE_SPEED_PROPOSAL.md, section 1.4) puts a third to a half
// of the merge phase's CPU in it: OpenCV's 16-bit bilinear is the scalar `RemapNoVec` path,
// the coordinates are generated a 64x16 block at a time into a stack buffer that is then
// handed to a second, separately dispatched `remap`, a block's `Mat` headers and its
// dispatch allocate, and the caller then warps a solid 8-bit plane through the very same
// maps only to learn which pixels the first call touched.
//
// This does the same arithmetic in one pass and says which pixels it touched as it goes.
// It reproduces the vendored OpenCV 4.12.0 (imgproc/src/imgwarp.cpp) operation for
// operation, so the result is not close to OpenCV's, it is OpenCV's:
//
//  * `warpPerspective` inverts H (`cv::invert`, LU, as it does) and walks the destination
//    in blocks `bw0` wide from column 0.  Each row of a block starts from
//    `X0 = M0*x + M1*y + M2` (likewise Y0, W0) at the block's first column and adds
//    `M0*x1` for the pixel x1 columns in, so the coordinate of a pixel is not a function of
//    the pixel alone — rounding differs with where the block boundary falls — and the block
//    width has to be OpenCV's: min(1024 / min(16, rows), cols).  Rows do not matter: each
//    row starts from its own absolute y, which is what lets a row range be exact.
//  * Per pixel, in double and with no fused multiply-add (the SSE4.1 line generator that
//    runs on every x86-64 Mac and PC uses separate multiplies and adds, and so does the
//    scalar tail): W = W0 + M6*x1, W = W ? 32/W : 0, then (X0 + M0*x1)*W and (Y0 + M3*x1)*W
//    clamped to the int range and rounded to nearest-even.  The integer is a position in
//    32nds of a pixel: `X >> 5` is the column, `X & 31` the weight table's column index.
//  * Bilinear weights come from a 32x32 float table, w[k1*2+k2] = (1-fy | fy)[k1] *
//    (1-fx | fx)[k2], built the way OpenCV builds it, and a pixel is
//    `S[0]*w0 + S[1]*w1 + S[step]*w2 + S[step+1]*w3` summed left to right in float and
//    rounded to nearest-even into a ushort.
//  * A pixel whose column is in [0, w-2] and row in [0, h-2] is interpolated as above.  Any
//    other is left untouched (the destination keeps its zero) unless its column and row are
//    both inside the source (the last column or row, whose window is partly outside), in
//    which case it is interpolated from the corners that exist and rescaled by the ratio of
//    all four weights to those: BORDER_TRANSPARENT's own rule in this version.  A pixel
//    mapped to -1, or past the frame, is not touched however close it lands.
//
// "Touched" is exactly what warpCoverage reports: the 8-bit probe it warps is 255 wherever
// this writes and 0 wherever this does not, whichever branch produced the 255 (a partial
// window renormalises by the weights it summed and so returns the probe's 255 exactly, and
// the weights of the corners that exist cannot sum to zero at any of the 1024 positions).
//
// The same header also holds `remap` and the cloud stage's field remap, which reproduce
// `cv::remap(src, dst, mapx, mapy, INTER_LINEAR, BORDER_TRANSPARENT)` from float maps (see the
// section on them below).  They share the interpolation above and differ only in how the
// source positions are made.
//
// x86-64 only.  OpenCV's arm64 build generates the coordinates with fused multiply-adds
// (universal intrinsics' v_muladd is a NEON FMA there), which rounds differently from the
// separate multiply and add used here, so on arm64 `exactWarpApplies` is false and
// cv::warpPerspective runs as before.  That is also where the GPU merge is the default.
#pragma once

#include "CpuFeatures.hpp"

#include <opencv2/core.hpp>
#include <opencv2/core/utility.hpp>

#include <algorithm>
#include <atomic>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

#if defined(__x86_64__) || defined(_M_X64)
#define STAR_EXACT_WARP 1
#endif

#ifdef STAR_EXACT_WARP

namespace exactwarp {

constexpr int kInterBits = 5;
constexpr int kTabSize = 1 << kInterBits;

// OpenCV's BilinearTab_f, laid out [i * 32 + j][k1][k2] with i the row fraction and j the
// column fraction, in 32nds.
inline const float *bilinearTable() {
    static const std::vector<float> table = [] {
        std::vector<float> t((size_t)kTabSize * kTabSize * 4);
        float oneD[2 * kTabSize];
        const float scale = 1.f / kTabSize;
        for (int i = 0; i < kTabSize; ++i) {
            const float x = i * scale;
            oneD[2 * i] = 1.f - x;
            oneD[2 * i + 1] = x;
        }
        for (int i = 0; i < kTabSize; ++i)
            for (int j = 0; j < kTabSize; ++j)
                for (int k1 = 0; k1 < 2; ++k1) {
                    const float vy = oneD[i * 2 + k1];
                    for (int k2 = 0; k2 < 2; ++k2)
                        t[(((size_t)i * kTabSize + j) * 2 + k1) * 2 + k2] = vy * oneD[j * 2 + k2];
                }
        return t;
    }();
    return table.data();
}

// Whether the merge uses this at all.  `STAR_WARP=opencv` in the environment turns it off, for an
// A/B of a real run against cv::warpPerspective; `gDisabled` is the same for a test, which
// holds the two to each other in one process.  Read once.
inline std::atomic<int> gDisabled{0};
inline bool enabled() {
    static const bool allowed = [] {
        const char *env = std::getenv("STAR_WARP");
        return !(env && std::strcmp(env, "opencv") == 0);
    }();
    return allowed && gDisabled.load(std::memory_order_relaxed) == 0;
}

// The cloud stage's remap alone, for an A/B of that stage: `STAR_REMAP=opencv` keeps cv::remap
// there while the warp above stays exact.  (`STAR_WARP=opencv` turns both off.)
inline bool remapEnabled() {
    static const bool allowed = [] {
        const char *env = std::getenv("STAR_REMAP");
        return !(env && std::strcmp(env, "opencv") == 0);
    }();
    return allowed && enabled();
}

// Test hook: run the scalar rows even where AVX2 is available, so that a harness can hold
// each implementation to OpenCV's.
inline bool &forceScalarFlag() { static bool flag = false; return flag; }
inline bool forceScalar() { return forceScalarFlag(); }

// Whether `warp` reproduces cv::warpPerspective for these.
inline bool applies(const cv::Mat &src, const cv::Mat &H) {
    if (src.dims != 2 || src.rows <= 0 || src.cols <= 0 || src.depth() != CV_16U) return false;
    if (src.channels() != 1 && src.channels() != 3) return false;
    if (H.rows != 3 || H.cols != 3 || (H.type() != CV_64F && H.type() != CV_32F)) return false;
    for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 3; ++c) {
            const double v = H.depth() == CV_64F ? H.at<double>(r, c) : (double)H.at<float>(r, c);
            if (!std::isfinite(v)) return false;
        }
    return true;
}

// The block width cv::warpPerspective uses for a destination of this size.
inline int blockWidth(int rows, int cols) {
    const int blockSz = 32;
    const int bh0 = std::min(blockSz / 2, rows);
    return std::min(blockSz * blockSz / bh0, cols);
}

// The pixels of one block, `bw` of them from column `x` of the row `D` / `cov` point at, from
// their source positions in 32nds of a pixel: `xy` holds the column and row, `alpha` the index
// into the weight table.  This is `remapBilinear`, and what the warp and the remap have in
// common: they differ only in how the positions are made.
template <int CN, bool Pixels>
inline void interpolateBlock(const uint16_t *S0, size_t sstep, int sw, int sh,
                             uint16_t *D, uint8_t *cov, int x, int bw,
                             const short *xy, const unsigned short *alpha, const float *wtab)
{
#pragma clang fp contract(off)
    const unsigned width1 = sw > 1 ? (unsigned)(sw - 1) : 0u;
    const unsigned height1 = sh > 1 ? (unsigned)(sh - 1) : 0u;
    for (int x1 = 0; x1 < bw; ++x1) {
        const int sx = xy[x1 * 2], sy = xy[x1 * 2 + 1];
        const float *w = wtab + (size_t)alpha[x1] * 4;
        if ((unsigned)sx < width1 && (unsigned)sy < height1) {
            if constexpr (Pixels) {
                uint16_t *Dx = D + (size_t)(x + x1) * CN;
                const uint16_t *S = S0 + (size_t)sy * sstep + (size_t)sx * CN;
                for (int c = 0; c < CN; ++c) {
                    const float t = S[c] * w[0] + S[c + CN] * w[1] + S[sstep + c] * w[2] +
                                    S[sstep + c + CN] * w[3];
                    Dx[c] = cv::saturate_cast<uint16_t>(t);
                }
            }
            if (cov) cov[x + x1] = 255;
        } else if (sx >= 0 && sx <= sw - 1 && sy >= 0 && sy <= sh - 1) {
            // The last column or row: a window partly outside, from the corners in.
            float wTot = 0;
            if (sx >= 0 && sy >= 0) wTot += w[0];
            if (sy >= 0 && sx < sw - 1) wTot += w[1];
            if (sx >= 0 && sy < sh - 1) wTot += w[2];
            if (sx < sw - 1 && sy < sh - 1) wTot += w[3];
            if (wTot == 0.f) continue;
            if constexpr (Pixels) {
                uint16_t *Dx = D + (size_t)(x + x1) * CN;
                const float wTotIni = (float)w[0] + w[1] + w[2] + w[3];
                const uint16_t *S = S0 + (size_t)sy * sstep + (size_t)sx * CN;
                for (int c = 0; c < CN; ++c) {
                    float t0 = 0;
                    if (sx >= 0 && sy >= 0) t0 += S[c] * w[0];
                    if (sy >= 0 && sx < sw - 1) t0 += S[c + CN] * w[1];
                    if (sx >= 0 && sy < sh - 1) t0 += S[sstep + c] * w[2];
                    if (sx < sw - 1 && sy < sh - 1) t0 += S[sstep + c + CN] * w[3];
                    t0 = (float)(t0 * (float)wTotIni / wTot);
                    Dx[c] = cv::saturate_cast<uint16_t>(t0);
                }
            }
            if (cov) cov[x + x1] = 255;
        }
    }
}

// One destination row of `CN`-channel data.
template <int CN, bool Pixels>
inline void warpRow(const uint16_t *S0, size_t sstep, int sw, int sh,
                    uint16_t *D, uint8_t *cov, int width, int y,
                    const double *M, int bw0, const float *wtab)
{
    // The compiler may not fuse any of this: the arithmetic below is OpenCV's, which
    // rounds after every operation.
#pragma clang fp contract(off)
    short xy[2 * 1024];
    unsigned short alpha[1024];

    for (int x = 0; x < width; x += bw0) {
        const int bw = std::min(bw0, width - x);
        const double X0 = M[0] * x + M[1] * y + M[2];
        const double Y0 = M[3] * x + M[4] * y + M[5];
        const double W0 = M[6] * x + M[7] * y + M[8];

        for (int x1 = 0; x1 < bw; ++x1) {
            double W = W0 + M[6] * x1;
            W = W ? (double)kTabSize / W : 0;
            const double fX = std::max((double)INT_MIN, std::min((double)INT_MAX, (X0 + M[0] * x1) * W));
            const double fY = std::max((double)INT_MIN, std::min((double)INT_MAX, (Y0 + M[3] * x1) * W));
            const int X = cv::saturate_cast<int>(fX);
            const int Y = cv::saturate_cast<int>(fY);
            xy[x1 * 2] = cv::saturate_cast<short>(X >> kInterBits);
            xy[x1 * 2 + 1] = cv::saturate_cast<short>(Y >> kInterBits);
            alpha[x1] = (unsigned short)((Y & (kTabSize - 1)) * kTabSize + (X & (kTabSize - 1)));
        }

        interpolateBlock<CN, Pixels>(S0, sstep, sw, sh, D, cov, x, bw, xy, alpha, wtab);
    }
}


#ifdef STAR_X86_AVX2_KERNELS

// `interpolateBlock` with the three-channel pixel four floats at a time.  Every value is the
// one the scalar block computes, from the same operations in the same order: the vector lanes
// are independent channels, and none of the arithmetic is fused — AVX2 here means the wide
// registers, not FMA, which this target does not enable.
template <int CN, bool Pixels>
STAR_AVX2 inline void interpolateRangeAvx2(const uint16_t *S0, size_t sstep, int sw, int sh,
                                           uint16_t *D, uint8_t *cov, int x, int from, int to,
                                           const short *xy, const unsigned short *alpha,
                                           const float *wtab)
{
#pragma clang fp contract(off)
    const unsigned width1 = sw > 1 ? (unsigned)(sw - 1) : 0u;
    const unsigned height1 = sh > 1 ? (unsigned)(sh - 1) : 0u;
    for (int x1 = from; x1 < to; ++x1) {
        const int sx = xy[x1 * 2], sy = xy[x1 * 2 + 1];
        const float *w = wtab + (size_t)alpha[x1] * 4;
        if ((unsigned)sx < width1 && (unsigned)sy < height1) {
            if constexpr (Pixels) {
                uint16_t *Dx = D + (size_t)(x + x1) * CN;
                const uint16_t *S = S0 + (size_t)sy * sstep + (size_t)sx * CN;
                if constexpr (CN == 3) {
                    // The pixel pair of each of the two rows, six samples = 12 bytes, read as
                    // 8 + 4 so nothing past them is touched, then one float lane per channel:
                    // lanes 0-2 are the channels at x, lanes 0-2 of the second vector the
                    // channels at x + 1.  Lane 3 is whatever it is and is not stored.
                    auto taps = [](const uint16_t *p, __m128 &left, __m128 &right) {
                        int tail;
                        std::memcpy(&tail, p + 4, sizeof tail);
                        const __m128i six = _mm_unpacklo_epi64(_mm_loadl_epi64((const __m128i *)p),
                                                               _mm_cvtsi32_si128(tail));
                        left = _mm_cvtepi32_ps(_mm_cvtepu16_epi32(six));
                        right = _mm_cvtepi32_ps(_mm_cvtepu16_epi32(_mm_srli_si128(six, 6)));
                    };
                    __m128 a0, a1, b0, b1;
                    taps(S, a0, a1);
                    taps(S + sstep, b0, b1);
                    __m128 t = _mm_mul_ps(a0, _mm_load1_ps(w));
                    t = _mm_add_ps(t, _mm_mul_ps(a1, _mm_load1_ps(w + 1)));
                    t = _mm_add_ps(t, _mm_mul_ps(b0, _mm_load1_ps(w + 2)));
                    t = _mm_add_ps(t, _mm_mul_ps(b1, _mm_load1_ps(w + 3)));
                    const __m128i r = _mm_packus_epi32(_mm_cvtps_epi32(t), _mm_setzero_si128());
                    const int low = _mm_cvtsi128_si32(r);
                    std::memcpy(Dx, &low, sizeof low);
                    Dx[2] = (uint16_t)_mm_extract_epi16(r, 2);
                } else {
                    const float t = S[0] * w[0] + S[1] * w[1] + S[sstep] * w[2] + S[sstep + 1] * w[3];
                    Dx[0] = cv::saturate_cast<uint16_t>(t);
                }
            }
            if (cov) cov[x + x1] = 255;
        } else if (sx >= 0 && sx <= sw - 1 && sy >= 0 && sy <= sh - 1) {
            float wTot = 0;
            if (sx >= 0 && sy >= 0) wTot += w[0];
            if (sy >= 0 && sx < sw - 1) wTot += w[1];
            if (sx >= 0 && sy < sh - 1) wTot += w[2];
            if (sx < sw - 1 && sy < sh - 1) wTot += w[3];
            if (wTot == 0.f) continue;
            if constexpr (Pixels) {
                uint16_t *Dx = D + (size_t)(x + x1) * CN;
                const float wTotIni = (float)w[0] + w[1] + w[2] + w[3];
                const uint16_t *S = S0 + (size_t)sy * sstep + (size_t)sx * CN;
                for (int c = 0; c < CN; ++c) {
                    float t0 = 0;
                    if (sx >= 0 && sy >= 0) t0 += S[c] * w[0];
                    if (sy >= 0 && sx < sw - 1) t0 += S[c + CN] * w[1];
                    if (sx >= 0 && sy < sh - 1) t0 += S[sstep + c] * w[2];
                    if (sx < sw - 1 && sy < sh - 1) t0 += S[sstep + c + CN] * w[3];
                    t0 = (float)(t0 * (float)wTotIni / wTot);
                    Dx[c] = cv::saturate_cast<uint16_t>(t0);
                }
            }
            if (cov) cov[x + x1] = 255;
        }
    }
}

// The weights as the three-channel AVX2 pixel wants them, per weight-table index: eight floats
// {w0,w0,w0,w1,w1,w1,0,0} (the two columns of the upper source row, one lane per channel) and
// eight {w2,w2,w2,w3,w3,w3,0,0} (the lower).  The same four floats `bilinearTable` holds.
inline const float *bilinearTable3() {
    static const std::vector<float> table = [] {
        const float *t = bilinearTable();
        std::vector<float> v((size_t)kTabSize * kTabSize * 16, 0.f);
        for (size_t i = 0; i < (size_t)kTabSize * kTabSize; ++i) {
            const float *w = t + i * 4;
            float *o = v.data() + i * 16;
            for (int c = 0; c < 3; ++c) { o[c] = w[0]; o[3 + c] = w[1]; o[8 + c] = w[2]; o[11 + c] = w[3]; }
        }
        return v;
    }();
    return table.data();
}

// A block of pixels, eight at a time where all eight are interior (and of a three-channel
// frame): what `interpolateRangeAvx2` does for each, with the integer work done for the eight
// in registers and a pixel's six samples of each row taken by one 16-byte load.
//
//  * The load reads 4 bytes past the pixel pair, so a pixel qualifies only if its lower row is
//    not the frame's last (`sy < sh - 2`): the 4 bytes are then in the next row.
//  * The products are the ones the scalar sum forms, `S0*w0`, `S1*w1`, `S2*w2`, `S3*w3`, each
//    rounded once; the sum is the same left to right, ((p0 + p1) + p2) + p3, with p1 and p3 moved
//    from lanes 3-5 to lanes 0-2 first.  Nothing is fused.
// Blocks with any pixel outside that, and the tail, go through the per-pixel code.
template <int CN, bool Pixels>
STAR_AVX2 inline void interpolateBlockAvx2(const uint16_t *S0, size_t sstep, int sw, int sh,
                                           uint16_t *D, uint8_t *cov, int x, int bw,
                                           const short *xy, const unsigned short *alpha,
                                           const float *wtab)
{
#pragma clang fp contract(off)
    int x1 = 0;
    if constexpr (CN == 3 && Pixels) {
        if (sw > 1 && sh > 2 && (double)sstep * (double)sh < 2.0e9) {
            const float *wtab3 = bilinearTable3();
            const __m256i vW1 = _mm256_set1_epi32(sw - 1), vH2 = _mm256_set1_epi32(sh - 2);
            const __m256i vMinus1 = _mm256_set1_epi32(-1), vStep = _mm256_set1_epi32((int)sstep);
            const __m256i vThree = _mm256_set1_epi32(3);
            const __m256i shiftDown = _mm256_setr_epi32(3, 4, 5, 6, 7, 7, 7, 7);
            for (; x1 + 8 <= bw; x1 += 8) {
                const __m256i p = _mm256_loadu_si256((const __m256i *)(xy + 2 * x1));
                const __m256i sx = _mm256_srai_epi32(_mm256_slli_epi32(p, 16), 16);
                const __m256i sy = _mm256_srai_epi32(p, 16);
                const __m256i inside = _mm256_and_si256(
                    _mm256_and_si256(_mm256_cmpgt_epi32(sx, vMinus1), _mm256_cmpgt_epi32(vW1, sx)),
                    _mm256_and_si256(_mm256_cmpgt_epi32(sy, vMinus1), _mm256_cmpgt_epi32(vH2, sy)));
                if (_mm256_movemask_epi8(inside) != -1) {
                    interpolateRangeAvx2<CN, Pixels>(S0, sstep, sw, sh, D, cov, x, x1, x1 + 8, xy, alpha, wtab);
                    continue;
                }
                alignas(32) int offs[8], widx[8];
                _mm256_store_si256((__m256i *)offs, _mm256_add_epi32(_mm256_mullo_epi32(sy, vStep),
                                                                      _mm256_mullo_epi32(sx, vThree)));
                _mm256_store_si256((__m256i *)widx, _mm256_slli_epi32(
                    _mm256_cvtepu16_epi32(_mm_loadu_si128((const __m128i *)(alpha + x1))), 4));
                uint16_t *Dx = D + (size_t)(x + x1) * 3;
                for (int k = 0; k < 8; ++k, Dx += 3) {
                    const uint16_t *S = S0 + offs[k];
                    const float *w = wtab3 + widx[k];
                    const __m256 rowA = _mm256_cvtepi32_ps(_mm256_cvtepu16_epi32(_mm_loadu_si128((const __m128i *)S)));
                    const __m256 rowB = _mm256_cvtepi32_ps(_mm256_cvtepu16_epi32(_mm_loadu_si128((const __m128i *)(S + sstep))));
                    const __m256 top = _mm256_mul_ps(rowA, _mm256_loadu_ps(w));
                    const __m256 bottom = _mm256_mul_ps(rowB, _mm256_loadu_ps(w + 8));
                    __m128 t = _mm_add_ps(_mm256_castps256_ps128(top),
                                          _mm256_castps256_ps128(_mm256_permutevar8x32_ps(top, shiftDown)));
                    t = _mm_add_ps(t, _mm256_castps256_ps128(bottom));
                    t = _mm_add_ps(t, _mm256_castps256_ps128(_mm256_permutevar8x32_ps(bottom, shiftDown)));
                    const __m128i r = _mm_packus_epi32(_mm_cvtps_epi32(t), _mm_setzero_si128());
                    const int low = _mm_cvtsi128_si32(r);
                    std::memcpy(Dx, &low, sizeof low);
                    Dx[2] = (uint16_t)_mm_extract_epi16(r, 2);
                }
                if (cov) _mm_storel_epi64((__m128i *)(cov + x + x1), _mm_set1_epi8(-1));
            }
        }
    }
    interpolateRangeAvx2<CN, Pixels>(S0, sstep, sw, sh, D, cov, x, x1, bw, xy, alpha, wtab);
}

// The same row as `warpRow`, with the coordinates four pixels at a time in AVX2 doubles.
template <int CN, bool Pixels>
STAR_AVX2 inline void warpRowAvx2(const uint16_t *S0, size_t sstep, int sw, int sh,
                                  uint16_t *D, uint8_t *cov, int width, int y,
                                  const double *M, int bw0, const float *wtab)
{
#pragma clang fp contract(off)
    alignas(32) short xy[2 * 1024];
    alignas(32) unsigned short alpha[1024];

    const __m256d vM0 = _mm256_set1_pd(M[0]), vM3 = _mm256_set1_pd(M[3]), vM6 = _mm256_set1_pd(M[6]);
    const __m256d vMax = _mm256_set1_pd((double)INT_MAX), vMin = _mm256_set1_pd((double)INT_MIN);
    const __m256d vTab = _mm256_set1_pd((double)kTabSize), vZero = _mm256_setzero_pd();
    const __m256d vFour = _mm256_set1_pd(4.0);
    const __m128i vLow5 = _mm_set1_epi32(kTabSize - 1);

    for (int x = 0; x < width; x += bw0) {
        const int bw = std::min(bw0, width - x);
        const double X0 = M[0] * x + M[1] * y + M[2];
        const double Y0 = M[3] * x + M[4] * y + M[5];
        const double W0 = M[6] * x + M[7] * y + M[8];

        const __m256d vX0 = _mm256_set1_pd(X0), vY0 = _mm256_set1_pd(Y0), vW0 = _mm256_set1_pd(W0);
        __m256d vx1 = _mm256_set_pd(3, 2, 1, 0);
        int x1 = 0;
        for (; x1 + 4 <= bw; x1 += 4) {
            __m256d W = _mm256_add_pd(_mm256_mul_pd(vM6, vx1), vW0);
            W = _mm256_andnot_pd(_mm256_cmp_pd(W, vZero, _CMP_EQ_OQ), _mm256_div_pd(vTab, W));
            const __m256d fX = _mm256_max_pd(vMin, _mm256_min_pd(vMax,
                _mm256_mul_pd(_mm256_add_pd(vX0, _mm256_mul_pd(vM0, vx1)), W)));
            const __m256d fY = _mm256_max_pd(vMin, _mm256_min_pd(vMax,
                _mm256_mul_pd(_mm256_add_pd(vY0, _mm256_mul_pd(vM3, vx1)), W)));
            const __m128i X = _mm256_cvtpd_epi32(fX), Y = _mm256_cvtpd_epi32(fY);
            const __m128i sx16 = _mm_packs_epi32(_mm_srai_epi32(X, kInterBits), _mm_setzero_si128());
            const __m128i sy16 = _mm_packs_epi32(_mm_srai_epi32(Y, kInterBits), _mm_setzero_si128());
            _mm_store_si128((__m128i *)(xy + 2 * x1), _mm_unpacklo_epi16(sx16, sy16));
            const __m128i a = _mm_add_epi32(_mm_slli_epi32(_mm_and_si128(Y, vLow5), kInterBits),
                                            _mm_and_si128(X, vLow5));
            _mm_storel_epi64((__m128i *)(alpha + x1), _mm_packus_epi32(a, a));
            vx1 = _mm256_add_pd(vx1, vFour);
        }
        for (; x1 < bw; ++x1) {
            double W = W0 + M[6] * x1;
            W = W ? (double)kTabSize / W : 0;
            const double fX = std::max((double)INT_MIN, std::min((double)INT_MAX, (X0 + M[0] * x1) * W));
            const double fY = std::max((double)INT_MIN, std::min((double)INT_MAX, (Y0 + M[3] * x1) * W));
            const int Xi = cv::saturate_cast<int>(fX);
            const int Yi = cv::saturate_cast<int>(fY);
            xy[x1 * 2] = cv::saturate_cast<short>(Xi >> kInterBits);
            xy[x1 * 2 + 1] = cv::saturate_cast<short>(Yi >> kInterBits);
            alpha[x1] = (unsigned short)((Yi & (kTabSize - 1)) * kTabSize + (Xi & (kTabSize - 1)));
        }

        interpolateBlockAvx2<CN, Pixels>(S0, sstep, sw, sh, D, cov, x, bw, xy, alpha, wtab);
    }
}

#endif  // STAR_X86_AVX2_KERNELS

// Warp `src` by `H` into `dst` (same size and type as `src`, already zero) over the
// destination rows [yStart, yEnd), and mark the pixels written in `covered` (CV_8UC1, same
// size, already zero) when it is given.  `M` is H's inverse as cv::warpPerspective forms it.
// The source is described by its pixels, step (in elements), size and channel count rather
// than by a Mat so that the coverage-only pass, which reads none, can have none.
struct Source {
    const uint16_t *data;
    size_t step;
    int cols, rows, channels;
};

// Rows [yStart, yEnd) of the destination.  `dst` and `covered` hold the whole destination, or, with
// `rowOffset` = yStart, only these rows (their row 0 is destination row `rowOffset`): the
// coordinates of a row depend on its own y alone, so a band is exactly the rows of the whole.
template <bool Pixels>
inline void warpRows(const Source &src, cv::Mat *dst, cv::Mat *covered, const double *M,
                     int yStart, int yEnd, int cols, int rows, int rowOffset = 0)
{
    const int cn = src.channels;
    const int width = cols;
    const int bw0 = blockWidth(rows, cols);
    const float *wtab = bilinearTable();
    const size_t sstep = src.step;
    const uint16_t *S0 = src.data;
#ifdef STAR_X86_AVX2_KERNELS
    const bool avx2 = cpuRunsAvx2() && !forceScalar();
#else
    const bool avx2 = false;
#endif
    for (int y = yStart; y < yEnd; ++y) {
        uint16_t *D = Pixels ? dst->ptr<uint16_t>(y - rowOffset) : nullptr;
        uint8_t *cov = covered ? covered->ptr<uint8_t>(y - rowOffset) : nullptr;
#ifdef STAR_X86_AVX2_KERNELS
        if (avx2) {
            if (cn == 1)
                warpRowAvx2<1, Pixels>(S0, sstep, src.cols, src.rows, D, cov, width, y, M, bw0, wtab);
            else
                warpRowAvx2<3, Pixels>(S0, sstep, src.cols, src.rows, D, cov, width, y, M, bw0, wtab);
            continue;
        }
#endif
        (void)avx2;
        if (cn == 1)
            warpRow<1, Pixels>(S0, sstep, src.cols, src.rows, D, cov, width, y, M, bw0, wtab);
        else
            warpRow<3, Pixels>(S0, sstep, src.cols, src.rows, D, cov, width, y, M, bw0, wtab);
    }
}

// cv::warpPerspective(src, dst, H, src.size(), INTER_LINEAR, BORDER_TRANSPARENT) for a
// zero-initialised `dst` of src's size and type, optionally with the touched set in
// `covered`.  Requires `applies(src, H)`.
inline void warp(const cv::Mat &src, const cv::Mat &H, cv::Mat &dst, cv::Mat *covered) {
    double M[9];
    cv::Mat matM(3, 3, CV_64F, M);
    H.convertTo(matM, matM.type());
    cv::invert(matM, matM);

    const Source source{src.ptr<uint16_t>(), src.step / sizeof(uint16_t), src.cols, src.rows,
                        src.channels()};
    const double stripes = (double)dst.total() / (double)(1 << 16);
    cv::parallel_for_(cv::Range(0, dst.rows), [&](const cv::Range &r) {
        warpRows<true>(source, &dst, covered, M, r.start, r.end, dst.cols, dst.rows);
    }, stripes);
}

// The rows [yStart, yEnd) of `warp(src, H, ...)`, into a `dst` of just those rows (and `covered`
// likewise), each byte what the whole warp gives that row.  `src` is the whole frame, which is
// also the destination's size.  Requires `applies(src, H)`.
inline void warpBand(const cv::Mat &src, const cv::Mat &H, cv::Mat &dst, cv::Mat *covered,
                     int yStart, int yEnd)
{
    double M[9];
    cv::Mat matM(3, 3, CV_64F, M);
    H.convertTo(matM, matM.type());
    cv::invert(matM, matM);

    const Source source{src.ptr<uint16_t>(), src.step / sizeof(uint16_t), src.cols, src.rows,
                        src.channels()};
    const double stripes = (double)dst.total() / (double)(1 << 16);
    cv::parallel_for_(cv::Range(yStart, yEnd), [&](const cv::Range &r) {
        warpRows<true>(source, &dst, covered, M, r.start, r.end, src.cols, src.rows, yStart);
    }, stripes);
}

// Whether `coverage` reproduces warpCoverage's CPU result for a probe of this size.
inline bool coverageApplies(cv::Size size, const cv::Mat &H) {
    if (size.width <= 0 || size.height <= 0) return false;
    return applies(cv::Mat(1, 1, CV_16UC1), H);   // the same tests on H
}

// The 8-bit plane `warpCoverage` returns on the CPU: 255 where a warp of a frame of this size
// by `H` writes a pixel and 0 where it does not.  The coordinates alone decide that, so the
// frame's pixels are never read — a pass over the maps instead of a second warp.
inline cv::Mat coverage(cv::Size size, const cv::Mat &H) {
    double M[9];
    cv::Mat matM(3, 3, CV_64F, M);
    H.convertTo(matM, matM.type());
    cv::invert(matM, matM);

    cv::Mat covered = cv::Mat::zeros(size, CV_8UC1);
    const Source source{nullptr, 0, size.width, size.height, 1};
    const double stripes = (double)covered.total() / (double)(1 << 16);
    cv::parallel_for_(cv::Range(0, covered.rows), [&](const cv::Range &r) {
        warpRows<false>(source, nullptr, &covered, M, r.start, r.end, covered.cols, covered.rows);
    }, stripes);
    return covered;
}

// --- cv::remap with float maps -------------------------------------------------------------
//
// The cloud-aware stage samples each neighbour at a position it computes per pixel (the star
// homography and a displacement field, see `DisplacementField`) and hands OpenCV two float
// planes, `cv::remap(src, dst, mapx, mapy, INTER_LINEAR, BORDER_TRANSPARENT)`, then does it
// again on a solid 8-bit probe to learn which pixels were written.  `RemapInvoker` turns the
// planes into the same (column, row, weight index) triples the warp does, by
// `cvRound(f * 32)` per coordinate, and runs the same `remapBilinear` over them — so the
// interpolation above is shared, and what is new here is the rounding of the coordinates:
//
//     X = cvRound(mapx * 32), Y = cvRound(mapy * 32)
//     column = saturate_cast<short>(X >> 5), row = saturate_cast<short>(Y >> 5)
//     weight index = (Y & 31) * 32 + (X & 31)
//
// A pixel's result depends on its own two floats and nothing else (unlike the warp, whose
// block structure shows in its coordinates), so any partition of the destination is exact.

// One chunk's positions from its maps.  `mx` and `my` are `n` floats each.
inline void quantiseScalar(const float *mx, const float *my, int n, short *xy, unsigned short *alpha) {
    for (int i = 0; i < n; ++i) {
        const int sx = cvRound(mx[i] * static_cast<float>(kTabSize));
        const int sy = cvRound(my[i] * static_cast<float>(kTabSize));
        xy[i * 2] = cv::saturate_cast<short>(sx >> kInterBits);
        xy[i * 2 + 1] = cv::saturate_cast<short>(sy >> kInterBits);
        alpha[i] = (unsigned short)((sy & (kTabSize - 1)) * kTabSize + (sx & (kTabSize - 1)));
    }
}

#ifdef STAR_X86_AVX2_KERNELS
// Eight at a time: `cvtps` rounds to nearest-even like `cvRound`, and a multiplication by 32
// is exact, so the integers are the scalar ones.  Anything the conversion cannot represent
// (NaN, beyond the int range) comes out as the indefinite integer in both.
STAR_AVX2 inline void quantiseAvx2(const float *mx, const float *my, int n, short *xy, unsigned short *alpha) {
    const __m256 v32 = _mm256_set1_ps((float)kTabSize);
    const __m256i low5 = _mm256_set1_epi32(kTabSize - 1);
    int i = 0;
    for (; i + 8 <= n; i += 8) {
        const __m256i sx = _mm256_cvtps_epi32(_mm256_mul_ps(v32, _mm256_loadu_ps(mx + i)));
        const __m256i sy = _mm256_cvtps_epi32(_mm256_mul_ps(v32, _mm256_loadu_ps(my + i)));
        const __m256i a = _mm256_add_epi32(_mm256_slli_epi32(_mm256_and_si256(sy, low5), kInterBits),
                                           _mm256_and_si256(sx, low5));
        _mm_storeu_si128((__m128i *)(alpha + i),
                         _mm_packus_epi32(_mm256_castsi256_si128(a), _mm256_extracti128_si256(a, 1)));
        const __m256i xs = _mm256_srai_epi32(sx, kInterBits), ys = _mm256_srai_epi32(sy, kInterBits);
        const __m128i x16 = _mm_packs_epi32(_mm256_castsi256_si128(xs), _mm256_extracti128_si256(xs, 1));
        const __m128i y16 = _mm_packs_epi32(_mm256_castsi256_si128(ys), _mm256_extracti128_si256(ys, 1));
        _mm_storeu_si128((__m128i *)(xy + 2 * i), _mm_unpacklo_epi16(x16, y16));
        _mm_storeu_si128((__m128i *)(xy + 2 * i + 8), _mm_unpackhi_epi16(x16, y16));
    }
    quantiseScalar(mx + i, my + i, n - i, xy + 2 * i, alpha + i);
}
#endif  // STAR_X86_AVX2_KERNELS

// Pixels per chunk: the maps for this many are made, rounded and interpolated while they are
// still in cache.
constexpr int kChunk = 1024;

// One destination row.  `maps(x, n, bufX, bufY, mx, my)` supplies the float maps of the `n`
// pixels from column `x` as `mx` / `my`, either pointing at maps that exist or into `bufX` /
// `bufY` (room for a chunk) after filling them.
template <int CN, bool Pixels, class Maps>
inline void remapRow(const Source &src, uint16_t *D, uint8_t *cov, int width, const float *wtab,
                     bool avx2, Maps &&maps)
{
    alignas(32) short xy[2 * kChunk];
    alignas(32) unsigned short alpha[kChunk];
    alignas(32) float bufX[kChunk], bufY[kChunk];
    for (int x = 0; x < width; x += kChunk) {
        const int n = std::min(kChunk, width - x);
        const float *mx = nullptr, *my = nullptr;
        maps(x, n, bufX, bufY, mx, my);
#ifdef STAR_X86_AVX2_KERNELS
        if (avx2) {
            quantiseAvx2(mx, my, n, xy, alpha);
            interpolateBlockAvx2<CN, Pixels>(src.data, src.step, src.cols, src.rows, D, cov, x, n,
                                             xy, alpha, wtab);
            continue;
        }
#endif
        (void)avx2;
        quantiseScalar(mx, my, n, xy, alpha);
        interpolateBlock<CN, Pixels>(src.data, src.step, src.cols, src.rows, D, cov, x, n, xy, alpha, wtab);
    }
}

// Whether `remap` / `remapField` reproduce cv::remap for this source and a destination of
// this size: the sizes OpenCV accepts, and the depth and channel counts that have a loop here.
inline bool remapApplies(const cv::Mat &src, cv::Size dsize) {
    if (src.dims != 2 || src.empty() || src.depth() != CV_16U) return false;
    if (src.channels() != 1 && src.channels() != 3) return false;
    return dsize.width > 0 && dsize.height > 0 && dsize.width < SHRT_MAX && dsize.height < SHRT_MAX
        && src.cols < SHRT_MAX && src.rows < SHRT_MAX;
}

inline bool useAvx2Rows() {
#ifdef STAR_X86_AVX2_KERNELS
    return cpuRunsAvx2() && !forceScalar();
#else
    return false;
#endif
}

// Rows [r.start, r.end) of the destination from `maps`, which fills in a chunk of row `y`.
template <class MapsFor>
inline void remapRows(const Source &src, cv::Mat &dst, cv::Mat *covered, int width, const cv::Range &r,
                      MapsFor &&mapsFor)
{
    const float *wtab = bilinearTable();
    const bool avx2 = useAvx2Rows();
    for (int y = r.start; y < r.end; ++y) {
        uint16_t *D = dst.empty() ? nullptr : dst.ptr<uint16_t>(y);
        uint8_t *cov = covered ? covered->ptr<uint8_t>(y) : nullptr;
        auto maps = mapsFor(y);
        if (src.channels == 1) {
            if (D) remapRow<1, true>(src, D, cov, width, wtab, avx2, maps);
            else remapRow<1, false>(src, D, cov, width, wtab, avx2, maps);
        } else {
            if (D) remapRow<3, true>(src, D, cov, width, wtab, avx2, maps);
            else remapRow<3, false>(src, D, cov, width, wtab, avx2, maps);
        }
    }
}

inline Source sourceOf(const cv::Mat &src) {
    return Source{src.ptr<uint16_t>(), src.step / sizeof(uint16_t), src.cols, src.rows, src.channels()};
}

// cv::remap(src, dst, mapx, mapy, INTER_LINEAR, BORDER_TRANSPARENT) for CV_32FC1 maps, into a
// zero-initialised `dst` of the maps' size and src's type, optionally with the pixels written
// marked 255 in `covered` (CV_8UC1, same size, zero) — what a remap of an all-255 8-bit
// probe through the same maps gives.  Requires `remapApplies(src, mapx.size())`.
inline void remap(const cv::Mat &src, const cv::Mat &mapx, const cv::Mat &mapy, cv::Mat &dst,
                  cv::Mat *covered)
{
    const Source source = sourceOf(src);
    const double stripes = (double)dst.total() / (double)(1 << 16);
    cv::parallel_for_(cv::Range(0, dst.rows), [&](const cv::Range &r) {
        remapRows(source, dst, covered, dst.cols, r, [&](int y) {
            const float *px = mapx.ptr<float>(y), *py = mapy.ptr<float>(y);
            return [px, py](int x, int, float *, float *, const float *&mx, const float *&my) {
                mx = px + x;
                my = py + x;
            };
        });
    }, stripes);
}

// --- the cloud stage's maps ------------------------------------------------------------------
//
// Where, in the neighbour's original frame, a pixel of the cloud stage's region looks: the
// star homography's inverse applied to the pixel displaced by the cloud field.
//
//     d      = bilinear interpolation of the per-tile (dy, dx) grid at the pixel, times `scale`
//     (qx,qy) = (originX + x, originY + y) + d
//     w      = hi[6]*qx + hi[7]*qy + hi[8]
//     mapx   = (hi[0]*qx + hi[1]*qy + hi[2]) / w,   mapy = (hi[3]*qx + hi[4]*qy + hi[5]) / w
//     (-1e6, -1e6 where |w| < 1e-12)
//
// with the interpolation in float and the homography in double, each operation rounded and
// none fused, as the stage computed them before.  These make the same floats, a row at a time
// into a chunk buffer, so `remapRow` can round and interpolate them without a pair of
// region-sized planes in between; the AVX2 form does eight pixels at a time.
//
// A fused multiply-add anywhere here would change a coordinate in its last bit and, once in a
// while, which 32nd of a pixel it rounds to; the stage's own scalar code is compiled without
// one on x86-64, and a build that enabled FMA would have it fused there and not here, so this
// is not offered then.
#if !defined(__FMA__)
#define STAR_EXACT_FIELD 1

struct DisplacementField {
    int nx = 0, ny = 0;                  // grid size
    const float *v[2] = {nullptr, nullptr};   // per tile, row-major ny x nx: dy then dx
    const int *colIdx = nullptr;         // per region column: the grid cell, and the weight of the next
    const float *colT = nullptr;
    const int *rowIdx = nullptr;         // the same per region row
    const float *rowT = nullptr;
    int originX = 0, originY = 0;        // the region's top left in the frame
    float scale = 1.f;                   // grid units to pixels
    double hi[9] = {};                   // the star homography's inverse, row-major
};

// The grid's two components blended vertically at region row `y`: for each grid column, the
// float `v(iy, j) * (1 - ty) + v(iy2, j) * ty` that every pixel of the row in that cell reads.
inline void fieldRowBlend(const DisplacementField &f, int y, float *rowA0, float *rowA1) {
#pragma clang fp contract(off)
    const int iy = f.rowIdx[y], iy2 = std::min(iy + 1, f.ny - 1);
    const float ty = f.rowT[y];
    float *out[2] = {rowA0, rowA1};
    for (int c = 0; c < 2; ++c) {
        const float *a = f.v[c] + (size_t)iy * f.nx, *b = f.v[c] + (size_t)iy2 * f.nx;
        for (int j = 0; j < f.nx; ++j) out[c][j] = a[j] * (1.f - ty) + b[j] * ty;
    }
}

// One pixel's map, exactly as the stage's lambda wrote it.
inline void fieldMapOne(const DisplacementField &f, const float *rowA0, const float *rowA1, int y,
                        int x, float &mx, float &my)
{
#pragma clang fp contract(off)
    const int jx = f.colIdx[x], jx2 = std::min(jx + 1, f.nx - 1);
    const float tx = f.colT[x];
    const float dy = (rowA0[jx] * (1.f - tx) + rowA0[jx2] * tx) * f.scale;
    const float dx = (rowA1[jx] * (1.f - tx) + rowA1[jx2] * tx) * f.scale;
    const double qx = (double)(f.originX + x) + (double)dx;
    const double qy = (double)(f.originY + y) + (double)dy;
    const double wd = f.hi[6] * qx + f.hi[7] * qy + f.hi[8];
    if (std::fabs(wd) < 1e-12) { mx = -1e6f; my = -1e6f; return; }
    mx = (float)((f.hi[0] * qx + f.hi[1] * qy + f.hi[2]) / wd);
    my = (float)((f.hi[3] * qx + f.hi[4] * qy + f.hi[5]) / wd);
}

inline void fieldMapsScalar(const DisplacementField &f, const float *rowA0, const float *rowA1, int y,
                            int x0, int n, float *mx, float *my)
{
    for (int i = 0; i < n; ++i) fieldMapOne(f, rowA0, rowA1, y, x0 + i, mx[i], my[i]);
}

#ifdef STAR_X86_AVX2_KERNELS
STAR_AVX2 inline void fieldMapsAvx2(const DisplacementField &f, const float *rowA0, const float *rowA1,
                                    int y, int x0, int n, float *mx, float *my)
{
#pragma clang fp contract(off)
    const __m256 one = _mm256_set1_ps(1.f), scale = _mm256_set1_ps(f.scale);
    const __m256d h0 = _mm256_set1_pd(f.hi[0]), h1 = _mm256_set1_pd(f.hi[1]), h2 = _mm256_set1_pd(f.hi[2]);
    const __m256d h3 = _mm256_set1_pd(f.hi[3]), h4 = _mm256_set1_pd(f.hi[4]), h5 = _mm256_set1_pd(f.hi[5]);
    const __m256d h6 = _mm256_set1_pd(f.hi[6]), h7 = _mm256_set1_pd(f.hi[7]), h8 = _mm256_set1_pd(f.hi[8]);
    const __m256d qyBase = _mm256_set1_pd((double)(f.originY + y));
    const __m256d tiny = _mm256_set1_pd(1e-12), sign = _mm256_set1_pd(-0.0), fallback = _mm256_set1_pd(-1e6);
    const __m128i iota = _mm_setr_epi32(0, 1, 2, 3);

    int i = 0;
    for (; i + 8 <= n; i += 8) {
        const int x = x0 + i;
        // A grid cell is hundreds of pixels wide, so nearly every eight share one and the
        // two values they blend are broadcasts.  (A gather would do for the rest and costs
        // more than twice the rest of this loop on the Xeon W-2191B it was measured on.)  The few
        // eights that straddle a boundary are made one pixel at a time.
        const int cell = f.colIdx[x];
        if (_mm256_movemask_epi8(_mm256_cmpeq_epi32(_mm256_loadu_si256((const __m256i *)(f.colIdx + x)),
                                                    _mm256_set1_epi32(cell))) != -1) {
            for (int k = 0; k < 8; ++k) fieldMapOne(f, rowA0, rowA1, y, x + k, mx[i + k], my[i + k]);
            continue;
        }
        const int next = std::min(cell + 1, f.nx - 1);
        const __m256 tx = _mm256_loadu_ps(f.colT + x);
        const __m256 omt = _mm256_sub_ps(one, tx);
        const __m256 dy = _mm256_mul_ps(_mm256_add_ps(_mm256_mul_ps(_mm256_set1_ps(rowA0[cell]), omt),
                                                      _mm256_mul_ps(_mm256_set1_ps(rowA0[next]), tx)), scale);
        const __m256 dx = _mm256_mul_ps(_mm256_add_ps(_mm256_mul_ps(_mm256_set1_ps(rowA1[cell]), omt),
                                                      _mm256_mul_ps(_mm256_set1_ps(rowA1[next]), tx)), scale);
        __m128 outX[2], outY[2];
        for (int h = 0; h < 2; ++h) {
            const __m128 dxh = h ? _mm256_extractf128_ps(dx, 1) : _mm256_castps256_ps128(dx);
            const __m128 dyh = h ? _mm256_extractf128_ps(dy, 1) : _mm256_castps256_ps128(dy);
            const __m128i cols = _mm_add_epi32(_mm_set1_epi32(f.originX + x + 4 * h), iota);
            const __m256d qx = _mm256_add_pd(_mm256_cvtepi32_pd(cols), _mm256_cvtps_pd(dxh));
            const __m256d qy = _mm256_add_pd(qyBase, _mm256_cvtps_pd(dyh));
            const __m256d wd = _mm256_add_pd(_mm256_add_pd(_mm256_mul_pd(h6, qx), _mm256_mul_pd(h7, qy)), h8);
            const __m256d numX = _mm256_add_pd(_mm256_add_pd(_mm256_mul_pd(h0, qx), _mm256_mul_pd(h1, qy)), h2);
            const __m256d numY = _mm256_add_pd(_mm256_add_pd(_mm256_mul_pd(h3, qx), _mm256_mul_pd(h4, qy)), h5);
            const __m256d degenerate = _mm256_cmp_pd(_mm256_andnot_pd(sign, wd), tiny, _CMP_LT_OQ);
            outX[h] = _mm256_cvtpd_ps(_mm256_blendv_pd(_mm256_div_pd(numX, wd), fallback, degenerate));
            outY[h] = _mm256_cvtpd_ps(_mm256_blendv_pd(_mm256_div_pd(numY, wd), fallback, degenerate));
        }
        _mm256_storeu_ps(mx + i, _mm256_insertf128_ps(_mm256_castps128_ps256(outX[0]), outX[1], 1));
        _mm256_storeu_ps(my + i, _mm256_insertf128_ps(_mm256_castps128_ps256(outY[0]), outY[1], 1));
    }
    for (; i < n; ++i) fieldMapOne(f, rowA0, rowA1, y, x0 + i, mx[i], my[i]);
}
#endif  // STAR_X86_AVX2_KERNELS

// cv::remap of `src` through the maps `fieldMapOne` describes, over a region of size `dsize`,
// into a zero-initialised `dst` (dsize, src's type), marking the pixels written in `covered`
// when it is given.  The maps are never made as planes.
inline void remapField(const cv::Mat &src, const DisplacementField &f, cv::Size dsize, cv::Mat &dst,
                       cv::Mat *covered)
{
    const Source source = sourceOf(src);
    const double stripes = (double)dsize.area() / (double)(1 << 16);
    cv::parallel_for_(cv::Range(0, dsize.height), [&](const cv::Range &r) {
        std::vector<float> blend(2 * (size_t)std::max(f.nx, 1));
        float *rowA0 = blend.data(), *rowA1 = blend.data() + std::max(f.nx, 1);
        const bool avx2 = useAvx2Rows();
        remapRows(source, dst, covered, dsize.width, r, [&](int y) {
            fieldRowBlend(f, y, rowA0, rowA1);
            return [&f, rowA0, rowA1, y, avx2](int x, int n, float *bufX, float *bufY,
                                              const float *&mx, const float *&my) {
#ifdef STAR_X86_AVX2_KERNELS
                if (avx2) fieldMapsAvx2(f, rowA0, rowA1, y, x, n, bufX, bufY);
                else
#endif
                    fieldMapsScalar(f, rowA0, rowA1, y, x, n, bufX, bufY);
                (void)avx2;
                mx = bufX;
                my = bufY;
            };
        });
    }, stripes);
}
#endif  // !__FMA__

}  // namespace exactwarp

#endif  // STAR_EXACT_WARP
