// BoxBlur.hpp — the cloud-aware stage's exact box blur, with an AVX2 form that returns the same
// float for every element.
//
// `boxBlurOnce` is one pass of a (2r+1)x(2r+1) box filter over a CV_32F plane, in place, with
// BORDER_REPLICATE edges and arithmetic that does not depend on where a window starts: every
// value is rounded to a multiple of 1/scale first, the sums are integers, and the one division
// at the end is exactly rounded.  That is what lets the stage agree to the bit whether it works
// on bands or on the whole frame, and it is also what makes a vector version possible without
// a tolerance: integer sums are the same in any order, and the two floating point steps (the
// rounding to 1/scale, the division) are single correctly rounded operations that a vector
// instruction performs identically.
//
// The scalar form is the stage's original code, kept as it was; it runs wherever AVX2 does not
// and is what the vector form is held to (`KernelHarness/blur_bench`, `CloudAwareMergeTests`).
// A profile of a cloudy merge phase had the two passes at 13.7 % of the busy samples:
// `std::nearbyint` is a library call per element at the SSE2 baseline, and the row sums
// clamped two indices per element.
#pragma once

#include "CpuFeatures.hpp"

#include <opencv2/core.hpp>
#include <opencv2/core/utility.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace boxblur {

inline int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

// Rounds `x * scale` to the nearest integer (ties to even), 0 for NaN, within +-qmax.
inline int32_t quantiseOne(float x, double scale, double qmax) {
    double v = std::nearbyint((double)x * scale);
    if (!(v == v)) v = 0;
    return (int32_t)std::min(std::max(v, -qmax), qmax);
}

// The horizontal pass of one row, as the stage first wrote it: `q` is the row quantised, `dst`
// receives the (2r+1)-wide sums with the edge pixels repeated.
inline void rowSumsScalar(const float *src, int w, int r, double scale, double qmax,
                          std::vector<int32_t> &q, int32_t *dst)
{
    for (int x = 0; x < w; ++x) q[(size_t)x] = quantiseOne(src[x], scale, qmax);
    int64_t s = 0;
    for (int x = -r; x <= r; ++x) s += q[(size_t)clampi(x, 0, w - 1)];
    dst[0] = (int32_t)s;
    for (int x = 1; x < w; ++x) {
        s += (int64_t)q[(size_t)std::min(x + r, w - 1)] - (int64_t)q[(size_t)std::max(x - r - 1, 0)];
        dst[x] = (int32_t)s;
    }
}

// The vertical pass over columns [x0, x0 + n) as the stage first wrote it: `acc` is scratch for
// n int64s.
inline void columnsScalar(cv::Mat &plane, const cv::Mat &rowSums, int r, double norm, int x0, int n,
                          int64_t *acc)
{
    const int h = plane.rows;
    for (int i = 0; i < n; ++i) acc[i] = 0;
    for (int y = -r; y <= r; ++y) {
        const int32_t *row = rowSums.ptr<int32_t>(clampi(y, 0, h - 1)) + x0;
        for (int i = 0; i < n; ++i) acc[i] += row[i];
    }
    for (int y = 0; y < h; ++y) {
        float *out = plane.ptr<float>(y) + x0;
        for (int i = 0; i < n; ++i) out[i] = (float)((double)acc[i] / norm);
        if (y + 1 < h) {
            const int32_t *add = rowSums.ptr<int32_t>(std::min(y + 1 + r, h - 1)) + x0;
            const int32_t *sub = rowSums.ptr<int32_t>(std::max(y - r, 0)) + x0;
            for (int i = 0; i < n; ++i) acc[i] += (int64_t)add[i] - (int64_t)sub[i];
        }
    }
}

#ifdef STAR_X86_AVX2_KERNELS

