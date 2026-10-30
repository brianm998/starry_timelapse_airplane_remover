// Differential and timing harness: ExactWarp.hpp against cv::warpPerspective (BORDER_TRANSPARENT,
// INTER_LINEAR) and against the 8-bit probe warp that `warpCoverage` used to be.
//
//   warp_bench sweep [trials]   random sizes, homographies and fills; scalar and AVX2 rows; the
//                               warp's own coverage marks and the coverage-only pass.  Exit 1 on
//                               any pixel or coverage difference.
//   warp_bench time             single-thread ns per pixel-channel against OpenCV (16-bit warp plus
//                               8-bit probe) on a 6000x1000x3 frame
#include "ExactWarp.hpp"
#include <opencv2/imgproc.hpp>
#include <opencv2/imgcodecs.hpp>
#include <chrono>
#include <cstdio>
#include <random>
#include <string>

using Clock = std::chrono::steady_clock;
static std::mt19937_64 rng(777);
static double urand(double a, double b) { return a + (b - a) * (double)(rng() >> 11) / (double)(1ULL << 53); }

static cv::Mat randomH(int w, int h, int kind) {
    cv::Mat H = cv::Mat::eye(3, 3, CV_64F);
    auto at = [&](int r, int c) -> double & { return H.at<double>(r, c); };
    switch (kind) {
    case 0: break;                                                           // identity
    case 1: at(0, 2) = (int)urand(-7, 7); at(1, 2) = (int)urand(-7, 7); break; // integer shift
    case 2: at(0, 2) = urand(-9, 9); at(1, 2) = urand(-9, 9); break;          // fractional shift
    case 3: {                                                                 // near identity, generic
        at(0, 0) = 1 + urand(-2e-4, 2e-4); at(0, 1) = urand(-3e-4, 3e-4); at(0, 2) = urand(-12, 12);
        at(1, 0) = urand(-3e-4, 3e-4); at(1, 1) = 1 + urand(-2e-4, 2e-4); at(1, 2) = urand(-12, 12);
        at(2, 0) = urand(-1e-8, 1e-8); at(2, 1) = urand(-1e-8, 1e-8);
        break; }
    case 4: {                                                                 // rotation + scale about centre
        double a = urand(-0.05, 0.05), s = 1 + urand(-0.05, 0.05), cx = w / 2.0, cy = h / 2.0;
        at(0, 0) = s * cos(a); at(0, 1) = -s * sin(a); at(1, 0) = s * sin(a); at(1, 1) = s * cos(a);
        at(0, 2) = cx - (at(0, 0) * cx + at(0, 1) * cy) + urand(-4, 4);
        at(1, 2) = cy - (at(1, 0) * cx + at(1, 1) * cy) + urand(-4, 4);
        break; }
    case 5: {                                                                 // strong perspective
        at(0, 0) = 1 + urand(-.2, .2); at(0, 1) = urand(-.1, .1); at(0, 2) = urand(-20, 20);
        at(1, 0) = urand(-.1, .1); at(1, 1) = 1 + urand(-.2, .2); at(1, 2) = urand(-20, 20);
        at(2, 0) = urand(-2e-3, 2e-3); at(2, 1) = urand(-2e-3, 2e-3);
        break; }
    case 6: at(0, 2) = urand(-w * 0.6, w * 0.6); at(1, 2) = urand(-h * 0.6, h * 0.6); break; // large shift
    case 7: at(0, 0) = -1; at(0, 2) = w - 1 + urand(-1, 1); break;             // mirror
    case 8: at(0, 0) = 0.5 + urand(0, 1); at(1, 1) = 0.5 + urand(0, 1); at(0, 2) = urand(-30, 30); at(1, 2) = urand(-30, 30); break; // zoom
    case 9: { at(0, 2) = 0.5; at(1, 2) = 0.5; break; }                        // exact half pixels (weight ties)
    case 10: { at(0, 2) = 0.03125 * (int)urand(-40, 40); at(1, 2) = 0.03125 * (int)urand(-40, 40); break; } // exact 32nds
    case 11: { at(2, 2) = 0; break; }                                         // degenerate W=0
    }
    return H;
}

static void fill(cv::Mat &m, int mode) {
    for (int y = 0; y < m.rows; ++y) {
        uint16_t *p = m.ptr<uint16_t>(y);
        for (int x = 0; x < m.cols * m.channels(); ++x) {
            switch (mode) {
            case 0: p[x] = (uint16_t)(rng() & 0xffff); break;
            case 1: p[x] = (uint16_t)(1000 + (rng() % 30)); break;
            case 2: p[x] = (uint16_t)((rng() & 1) ? 65535 : 0); break;
            default: p[x] = (uint16_t)((x * 37 + y * 11) & 0xffff);
            }
        }
    }
}

struct Result { long long pixels = 0, differ = 0, covDiffer = 0; };

