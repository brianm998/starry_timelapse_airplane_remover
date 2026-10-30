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
    const unsigned width1 = sw > 1 ? (unsigned)(sw - 1) : 0u;
    const unsigned height1 = sh > 1 ? (unsigned)(sh - 1) : 0u;

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
}


#ifdef STAR_X86_AVX2_KERNELS

// The same row, with the coordinates four pixels at a time in AVX2 doubles and the
// three-channel interpolation four floats at a time.  Every value is the one `warpRow`
// computes, from the same operations in the same order: the vector lanes are independent
// pixels (or channels), and none of the arithmetic is fused — AVX2 here means the wide
// registers, not FMA, which this target does not enable.
template <int CN, bool Pixels>
STAR_AVX2 inline void warpRowAvx2(const uint16_t *S0, size_t sstep, int sw, int sh,
                                  uint16_t *D, uint8_t *cov, int width, int y,
                                  const double *M, int bw0, const float *wtab)
{
#pragma clang fp contract(off)
    alignas(32) short xy[2 * 1024];
    alignas(32) unsigned short alpha[1024];
    const unsigned width1 = sw > 1 ? (unsigned)(sw - 1) : 0u;
    const unsigned height1 = sh > 1 ? (unsigned)(sh - 1) : 0u;

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

        for (int x1 = 0; x1 < bw; ++x1) {
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

template <bool Pixels>
inline void warpRows(const Source &src, cv::Mat *dst, cv::Mat *covered, const double *M,
                     int yStart, int yEnd, int cols, int rows)
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
        uint16_t *D = Pixels ? dst->ptr<uint16_t>(y) : nullptr;
        uint8_t *cov = covered ? covered->ptr<uint8_t>(y) : nullptr;
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

}  // namespace exactwarp

#endif  // STAR_EXACT_WARP
