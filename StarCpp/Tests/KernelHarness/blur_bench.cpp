// Differential and timing harness: BoxBlur.hpp's AVX2 box blur against the cloud stage's original
// `boxBlurOnce` (a verbatim copy below) and against the scalar form that header keeps.
//
//   blur_bench sweep [trials]   random planes (luma-sized, weight-sized, signed, NaN / inf / huge /
//                               exact ties), widths and heights from 1 up (including narrower than
//                               the window), radii 1..48, both scales.  Bitwise comparison of every
//                               float.  Exit 1 on any difference.
//   blur_bench time             single-thread ns per element for three passes of r = 24 and r = 6 on
//                               a 6000x3400 plane, original vs AVX2
#include "BoxBlur.hpp"
#include <chrono>
#include <cstdio>
#include <cstring>
#include <limits>
#include <random>
#include <string>

using Clock = std::chrono::steady_clock;
static std::mt19937_64 rng(99);
static double urand(double a, double b) { return a + (b - a) * (double)(rng() >> 11) / (double)(1ULL << 53); }

// ---- the original, as it was in ImageAligner.cpp before BoxBlur.hpp -------------------------

static inline int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

static void originalBoxBlurOnce(cv::Mat &plane, cv::Mat &rowSums, int r, double scale) {
    const int h = plane.rows, w = plane.cols, win = 2 * r + 1;
    const double qmax = (double)(INT32_MAX / win);
    rowSums.create(h, w, CV_32S);

    cv::parallel_for_(cv::Range(0, h), [&](const cv::Range &rg) {
        std::vector<int32_t> q((size_t)w);
        for (int y = rg.start; y < rg.end; ++y) {
            const float *src = plane.ptr<float>(y);
            for (int x = 0; x < w; ++x) {
                double v = std::nearbyint((double)src[x] * scale);
                if (!(v == v)) v = 0;
                q[(size_t)x] = (int32_t)std::min(std::max(v, -qmax), qmax);
            }
            int32_t *dst = rowSums.ptr<int32_t>(y);
            int64_t s = 0;
            for (int x = -r; x <= r; ++x) s += q[(size_t)clampi(x, 0, w - 1)];
            dst[0] = (int32_t)s;
            for (int x = 1; x < w; ++x) {
                s += (int64_t)q[(size_t)std::min(x + r, w - 1)]
                   - (int64_t)q[(size_t)std::max(x - r - 1, 0)];
                dst[x] = (int32_t)s;
            }
        }
    });

    const double norm = (double)win * (double)win * scale;
    const int strip = 64;
    cv::parallel_for_(cv::Range(0, (w + strip - 1) / strip), [&](const cv::Range &rg) {
        std::vector<int64_t> acc((size_t)strip);
        for (int sIdx = rg.start; sIdx < rg.end; ++sIdx) {
            const int x0 = sIdx * strip, x1 = std::min(w, x0 + strip), n = x1 - x0;
            for (int i = 0; i < n; ++i) acc[(size_t)i] = 0;
            for (int y = -r; y <= r; ++y) {
                const int32_t *row = rowSums.ptr<int32_t>(clampi(y, 0, h - 1)) + x0;
                for (int i = 0; i < n; ++i) acc[(size_t)i] += row[i];
            }
            for (int y = 0; y < h; ++y) {
                float *out = plane.ptr<float>(y) + x0;
                for (int i = 0; i < n; ++i) out[i] = (float)((double)acc[(size_t)i] / norm);
                if (y + 1 < h) {
                    const int32_t *add = rowSums.ptr<int32_t>(std::min(y + 1 + r, h - 1)) + x0;
                    const int32_t *sub = rowSums.ptr<int32_t>(std::max(y - r, 0)) + x0;
                    for (int i = 0; i < n; ++i)
                        acc[(size_t)i] += (int64_t)add[i] - (int64_t)sub[i];
                }
            }
        }
    });
}

// ---- cases ----------------------------------------------------------------------------------

