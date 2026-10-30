// Differential and timing harness for the CPU median merge kernels (MedianMerge.hpp).
//
// The reference is the Welford kernel, selected with the same override the Swift tests use; the
// kernel under test is whatever this machine runs by default (the exact-statistics kernel on
// x86-64 with AVX2).  The sweep compares their bytes over random shapes, depths, channel counts,
// source counts, thresholds and coverage planes, with data built to put the sigma-clip threshold
// exactly on a sample; the timing modes report single-thread ns per pixel-channel.
//
//   median_bench sweep [trials]        random differential, exit 1 on any difference
//   median_bench synthtime             synthetic 64x6000x3 bands, 9 and 17 sources
//   median_bench real a.tiff b.tiff..  a band of real 16-bit frames (>= 2 files)
#include "MedianMerge.hpp"

#include <chrono>
#include <cstdio>
#include <random>
#include <string>
#include <opencv2/imgcodecs.hpp>

using Clock = std::chrono::steady_clock;

static std::mt19937_64 rng(12345);

template <typename T>
static void fillRandom(cv::Mat &m, int mode, int maxv) {
    const int rows = m.rows, cols = m.cols * m.channels();
    std::uniform_int_distribution<int> full(0, maxv);
    std::uniform_int_distribution<int> small(0, 3);
    std::uniform_int_distribution<int> coin(0, 9);
    for (int y = 0; y < rows; ++y) {
        T *r = m.ptr<T>(y);
        int run = 0; int runv = 0;
        for (int x = 0; x < cols; ++x) {
            int v;
            switch (mode) {
            case 0: v = full(rng); break;
            case 1: v = 1000 + small(rng); break;                    // 4-value range
            case 2: v = coin(rng) < 4 ? 0 : full(rng); break;       // zeros mixed in
            case 3: v = coin(rng) < 5 ? maxv : full(rng); break;    // saturated
            case 4: if (run == 0) { run = 1 + (int)(rng() % 12); runv = full(rng); } v = runv; --run; break; // equal runs
            case 5: v = (maxv/2) + (int)(rng() % 40) - 20; break;   // noise around mid
            case 6: v = (maxv/3) + 2 * (int)(rng() % 3) * (int)(1 + rng() % 4); break; // two/three-point, exact-tie prone
            case 7: v = (maxv/4) + (int)(rng() & 1) * 2 * (1 + (int)(x / 7 % 5)); break; // balanced two-point per column group
            default: v = 0;
            }
            r[x] = (T)std::clamp(v, 0, maxv);
        }
    }
}

template <typename T>
static bool sameMat(const cv::Mat &a, const cv::Mat &b, long &diff) {
    diff = 0;
    for (int y = 0; y < a.rows; ++y) {
        const T *p = a.ptr<T>(y), *q = b.ptr<T>(y);
        for (int x = 0; x < a.cols * a.channels(); ++x) if (p[x] != q[x]) ++diff;
    }
    return diff == 0;
}

struct Totals { long long lanes = 0, differ = 0; };

template <typename T>
static void trial(int n, int rows, int cols, int ch, int mode, bool includeAll, double k,
                  bool withMiss, bool garbageMiss, Totals &tot, bool &failedOut) {
    const int type = CV_MAKETYPE(cv::DataDepth<T>::value, ch);
    const int maxv = sizeof(T) == 1 ? 255 : 65535;
    std::vector<cv::Mat> mats(n);
    for (auto &m : mats) { m.create(rows, cols, type); fillRandom<T>(m, mode, maxv); }
    cv::Mat miss;
    if (withMiss) {
        miss.create(rows, cols, CV_8UC1);
        for (int y = 0; y < rows; ++y) for (int x = 0; x < cols; ++x) {
            int r = (int)(rng() % 100);
            int c = r < 70 ? 0 : (r < 90 ? 1 + (int)(rng() % 3) : (int)(rng() % (n + 3)));
            miss.at<uchar>(y, x) = (uchar)c;
        }
        if (!garbageMiss) {
            // Honest coverage: the first `miss` sources (by index) have no sample -> zeros.
            for (int y = 0; y < rows; ++y) for (int x = 0; x < cols; ++x) {
                int c = std::min<int>(miss.at<uchar>(y, x), n);
                for (int i = 0; i < c; ++i) for (int q = 0; q < ch; ++q) mats[i].ptr<T>(y)[x * ch + q] = 0;
            }
        }
    }
    cv::Mat outOld(rows, cols, type), outNew(rows, cols, type), outDirect(rows, cols, type);
    gMedianKernelOverride.store(1);
    medianMergeTyped<T>(outOld, mats, k, includeAll, rows, cols, ch, CoverageMisses(miss));
    gMedianKernelOverride.store(0);
    medianMergeTyped<T>(outNew, mats, k, includeAll, rows, cols, ch, CoverageMisses(miss));
    long d1 = 0;
    bool ok = sameMat<T>(outOld, outNew, d1);
    tot.lanes += (long long)rows * cols * ch;
    tot.differ += d1;
    if (!ok) {
        failedOut = true;
        std::printf("DIFF n=%d rows=%d cols=%d ch=%d mode=%d includeAll=%d k=%g miss=%d garbage=%d depth=%zu : %ld differ\n",
                    n, rows, cols, ch, mode, includeAll, k, withMiss, garbageMiss, sizeof(T) * 8, d1);
    }
}