// Four floats at a time: the same product in double, the same round-to-nearest-even (`roundpd`
// and `nearbyint` agree under the default rounding mode), NaN to 0 after the rounding as the
// scalar does it, the same clamp.  Every value is then an integer inside the int range, so the
// conversion is exact.
STAR_AVX2 inline void quantiseRowAvx2(const float *src, int w, double scale, double qmax, int32_t *q) {
    const __m256d vScale = _mm256_set1_pd(scale), vHigh = _mm256_set1_pd(qmax), vLow = _mm256_set1_pd(-qmax);
    int x = 0;
    for (; x + 4 <= w; x += 4) {
        __m256d d = _mm256_mul_pd(_mm256_cvtps_pd(_mm_loadu_ps(src + x)), vScale);
        d = _mm256_round_pd(d, _MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC);
        d = _mm256_andnot_pd(_mm256_cmp_pd(d, d, _CMP_UNORD_Q), d);
        d = _mm256_min_pd(_mm256_max_pd(d, vLow), vHigh);
        _mm_storeu_si128((__m128i *)(q + x), _mm256_cvtpd_epi32(d));
    }
    for (; x < w; ++x) q[x] = quantiseOne(src[x], scale, qmax);
}

// The horizontal pass of one row: the quantised row padded with `r` copies of each end (so the
// window never needs a clamp, and a row narrower than the window still sees the same pixels the
// clamped indices would give), then the running sum.
STAR_AVX2 inline void rowSumsAvx2(const float *src, int w, int r, double scale, double qmax,
                                  std::vector<int32_t> &padded, int32_t *dst)
{
    int32_t *q = padded.data() + r;
    quantiseRowAvx2(src, w, scale, qmax, q);
    for (int k = 0; k < r; ++k) { padded[(size_t)k] = q[0]; q[w + k] = q[w - 1]; }
    const int32_t *p = padded.data();
    int64_t s = 0;
    for (int k = 0; k <= 2 * r; ++k) s += p[k];
    dst[0] = (int32_t)s;
    for (int x = 1; x < w; ++x) {
        s += (int64_t)p[x + 2 * r] - (int64_t)p[x - 1];
        dst[x] = (int32_t)s;
    }
}

// int64 to double, exactly, for |x| < 2^51: the integer is added to the bits of 1.5 * 2^52, which
// leaves it in the low mantissa bits, and 1.5 * 2^52 is taken off again.  A column sum is at most
// (2r+1) row sums of at most INT32_MAX each — about 2^38 at the largest radius used.
STAR_AVX2 inline __m256d int64ToDouble(__m256i x) {
    const __m256i magicBits = _mm256_set1_epi64x(0x4338000000000000LL);
    const __m256d magic = _mm256_set1_pd(6755399441055744.0);
    return _mm256_sub_pd(_mm256_castsi256_pd(_mm256_add_epi64(x, magicBits)), magic);
}