static float sample(int kind, double scale) {
    switch (kind) {
    case 0: return (float)urand(0, 65535);
    case 1: return (float)urand(0, 1);
    case 2: return (float)urand(-70000, 70000);
    case 3: {
        const float specials[] = {std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity(),
                                  -std::numeric_limits<float>::infinity(), 1e30f, -1e30f, 0.f, -0.f,
                                  1e-40f, -1e-40f, 3.4e38f};
        switch (rng() % 4) {
        case 0: return specials[rng() % (sizeof specials / sizeof specials[0])];
        case 1: return (float)(((int)(rng() % 20001) - 10000 + 0.5) / scale);      // exact ties at the scale
        case 2: return (float)(((int)(rng() % 2001) - 1000 + 0.25) / scale);
        default: return (float)urand(-1e9, 1e9);
        }
    }
    default: return 12345.678f;
    }
}

static bool oneCase(int w, int h, int r, double scale, int kind, long long &compared) {
    cv::Mat src(h, w, CV_32F);
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) src.at<float>(y, x) = sample(kind, scale);
    cv::Mat a = src.clone(), b = src.clone(), c = src.clone(), scratch;
    originalBoxBlurOnce(a, scratch, r, scale);
    boxblur::boxBlurOnce(b, scratch, r, scale, false);
    boxblur::boxBlurOnce(c, scratch, r, scale, true);
    long long dScalar = 0, dAvx = 0;
    for (int y = 0; y < h; ++y) {
        dScalar += std::memcmp(a.ptr<float>(y), b.ptr<float>(y), (size_t)w * 4) != 0;
        dAvx += std::memcmp(a.ptr<float>(y), c.ptr<float>(y), (size_t)w * 4) != 0;
    }
    compared += (long long)w * h;
    if (dScalar || dAvx)
        std::printf("DIFF %dx%d r=%d scale=%g kind=%d: scalar form %lld rows, AVX2 %lld rows\n", w, h, r, scale, kind, dScalar, dAvx);
    return !dScalar && !dAvx;
}

int main(int argc, char **argv) {
    std::string mode = argc > 1 ? argv[1] : "sweep";
    if (mode == "sweep") {
        const int trials = argc > 2 ? atoi(argv[2]) : 800;
        const int dims[] = {1, 2, 3, 4, 5, 7, 8, 9, 31, 63, 64, 65, 97, 130, 257, 600};
        const int radii[] = {1, 2, 6, 16, 24, 48};
        const double scales[] = {256.0, 65536.0};
        bool ok = true; long long compared = 0;
        for (int t = 0; t < trials; ++t) {
            const int w = dims[rng() % (sizeof dims / sizeof dims[0])], h = dims[rng() % (sizeof dims / sizeof dims[0])];
            ok &= oneCase(w, h, radii[rng() % 6], scales[rng() % 2], (int)(rng() % 5), compared);
        }
        std::printf("%lld elements, %s\n", compared, ok ? "0 differ" : "DIFFERENCES");
        return ok ? 0 : 1;
    }
    if (mode == "time") {
        cv::setNumThreads(1);
        const int w = 6000, h = 3400;
        cv::Mat src(h, w, CV_32F);
        for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) src.at<float>(y, x) = (float)urand(0, 65535);
        for (int r : {24, 6}) {
            double bestO = 1e9, bestN = 1e9;
            cv::Mat a, scratch;
            for (int rep = 0; rep < 3; ++rep) {
                a = src.clone(); auto t = Clock::now();
                for (int p = 0; p < 3; ++p) originalBoxBlurOnce(a, scratch, r, 256.0);
                bestO = std::min(bestO, std::chrono::duration<double>(Clock::now() - t).count());
                a = src.clone(); t = Clock::now();
                for (int p = 0; p < 3; ++p) boxblur::boxBlurOnce(a, scratch, r, 256.0, true);
                bestN = std::min(bestN, std::chrono::duration<double>(Clock::now() - t).count());
            }
            const double el = (double)w * h * 3;
            std::printf("r=%d: original %.2f ns/element-pass, AVX2 %.2f  (%.2fx)\n", r, bestO / el * 1e9, bestN / el * 1e9, bestO / bestN);
            for (int strip : {32, 128, 256, 512, 1024}) {
                double best = 1e9;
                for (int rep = 0; rep < 3; ++rep) {
                    a = src.clone(); auto t = Clock::now();
                    for (int p = 0; p < 3; ++p) boxblur::boxBlurOnce(a, scratch, r, 256.0, true, strip);
                    best = std::min(best, std::chrono::duration<double>(Clock::now() - t).count());
                }
                std::printf("      AVX2 strip %4d: %.2f ns/element-pass\n", strip, best / el * 1e9);
            }
        }
        return 0;
    }
    return 2;
}