template <typename T>
static bool sweep(int trials, Totals &tot) {
    bool failed = false;
    const int ns[] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 9, 9, 10, 11, 12, 13, 14, 15, 16, 17, 17, 17, 18, 31, 33, 64, 65};
    const double ks[] = {0.0, 0.5, 1.0, 1.0, 1.2, 2.0, 2.0, 3.5, 100.0};
    for (int t = 0; t < trials; ++t) {
        int n = ns[rng() % (sizeof(ns) / sizeof(ns[0]))];
        int ch = (rng() & 1) ? 1 : 3;
        int rows = 2 + (int)(rng() % 5);
        int cols = 1 + (int)(rng() % 90);
        int mode = (int)(rng() % 8);
        bool includeAll = (rng() % 8) == 0;
        double k = ks[rng() % (sizeof(ks) / sizeof(ks[0]))];
        bool withMiss = (rng() % 3) != 0;
        bool garbage = withMiss && (rng() % 6) == 0;
        trial<T>(n, rows, cols, ch, mode, includeAll, k, withMiss, garbage, tot, failed);
    }
    return !failed;
}

template <typename T>
static double timeKernel(bool oldKernel, const std::vector<cv::Mat> &mats, cv::Mat &out, const cv::Mat &miss,
                         double k, int reps) {
    double best = 1e30;
    const int rows = out.rows, cols = out.cols, ch = out.channels();
    for (int r = 0; r < reps; ++r) {
        auto t0 = Clock::now();
        gMedianKernelOverride.store(oldKernel ? 1 : 0);
        medianMergeTyped<T>(out, mats, k, false, rows, cols, ch, CoverageMisses(miss));
        gMedianKernelOverride.store(0);
        double s = std::chrono::duration<double>(Clock::now() - t0).count();
        best = std::min(best, s);
    }
    return best;
}

int main(int argc, char **argv) {
    const std::string mode = argc > 1 ? argv[1] : "sweep";
    std::printf("kernel on this machine: %s\n", mergeKernelForThisMachine() == MergeKernel::ExactAvx2 ? "ExactAvx2" : "Welford");
    if (mode == "sweep") {
        int trials = argc > 2 ? atoi(argv[2]) : 2000;
        Totals t16, t8;
        bool ok16 = sweep<uint16_t>(trials, t16);
        bool ok8 = sweep<uchar>(trials, t8);
        std::printf("uint16: %lld pixel-channels, %lld differ\nuchar:  %lld pixel-channels, %lld differ\n",
                    t16.lanes, t16.differ, t8.lanes, t8.differ);
        return (ok16 && ok8) ? 0 : 1;
    }
    if (mode == "synthtime") {
        // Synthetic timing: n sources, 3 ch, a 6000x64 band, single thread.
        cv::setNumThreads(1);
        for (int n : {9, 17}) {
            for (int dmode : {5, 0}) {
                const int rows = 64, cols = 6000, ch = 3;
                std::vector<cv::Mat> mats(n);
                for (auto &m : mats) { m.create(rows, cols, CV_16UC3); fillRandom<uint16_t>(m, dmode, 65535); }
                cv::Mat miss(rows, cols, CV_8UC1, cv::Scalar(0));
                cv::Mat o1(rows, cols, CV_16UC3), o2(rows, cols, CV_16UC3);
                double a = timeKernel<uint16_t>(true, mats, o1, miss, 1.2, 5);
                double b = timeKernel<uint16_t>(false, mats, o2, miss, 1.2, 5);
                long d; bool same = sameMat<uint16_t>(o1, o2, d);
                double pc = (double)rows * cols * ch;
                std::printf("n=%2d data=%d  old %.1f ns/pc  new %.1f ns/pc  speedup %.2fx  identical=%d\n",
                            n, dmode, a / pc * 1e9, b / pc * 1e9, a / b, same);
            }
        }
        return 0;
    }
    if (mode == "real") {
        // argv[2..] = tiff paths (>= 2). A band of rows [r0, r1) of each.
        cv::setNumThreads(1);
        std::vector<cv::Mat> mats;
        const int r0 = 1500, r1 = 1564;
        for (int i = 2; i < argc; ++i) {
            cv::Mat full = cv::imread(argv[i], cv::IMREAD_UNCHANGED);
            if (full.empty()) { std::printf("cannot read %s\n", argv[i]); return 2; }
            mats.push_back(full.rowRange(r0, r1).clone());
        }
        const int rows = mats[0].rows, cols = mats[0].cols, ch = mats[0].channels();
        cv::Mat miss(rows, cols, CV_8UC1, cv::Scalar(0));
        for (int y = 0; y < rows; ++y) for (int x = 0; x < 40; ++x) miss.at<uchar>(y, x) = (uchar)(1 + x % 3);
        for (int y = 0; y < rows; ++y) for (int x = 0; x < 40; ++x)
            for (int i = 0; i < (int)miss.at<uchar>(y, x) && i < (int)mats.size(); ++i)
                for (int q = 0; q < ch; ++q) mats[i].ptr<uint16_t>(y)[x * ch + q] = 0;
        cv::Mat o1(rows, cols, mats[0].type()), o2(rows, cols, mats[0].type());
        double a = timeKernel<uint16_t>(true, mats, o1, miss, 1.2, 5);
        double b = timeKernel<uint16_t>(false, mats, o2, miss, 1.2, 5);
        long d; bool same = sameMat<uint16_t>(o1, o2, d);
        double pc = (double)rows * cols * ch;
        std::printf("real %zu sources %dx%d ch%d: old %.1f ns/pc  new %.1f ns/pc  speedup %.2fx  identical=%d (differ %ld)\n",
                    mats.size(), rows, cols, ch, a / pc * 1e9, b / pc * 1e9, a / b, same, d);
        return same ? 0 : 1;
    }
    return 2;
}
