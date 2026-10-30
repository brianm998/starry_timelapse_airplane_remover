// Differential and timing harness: PairMatch.hpp against cv::BFMatcher::knnMatch(query, train, 2).
//
//   match_bench sweep [trials]   random descriptor sets (SIFT-like float 128-d, quantised floats
//                                with many equal distances, all-equal rows, rows that overflow the
//                                squared sum, packed bits for Hamming), query and train sizes from
//                                1 up.  Forward and reverse results from one pair pass, and through
//                                `knn2` with its cache, bit for bit against BFMatcher (query, train
//                                and train, query).  Exit 1 on any difference.
//   match_bench time             two directions through BFMatcher against one pair pass, on SIFT-like
//                                8000 x 8000 descriptors
#include "PairMatch.hpp"
#include <chrono>
#include <cstdio>
#include <random>
#include <string>

using Clock = std::chrono::steady_clock;
static std::mt19937_64 rng(31337);

static cv::Mat makeSet(int rows, int cols, bool bits, int mode, const cv::Mat *pool = nullptr) {
    cv::Mat m(rows, cols, bits ? CV_8UC1 : CV_32FC1);
    for (int y = 0; y < rows; ++y) {
        if (bits) {
            uchar *p = m.ptr<uchar>(y);
            for (int x = 0; x < cols; ++x) {
                switch (mode) {
                case 0: p[x] = (uchar)(rng() & 0xff); break;
                case 1: p[x] = (uchar)((rng() & 3) ? 0 : 0xff); break;           // few distinct distances: ties
                case 2: p[x] = 0x5a; break;                                       // all equal
                default: p[x] = (uchar)(1u << (rng() % 8));
                }
            }
        } else {
            float *p = m.ptr<float>(y);
            for (int x = 0; x < cols; ++x) {
                switch (mode) {
                case 0: p[x] = (float)(rng() % 256); break;                       // SIFT-like integers
                case 1: p[x] = (float)((double)(rng() >> 11) / (double)(1ULL << 53)); break;
                case 2: p[x] = (float)(rng() % 3); break;                         // very few distinct values: ties
                case 3: p[x] = 1.5f; break;                                       // all equal
                default: p[x] = (rng() & 7) ? 3e19f : (float)(rng() % 7);         // squared sums overflow to inf
                }
            }
        }
    }
    if (pool && pool->rows > 0 && mode != 3) {                                    // some rows repeated from the other set
        for (int y = 0; y < rows; ++y)
            if ((rng() & 3) == 0) pool->row((int)(rng() % (uint64_t)pool->rows)).copyTo(m.row(y));
    }
    return m;
}

static bool sameMatches(const std::vector<std::vector<cv::DMatch>> &a, const std::vector<std::vector<cv::DMatch>> &b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i) {
        if (a[i].size() != b[i].size()) return false;
        for (size_t k = 0; k < a[i].size(); ++k) {
            uint32_t da, db;
            std::memcpy(&da, &a[i][k].distance, 4);
            std::memcpy(&db, &b[i][k].distance, 4);
            if (a[i][k].queryIdx != b[i][k].queryIdx || a[i][k].trainIdx != b[i][k].trainIdx ||
                a[i][k].imgIdx != b[i][k].imgIdx || da != db) return false;
        }
    }
    return true;
}