static bool oneCase(int w, int h, int cn, int kind, int fmode, Result &res) {
    cv::Mat src(h, w, CV_MAKETYPE(CV_16U, cn));
    fill(src, fmode);
    cv::Mat H = randomH(w, h, kind);
    if (!exactwarp::applies(src, H)) return true;

    cv::Mat ref = cv::Mat::zeros(src.size(), src.type());
    cv::warpPerspective(src, ref, H, src.size(), cv::INTER_LINEAR, cv::BORDER_TRANSPARENT);
    cv::Mat probe(src.size(), CV_8UC1, cv::Scalar(255)), refCov = cv::Mat::zeros(src.size(), CV_8UC1);
    cv::warpPerspective(probe, refCov, H, src.size(), cv::INTER_LINEAR, cv::BORDER_TRANSPARENT);

    long long d = 0, dc = 0;
    for (int scalar = 0; scalar < 2; ++scalar) {
        exactwarp::forceScalarFlag() = scalar == 1;
        cv::Mat out = cv::Mat::zeros(src.size(), src.type()), cov = cv::Mat::zeros(src.size(), CV_8UC1);
        exactwarp::warp(src, H, out, &cov);
        for (int y = 0; y < h; ++y) {
            const uint16_t *a = ref.ptr<uint16_t>(y), *b = out.ptr<uint16_t>(y);
            for (int x = 0; x < w * cn; ++x) d += a[x] != b[x];
            const uint8_t *ca = refCov.ptr<uint8_t>(y), *cb = cov.ptr<uint8_t>(y);
            for (int x = 0; x < w; ++x) dc += ca[x] != cb[x];
        }
    }
    exactwarp::forceScalarFlag() = false;
    {   // the analytic coverage, with no pixels read, against the 8-bit probe warp
        for (int scalar = 0; scalar < 2; ++scalar) {
            exactwarp::forceScalarFlag() = scalar == 1;
            cv::Mat cov2 = exactwarp::coverage(src.size(), H);
            for (int y = 0; y < h; ++y) {
                const uint8_t *ca = refCov.ptr<uint8_t>(y), *cb = cov2.ptr<uint8_t>(y);
                for (int x = 0; x < w; ++x) dc += ca[x] != cb[x];
            }
        }
        exactwarp::forceScalarFlag() = false;
    }
    res.pixels += (long long)w * h * cn * 2; res.differ += d; res.covDiffer += dc;
    if (d || dc) std::printf("DIFF %dx%d cn=%d kind=%d fill=%d: %lld pixel-channels, %lld coverage\n", w, h, cn, kind, fmode, d, dc);
    return d == 0 && dc == 0;
}

int main(int argc, char **argv) {
    std::string mode = argc > 1 ? argv[1] : "sweep";
    if (mode == "sweep") {
        int trials = argc > 2 ? atoi(argv[2]) : 600;
        Result r; bool ok = true;
        const int sizes[][2] = {{1,1},{2,2},{3,7},{16,1},{1,40},{17,9},{63,15},{64,16},{65,17},{100,33},{130,70},{257,129},{513,31},{1200,40},{1030,20}};
        for (int t = 0; t < trials; ++t) {
            auto &sz = sizes[rng() % (sizeof(sizes) / sizeof(sizes[0]))];
            int cn = (rng() & 1) ? 1 : 3, kind = (int)(rng() % 12), fm = (int)(rng() % 4);
            ok &= oneCase(sz[0], sz[1], cn, kind, fm, r);
        }
        std::printf("%lld pixel-channels, %lld differ, %lld coverage differ\n", r.pixels, r.differ, r.covDiffer);
        return ok ? 0 : 1;
    }
    if (mode == "time") {
        cv::setNumThreads(1);
        const int w = 6000, h = 1000, cn = 3;
        cv::Mat src(h, w, CV_16UC3); fill(src, 0);
        for (int kind : {3, 4}) {
            cv::Mat H = randomH(w, h, kind);
            cv::Mat ref(src.size(), src.type()), out(src.size(), src.type()), cov(src.size(), CV_8UC1);
            cv::Mat probe(src.size(), CV_8UC1, cv::Scalar(255)), refCov(src.size(), CV_8UC1);
            double best1 = 1e9, best2 = 1e9, best3 = 1e9;
            for (int r = 0; r < 4; ++r) {
                ref.setTo(0); auto t = Clock::now(); cv::warpPerspective(src, ref, H, src.size(), cv::INTER_LINEAR, cv::BORDER_TRANSPARENT);
                best1 = std::min(best1, std::chrono::duration<double>(Clock::now() - t).count());
                refCov.setTo(0); t = Clock::now(); cv::warpPerspective(probe, refCov, H, src.size(), cv::INTER_LINEAR, cv::BORDER_TRANSPARENT);
                best3 = std::min(best3, std::chrono::duration<double>(Clock::now() - t).count());
                out.setTo(0); cov.setTo(0); t = Clock::now(); exactwarp::warp(src, H, out, &cov);
                best2 = std::min(best2, std::chrono::duration<double>(Clock::now() - t).count());
            }
            double pc = (double)w * h * cn;
            std::printf("kind %d: cv 16-bit %.1f ns/pc + 8-bit probe %.1f ns/px  | exact (warp+coverage) %.1f ns/pc  speedup %.2fx (vs both)\n",
                        kind, best1 / pc * 1e9, best3 / ((double)w * h) * 1e9, best2 / pc * 1e9, (best1 + best3) / best2);
        }
        return 0;
    }
    return 2;
}