STAR_AVX2 inline void columnsAvx2(cv::Mat &plane, const cv::Mat &rowSums, int r, double norm, int x0, int n,
                                  int64_t *acc)
{
    const int h = plane.rows;
    const int n4 = n & ~3;
    const __m256d vNorm = _mm256_set1_pd(norm);

    for (int i = 0; i < n; ++i) acc[i] = 0;
    for (int y = -r; y <= r; ++y) {
        const int32_t *row = rowSums.ptr<int32_t>(clampi(y, 0, h - 1)) + x0;
        for (int i = 0; i < n4; i += 4) {
            const __m256i a = _mm256_loadu_si256((const __m256i *)(acc + i));
            const __m256i v = _mm256_cvtepi32_epi64(_mm_loadu_si128((const __m128i *)(row + i)));
            _mm256_storeu_si256((__m256i *)(acc + i), _mm256_add_epi64(a, v));
        }
        for (int i = n4; i < n; ++i) acc[i] += row[i];
    }
    for (int y = 0; y < h; ++y) {
        float *out = plane.ptr<float>(y) + x0;
        for (int i = 0; i < n4; i += 4) {
            const __m256d d = _mm256_div_pd(int64ToDouble(_mm256_loadu_si256((const __m256i *)(acc + i))), vNorm);
            _mm_storeu_ps(out + i, _mm256_cvtpd_ps(d));
        }
        for (int i = n4; i < n; ++i) out[i] = (float)((double)acc[i] / norm);
        if (y + 1 < h) {
            const int32_t *add = rowSums.ptr<int32_t>(std::min(y + 1 + r, h - 1)) + x0;
            const int32_t *sub = rowSums.ptr<int32_t>(std::max(y - r, 0)) + x0;
            for (int i = 0; i < n4; i += 4) {
                const __m256i a = _mm256_loadu_si256((const __m256i *)(acc + i));
                const __m256i p = _mm256_cvtepi32_epi64(_mm_loadu_si128((const __m128i *)(add + i)));
                const __m256i m = _mm256_cvtepi32_epi64(_mm_loadu_si128((const __m128i *)(sub + i)));
                _mm256_storeu_si256((__m256i *)(acc + i), _mm256_add_epi64(a, _mm256_sub_epi64(p, m)));
            }
            for (int i = n4; i < n; ++i) acc[i] += (int64_t)add[i] - (int64_t)sub[i];
        }
    }
}

#endif  // STAR_X86_AVX2_KERNELS

// Test hook: the scalar form even where AVX2 is available.
inline bool &forceScalarFlag() { static bool flag = false; return flag; }

inline bool useAvx2() {
#ifdef STAR_X86_AVX2_KERNELS
    return cpuRunsAvx2() && !forceScalarFlag();
#else
    return false;
#endif
}

// One pass of a (2r+1) square box filter over a CV_32F plane, in place.  `rowSums` is scratch.
// `fast` allows the AVX2 form.  `strip` is how many columns one task sweeps down the plane: the
// result does not depend on it, the speed does (a column's sums are read a row at a time at a
// stride of a whole row, so a wider strip makes each of those reads a longer run of the same
// cache lines — 64 was the original, 256 to 512 measured best on a 6000 wide plane, and 256 keeps
// 24 tasks for it).
inline void boxBlurOnce(cv::Mat &plane, cv::Mat &rowSums, int r, double scale, bool fast = true, int strip = 256) {
    const int h = plane.rows, w = plane.cols, win = 2 * r + 1;
    // A row sum has to fit an int32; every value this is given is far inside this.
    const double qmax = (double)(INT32_MAX / win);
    rowSums.create(h, w, CV_32S);
    const bool avx2 = fast && useAvx2();

    cv::parallel_for_(cv::Range(0, h), [&](const cv::Range &rg) {
        std::vector<int32_t> q((size_t)w + 2 * (size_t)r);
        for (int y = rg.start; y < rg.end; ++y) {
#ifdef STAR_X86_AVX2_KERNELS
            if (avx2) { rowSumsAvx2(plane.ptr<float>(y), w, r, scale, qmax, q, rowSums.ptr<int32_t>(y)); continue; }
#endif
            rowSumsScalar(plane.ptr<float>(y), w, r, scale, qmax, q, rowSums.ptr<int32_t>(y));
        }
    });

    const double norm = (double)win * (double)win * scale;
    cv::parallel_for_(cv::Range(0, (w + strip - 1) / strip), [&](const cv::Range &rg) {
        std::vector<int64_t> acc((size_t)strip);
        for (int sIdx = rg.start; sIdx < rg.end; ++sIdx) {
            const int x0 = sIdx * strip, x1 = std::min(w, x0 + strip), n = x1 - x0;
#ifdef STAR_X86_AVX2_KERNELS
            if (avx2) { columnsAvx2(plane, rowSums, r, norm, x0, n, acc.data()); continue; }
#endif
            columnsScalar(plane, rowSums, r, norm, x0, n, acc.data());
        }
    });
    (void)avx2;
}

}  // namespace boxblur