static bool oneCase(int N, int M, int len, bool bits, int mode, long long &pairs) {
    cv::Mat q = makeSet(N, len, bits, mode);
    cv::Mat t = makeSet(M, len, bits, mode, &q);
    const int norm = bits ? cv::NORM_HAMMING : cv::NORM_L2;
    std::vector<std::vector<cv::DMatch>> refF, refR, f, r;
    cv::BFMatcher(norm).knnMatch(q, t, refF, 2);
    cv::BFMatcher(norm).knnMatch(t, q, refR, 2);

    bool ok = true;
    pairmatch::PairResult pr = pairmatch::computePair(q, t, bits);
    pairmatch::toMatches(pr.forward, bits, f);
    pairmatch::toMatches(pr.reverse, bits, r);
    if (!sameMatches(f, refF)) { std::printf("DIFF forward %dx%d len=%d bits=%d mode=%d\n", N, M, len, bits, mode); ok = false; }
    if (!sameMatches(r, refR)) { std::printf("DIFF reverse %dx%d len=%d bits=%d mode=%d\n", N, M, len, bits, mode); ok = false; }

    // through the API and its cache: (q, t) computes and keeps the reverse; (t, q) finds it waiting
    pairmatch::waiting().clear();
    std::vector<std::vector<cv::DMatch>> a, b, c;
    pairmatch::knn2(q, t, norm, a);
    pairmatch::knn2(t, q, norm, b);
    if (!sameMatches(a, refF)) { std::printf("DIFF knn2 forward %dx%d len=%d bits=%d mode=%d\n", N, M, len, bits, mode); ok = false; }
    if (!sameMatches(b, refR)) { std::printf("DIFF knn2 cached %dx%d len=%d bits=%d mode=%d\n", N, M, len, bits, mode); ok = false; }
    // the answer was taken: asking again computes it again, the same
    pairmatch::knn2(t, q, norm, c);
    if (!sameMatches(c, refR)) { std::printf("DIFF knn2 recomputed %dx%d\n", N, M); ok = false; }
    // a different train set must not find the entry
    cv::Mat other = makeSet(M, len, bits, mode);
    std::vector<std::vector<cv::DMatch>> d, refD;
    pairmatch::knn2(q, other, norm, d);
    cv::BFMatcher(norm).knnMatch(q, other, refD, 2);
    if (!sameMatches(d, refD)) { std::printf("DIFF knn2 other set %dx%d\n", N, M); ok = false; }
    pairs += (long long)N * M;
    return ok;
}

int main(int argc, char **argv) {
    std::string mode = argc > 1 ? argv[1] : "sweep";
    if (mode == "sweep") {
        const int trials = argc > 2 ? atoi(argv[2]) : 400;
        const int sizes[] = {1, 2, 3, 5, 17, 64, 333, 1200};
        long long pairs = 0; bool ok = true;
        for (int t = 0; t < trials; ++t) {
            const int N = sizes[rng() % 8], M = sizes[rng() % 8];
            const bool bits = rng() & 1;
            const int lens[] = {128, 64, 3, 1};
            const int len = bits ? (rng() % 3 ? 61 : (int)(1 + rng() % 40)) : lens[rng() % 4];
            ok &= oneCase(N, M, len, bits, (int)(rng() % (bits ? 4 : 5)), pairs);
        }
        std::printf("%lld descriptor pairs, %s\n", pairs, ok ? "0 differ" : "DIFFERENCES");
        return ok ? 0 : 1;
    }
    if (mode == "time") {
        const int N = 8000, M = 8000;
        cv::Mat q = makeSet(N, 128, false, 0), t = makeSet(M, 128, false, 0);
        std::vector<std::vector<cv::DMatch>> a, b;
        double bestTwo = 1e9, bestPair = 1e9;
        for (int rep = 0; rep < 3; ++rep) {
            auto s = Clock::now();
            cv::BFMatcher(cv::NORM_L2).knnMatch(q, t, a, 2);
            cv::BFMatcher(cv::NORM_L2).knnMatch(t, q, b, 2);
            bestTwo = std::min(bestTwo, std::chrono::duration<double>(Clock::now() - s).count());
            s = Clock::now();
            pairmatch::PairResult pr = pairmatch::computePair(q, t, false);
            bestPair = std::min(bestPair, std::chrono::duration<double>(Clock::now() - s).count());
            (void)pr;
        }
        std::printf("8000 x 8000 SIFT-like: both directions through BFMatcher %.2f s, one pair pass %.2f s (%.2fx)\n",
                    bestTwo, bestPair, bestTwo / bestPair);
        return 0;
    }
    return 2;
}
