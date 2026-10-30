// MedianMerge.hpp — the sigma-clip median merge kernels behind every star-aligned and
// earth-aligned frame.  Included by ImageAligner.cpp, and by the differential harness that
// holds each kernel to the reference one bit for bit.
#pragma once

#include "CpuFeatures.hpp"

#include <opencv2/core.hpp>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <type_traits>
#include <vector>

// --- Sorting networks for median merge ---
#define CSWAP(a,b) do { if ((a)>(b)) { int _t=(a);(a)=(b);(b)=_t; } } while(0)

static inline void sort2(int* v) { CSWAP(v[0],v[1]); }
static inline void sort3(int* v) { CSWAP(v[0],v[1]); CSWAP(v[0],v[2]); CSWAP(v[1],v[2]); }
static inline void sort4(int* v) { CSWAP(v[0],v[1]); CSWAP(v[2],v[3]); CSWAP(v[0],v[2]); CSWAP(v[1],v[3]); CSWAP(v[1],v[2]); }
static inline void sort5(int* v) { CSWAP(v[0],v[1]); CSWAP(v[2],v[3]); CSWAP(v[0],v[2]); CSWAP(v[1],v[4]); CSWAP(v[0],v[1]); CSWAP(v[2],v[3]); CSWAP(v[1],v[2]); CSWAP(v[3],v[4]); CSWAP(v[2],v[3]); }

static inline void small_sort(int* v, int n) {
    switch (n) {
        case 1: break;
        case 2: sort2(v); break;
        case 3: sort3(v); break;
        case 4: sort4(v); break;
        case 5: sort5(v); break;
        default: std::sort(v, v + n); break;
    }
}

// One compare-exchange of a sorting network: put the smaller of the two slots in
// `a` and the larger in `b`.  A network is a fixed list of these, applied in
// order, and it sorts any input — which is why the block kernel below can run one
// network across a whole block of pixels at once without branching per pixel.
struct MergeComparator { int a, b; };

// Batcher's odd-even merge sort, the textbook recursive construction.  Only
// defined for a power-of-two width, which is why mergeSortNetwork sorts the
// largest power of two that fits and inserts the rest by hand.
static void oddEvenMergeNet(int lo, int n, int r, std::vector<MergeComparator> &out) {
    const int m = r * 2;
    if (m < n) {
        oddEvenMergeNet(lo, n, m, out);
        oddEvenMergeNet(lo + r, n, m, out);
        for (int i = lo + r; i + r < lo + n; i += m) out.push_back({i, i + r});
    } else {
        out.push_back({lo, lo + r});
    }
}

static void oddEvenSortNet(int lo, int n, std::vector<MergeComparator> &out) {
    if (n <= 1) return;
    const int m = n / 2;
    oddEvenSortNet(lo, m, out);
    oddEvenSortNet(lo + m, m, out);
    oddEvenMergeNet(lo, n, 1, out);
}

// A network that sorts `n` values ascending.  Batcher over the largest power of
// two <= n, then each leftover element bubbled down into place.
//
// Padding up to a power of two with sentinels is the more usual trick and it is
// much worse here: the two source counts star actually merges are 9 (base plus
// numberAlignedNeighborFrames) and 17 (base plus numberStaticNeighborFrames),
// and padding costs 63 and 191 comparators against 27 and 79 this way.
//
// Cheap enough to build per call — a few dozen push_backs against a band of a
// million-odd pixels — so it is not cached or preallocated anywhere.
static std::vector<MergeComparator> mergeSortNetwork(int n) {
    std::vector<MergeComparator> net;
    if (n < 2) return net;
    int p = 1;
    while ((p << 1) <= n) p <<= 1;
    oddEvenSortNet(0, p, net);
    for (int i = p; i < n; ++i)
        for (int j = i; j > 0; --j) net.push_back({j - 1, j});
    // Neither construction above can pair a slot with itself, but the block kernel
    // hands the two slots to the compiler as restrict pointers, so a comparator
    // that did would be a miscompile rather than a wrong answer.  Drop it here,
    // once per merge, instead of testing for it per pixel.
    net.erase(std::remove_if(net.begin(), net.end(),
                             [](const MergeComparator &c) { return c.a == c.b; }),
              net.end());
    return net;
}

template <typename T>
static inline T clamp_cast_int(int v) {
    if constexpr (std::is_same_v<T, uchar>) {
        return static_cast<uchar>(std::clamp(v, 0, 255));
    } else {
        return static_cast<uint16_t>(std::clamp(v, 0, 65535));
    }
}

// Pixel-channels a block handles at once — eight lanes of int32 is two SSE2 or
// NEON registers, and four of doubles — and the largest source count the block
// path will take.  A merge with more sources than that runs entirely on the
// scalar tail below, which is the code this kernel has always run.  See the
// kernel's own comment for why the width is 8.
static const int kMergeLanes = 8;
static const int kMergeMaxBlockSources = 64;

// How many of a merge's sources have no sample at a given pixel — one byte per
// pixel, shared by every channel, or nothing at all when every source covers the
// whole frame.
//
// This is what lets the kernel tell "the warp did not reach here" from "this pixel
// is black", and it is deliberately a count rather than a mask per source.  A
// source with no sample reads 0, the smallest value the type holds, so all of them
// land in the leading run of zeros once a pixel's samples are sorted.  Which of
// those zeros came from which source cannot matter to a kernel that only ever
// looks at values, so the count is everything: skip that many and what is left is
// exactly the sources that had something to say, real zeros included.
//
// One plane of counts rather than one mask per source is not a small saving at
// these sizes — 40MB against 683MB for a 17-source 42MP merge — and it stays
// resident through a streaming merge instead of being spilled and read back
// alongside every source.
struct CoverageMisses {
    const uint8_t *data = nullptr;
    size_t stride = 0;

    CoverageMisses() = default;
    explicit CoverageMisses(const cv::Mat &m)
      : data(m.empty() ? nullptr : m.ptr<uint8_t>()),
        stride(m.empty() ? 0 : m.step) {}

    // The same plane seen from row `y`, for a kernel running on a band of rows.
    CoverageMisses fromRow(int y) const {
        if (!data) return CoverageMisses();
        CoverageMisses ret;
        ret.data = data + (size_t)y * stride;
        ret.stride = stride;
        return ret;
    }

    const uint8_t *row(int y) const { return data ? data + (size_t)y * stride : nullptr; }
};

// Parallel over bands of rows, and within a row over blocks of kMergeLanes
// pixel-channels.
//
// The merge is the pipeline's largest single consumer of CPU at 42MP.  Two things
// make it so, measured per pixel-channel on real 9-source frames with the flags
// star ships (no -march, so SSE2 on Intel and NEON on Apple silicon): the sort
// was 194ns of a 304ns total, all of it std::sort mispredicting branches on nine
// elements, and the Welford recurrence below was most of the rest, latency-bound
// on a chain of nine double divisions.
//
// Both go away by doing kMergeLanes pixel-channels in lockstep instead of one at
// a time.  Consecutive pixel-channels are contiguous in every source, so the
// gather is a vector load; a comparator network sorts all the lanes with the same
// branchless min/max pairs; and the statistics run the identical scalar
// recurrence per lane, which the compiler puts in vector registers.  The
// divisions no longer wait on each other because eight independent chains
// interleave.
//
// Measured against the previous kernel, serially so the figures are core-seconds
// rather than whatever share of the machine a run happened to get: 3.7x at 9
// sources (33.9 -> 9.1 core-seconds per 42MP frame) and 4.0x at 17 (61.3 ->
// 15.2).  On the whole frame with the machine to itself, 2.94s -> 0.73s.  End to
// end, a 19-frame 12MP sequence through the release cli went from 1053 and 1059
// core-seconds on two runs to 752 and 838 — about a quarter of the entire
// pipeline's CPU — for byte-identical output.  Wall clock is not the instrument
// to read this with: the same four runs ranged 94-150s.
//
// kMergeLanes = 16 measured a few percent better again at both source counts,
// and slower than 8 once -march=native was in play, so this stays at the width
// that was never the worse of the two.  AVX512 adds nothing over the shipped
// SSE2 baseline here — the loop is bound by divide throughput, not width — so
// the Welford kernel gets no runtime CPU dispatch.  The exact-statistics kernel
// further down removes those divisions, which is what makes AVX2 pay, and that
// one is dispatched; see its comment.
//
// Bit-identical, by construction and then by measurement.  A comparator network
// computes the same total order std::sort does, so `blk` holds exactly the array
// `vals` held.  Every lane then evaluates the same IEEE double operations in the
// same order as the scalar code — lanes whose data starts later are carried
// along and their updates discarded by a select, never folded in — and IEEE
// division and square root are exactly rounded, so a vectorised lane and a
// scalar one cannot disagree.  Checked against the old kernel over full 42MP
// frames including the zero-covered edges, and over randomised inputs across
// source counts, depths, channel counts and both includeAll settings.
//
// Bands remain safe for the same reason as before: output pixel (y, xc) reads
// only column xc of row y of each source, there is no accumulator spanning rows,
// and nothing depends on the order bands are visited in.
//
// Worth knowing before tuning this: the vendored OpenCV selects the GCD backend at
// runtime (`getBuildInformation()` reports "Parallel framework: GCD", despite
// cvconfig.h defining HAVE_PTHREADS_PF and the archive exporting the pthreads entry
// points), and `cv::setNumThreads(N)` measurably does nothing for N > 1 — only N == 1
// takes effect.  So the worker count here cannot be bounded from Star; what bounds total
// threads is `numberOfFramesToProcessConcurrently`, which is why lowering it and
// parallelising this loop are one change and not two.

// Everything one band of rows needs, so that the kernels below can be plain functions
// (and so that one of them can be compiled for a wider instruction set than the rest of
// the library) instead of a lambda inside medianMergeTyped.
template <typename T>
struct MergeJob {
    cv::Mat *output = nullptr;
    const std::vector<cv::Mat> *mats = nullptr;
    double k = 0.0;
    bool includeAll = false;
    int rows = 0, cols = 0, ch = 1;
    CoverageMisses misses;
    const MergeComparator *net = nullptr;
    int netCount = 0;
};

// The kernel this file has always had: eight pixel-channels per block, the statistics a
// per-lane Welford recurrence in double.  It is the reference every other kernel here is
// held to, and the one that runs wherever the exact kernel below does not.
template <typename T>
static void mergeRowsWelford(const MergeJob<T> &job, int yStart, int yEnd) {
    cv::Mat &output = *job.output;
    const std::vector<cv::Mat> &mats = *job.mats;
    const double k = job.k;
    const bool includeAll = job.includeAll;
    const int ch = job.ch;
    const CoverageMisses misses = job.misses;
    const MergeComparator *netData = job.net;
    const int netCount = job.netCount;
    const int n = (int)mats.size();
    const int total = job.cols * ch;
    const bool blocked = n <= kMergeMaxBlockSources && total >= kMergeLanes;

    std::vector<int> vals(n);
    std::vector<const T*> rowPtrs(n);
    alignas(64) int blk[kMergeMaxBlockSources][kMergeLanes];

    for (int y = yStart; y < yEnd; ++y) {
        for (int i = 0; i < n; ++i) rowPtrs[i] = mats[i].ptr<T>(y);
        T* outRow = output.ptr<T>(y);
        // How many sources have no sample at each pixel of this row, or null
        // when they all cover it.  One entry per pixel, not per pixel-channel:
        // a warp either reached a pixel or it did not, whatever its colour.
        const uint8_t *missRow = misses.row(y);

        int xc = 0;

        if (blocked) {
            for (; xc + kMergeLanes <= total; xc += kMergeLanes) {
                for (int i = 0; i < n; ++i) {
                    const T *src = rowPtrs[i] + xc;
                    for (int l = 0; l < kMergeLanes; ++l) blk[i][l] = src[l];
                }

                // sort every lane, one comparator at a time.  The two slots a
                // comparator touches are always different, so restrict holds.
                for (int c = 0; c < netCount; ++c) {
                    int *__restrict lo = blk[netData[c].a];
                    int *__restrict hi = blk[netData[c].b];
                    for (int l = 0; l < kMergeLanes; ++l) {
                        const int x = lo[l], y2 = hi[l];
                        lo[l] = x < y2 ? x : y2;
                        hi[l] = x < y2 ? y2 : x;
                    }
                }

                if (includeAll) {
                    // With every source counted, minIndex is 0 and maxIndex is n
                    // whatever the statistics say, so the answer is the plain
                    // midpoint and the whole pass below is dead.
                    for (int l = 0; l < kMergeLanes; ++l)
                        outRow[xc + l] = clamp_cast_int<T>(blk[n / 2][l]);
                    continue;
                }

                // The leading `misses` entries are the sources with no sample
                // here — see the scalar path below.  Every one of them is a
                // zero, so they are exactly the front of the sorted block; any
                // zero past them is a pixel that really is black and counts.
                int minIndex[kMergeLanes], first[kMergeLanes];
                for (int l = 0; l < kMergeLanes; ++l) {
                    const int miss = missRow ? (int)missRow[(xc + l) / ch] : 0;
                    minIndex[l] = miss < n ? miss : n;
                    first[l] = miss < n ? miss : n - 1;
                }

                // Welford, per lane, from each lane's own `first`.  A lane that is
                // not started yet computes its update anyway and throws it away;
                // the divisor is floored at 1 so that idle arithmetic cannot
                // divide by zero.
                double mean[kMergeLanes] = {0.0}, M2[kMergeLanes] = {0.0};
                for (int i = 0; i < n; ++i) {
                    for (int l = 0; l < kMergeLanes; ++l) {
                        const double v = blk[i][l];
                        const double delta = v - mean[l];
                        const int count = i - first[l] + 1;
                        const double nextMean =
                          mean[l] + delta / (double)(count < 1 ? 1 : count);
                        const double nextM2 = M2[l] + delta * (v - nextMean);
                        const bool active = i >= first[l];
                        mean[l] = active ? nextMean : mean[l];
                        M2[l] = active ? nextM2 : M2[l];
                    }
                }

                double threshold[kMergeLanes];
                for (int l = 0; l < kMergeLanes; ++l)
                    threshold[l] =
                      mean[l] + k * std::sqrt(M2[l] / (double)(n - first[l]));

                // The scalar path walks up from `first` and stops at the first
                // value the threshold rejects.  The values are sorted, so the ones
                // it accepts are exactly a prefix, and counting them says where it
                // would have stopped.  An empty prefix — including the NaN case,
                // where every compare is false — leaves maxIndex at n, as there.
                int below[kMergeLanes] = {0};
                for (int i = 0; i < n; ++i)
                    for (int l = 0; l < kMergeLanes; ++l)
                        below[l] += (i >= first[l] &&
                                     (double)blk[i][l] < threshold[l]) ? 1 : 0;

                for (int l = 0; l < kMergeLanes; ++l) {
                    const int maxIndex = below[l] ? first[l] + below[l] - 1 : n;
                    int idx = (minIndex[l] + maxIndex) / 2;
                    if (idx >= n) idx = n - 1;
                    if (idx < first[l]) idx = first[l];
                    outRow[xc + l] = clamp_cast_int<T>(blk[idx][l]);
                }
            }
        }

        // Whatever the blocks did not cover: the last few pixel-channels of a row,
        // or every one of them when there are more sources than a block holds.
        for (; xc < total; ++xc) {
            for (int i = 0; i < n; ++i) vals[i] = rowPtrs[i][xc];
            small_sort(vals.data(), n);

            // How many sources have nothing to offer at this pixel.  warpInto
            // zeroes everything its warp does not cover, so near the frame edges
            // a neighbour simply has no sample here; those slots are not
            // observations and must stay out of both the statistics and the
            // selection below.
            //
            // Leaving them in the statistics is what put a black border down one
            // side of the first and last few frames of a sequence.  Those frames
            // have neighbours on one side only, so every warp uncovers the same
            // edge, and in that strip most of `vals` is zero.  The zeros dragged
            // the mean down and inflated the deviation until the base frame's own
            // real value looked like a bright outlier, `maxIndex` excluded it,
            // minIndex/maxIndex crossed over, and the midpoint landed back inside
            // the run of zeros — emitting black where exactly one source, the
            // base frame, had a perfectly good value.  Measured at the default
            // pixelThreshold of 1.2 and 8 aligned neighbours, that happened
            // wherever 3 or fewer of the 9 sources had data.
            //
            // This count is the answer to that, and counting the zeros here
            // instead was the wrong one.  A zero is not evidence of anything: a
            // black-clipped foreground reads exactly 0 in 99.8% of its
            // pixel-channels, so every real observation was discarded as
            // no-data and the merge returned the median of whatever light had
            // crossed the frame — printing cars into a static earth merge
            // brighter than any single frame had them, one per source frame they
            // appeared in.  Coverage is a property of the warp, not of the
            // brightness it lands, so it is carried alongside the sources rather
            // than inferred from them; see CoverageMisses.
            //
            // vals is sorted ascending and every no-data slot is a zero, so those
            // slots are exactly the first `minIndex` entries.  A zero after them
            // is a pixel that really is black, and is an observation like any
            // other.
            int minIndex = 0;
            if (!includeAll && missRow) {
                const int miss = (int)missRow[xc / ch];
                minIndex = miss < n ? miss : n;
            }
            // all zero: nothing covered this pixel, so 0 is the honest answer
            const int first = (minIndex < n) ? minIndex : n - 1;
            const int count = n - first;

            // Welford, deliberately kept.  Replacing it with exact int64 sum and
            // sum-of-squares was tried and reverted: measured 1.52x on the SERIAL
            // kernel (45.22s -> 29.76s on a 17-source 42MP merge), but once the
            // row loop above is parallel the kernel is ~3s and the difference
            // disappears into noise — 0.86x and 1.15x on two runs of the same
            // benchmark.  Against that it is not free: `threshold` feeds the
            // int-vs-double compare below, real data decides it at exactly zero
            // margin, and a flip selects a different source frame's sample
            // entirely rather than a neighbouring value.  Measured end to end,
            // 1 of 20 output frames changed, in 4 samples of 126.5M, but with a
            // max delta of 26368 of 65535.  No measurable speed for occasional
            // large isolated pixel changes is the wrong trade.
            double mean = 0.0, M2 = 0.0;
            for (int i = first; i < n; ++i) {
                double delta = vals[i] - mean;
                mean += delta / (i - first + 1);
                M2 += delta * (vals[i] - mean);
            }
            const double threshold = mean + k * std::sqrt(M2 / count);

            int maxIndex = n;
            if (!includeAll) {
                for (int z = first; z < n; ++z) {
                    if (vals[z] < threshold) maxIndex = z;
                    else break;
                }
            }

            int idx = (minIndex + maxIndex) / 2;
            if (idx >= n) idx = n - 1;
            // never fall back into the no-data zeros
            if (idx < first) idx = first;
            outRow[xc] = clamp_cast_int<T>(vals[idx]);
        }
    }
}

// --- Exact-statistics block kernels (x86-64, AVX2) -------------------------------
//
// The Welford kernel above spends most of its time in a chain of double divisions per
// source per lane, and divide throughput does not improve with vector width, so the
// same code is no faster on AVX2 than on SSE2.  These kernels reach the same decision
// without them.
//
// Every sample is below 2^16, so over the `c` counted sources of a lane
//
//     S = sum v      Q = sum v*v      D = c*Q - S*S
//
// are integers below 2^53 and exact in double, whatever order they are added in.  The
// Welford threshold, mean + k*sqrt(M2/c), is algebraically (S + k*sqrt(D))/c =: t, and
// what the kernel needs from it is only how many of the sorted samples lie below it.
// The samples are integers, so t is computed to within a few ulps (two correctly
// rounded operations and a division) and that count is the number of samples <= some
// integer: ceil(t - band) - 1 when no integer lies within `band` of t.  Welford's own
// rounding is a few ulps of t as well, so the two cannot disagree about a sample that is
// not within a hair of the threshold, and "within a hair" is made generous: band =
// 1e-6 * (1 + |t|), a hundred million times what the two roundings add up to.
//
// Lanes with a sample inside the band are not decided here.  They are redone with the
// Welford recurrence exactly as the Welford kernel does it, one lane at a time, so the
// answer is its answer by construction.  That is a few lanes in 100,000 of real frames.
// And a lane whose counted values are all equal needs no statistics at all: whatever the
// threshold, the selected value is that value.
//
// Why a band and not plain integer arithmetic: replacing Welford with exact int64 sums
// *without* the fallback was tried and reverted, and one output frame of twenty changed,
// in 4 samples of 126.5M, by up to 26368 of 65535 — a sample sitting on the threshold at
// zero margin, where a one-ulp difference selects a different source frame's value.
// Those are exactly the lanes the band hands back.
//
// What it buys is only there with a wide enough vector unit.  For 16-bit data and 2 to
// 17 sources (9 and 17 are what star merges) the whole block lives in registers: the
// sort is a compile-time sorting network over 16 pixel-channels per register, the
// statistics run four doubles at a time, and the counting runs in 16-bit lanes against
// the integer bounds above.  Everything else, 8-bit data, other source counts, and the
// blocks near a frame edge where some source has no sample, runs the same decision
// through plain loops the compiler vectorises.  All of it is compiled for AVX2 and
// chosen at run time; where there is no AVX2 the Welford kernel above runs.
//
// The k the exact kernels accept is 0 to 1e6.  The band argument needs Welford's
// threshold to be accurate to a few parts in 1e15 *relative to itself*, which holds when
// mean and k*sd are both non-negative; a negative k can cancel them and does not.

#ifdef STAR_X86_AVX2_KERNELS
#define STAR_MERGE_HAS_AVX2_KERNEL 1
#endif

#ifdef STAR_MERGE_HAS_AVX2_KERNEL

static const int kExactLanes = 16;

// One lane through the Welford recurrence, from sorted column `l` of blk.  This is the
// scalar path of the Welford kernel, operation for operation.
template <typename T>
STAR_AVX2_INLINE T welfordLane(const T (&blk)[kMergeMaxBlockSources][kExactLanes],
                               int l, int n, int first, int minIndex, double k)
{
    const int count = n - first;
    double mean = 0.0, M2 = 0.0;
    for (int i = first; i < n; ++i) {
        const double v = (double)blk[i][l];
        const double delta = v - mean;
        mean += delta / (i - first + 1);
        M2 += delta * (v - mean);
    }
    const double threshold = mean + k * std::sqrt(M2 / count);
    int maxIndex = n;
    for (int z = first; z < n; ++z) {
        if ((double)blk[z][l] < threshold) maxIndex = z;
        else break;
    }
    int idx = (minIndex + maxIndex) / 2;
    if (idx >= n) idx = n - 1;
    if (idx < first) idx = first;
    return blk[idx][l];
}

// Which sources have no sample in the 16 pixel-channels starting at xc, as the
// per-lane `first` and `minIndex` the Welford kernel derives.  False, and nothing
// written, when every source covers all of them — the common case.
STAR_AVX2_INLINE bool blockMisses(const uint8_t *missRow, int xc, int ch, int n,
                                  int *first, int *minIndex)
{
    if (!missRow) return false;
    const int p0 = xc / ch, p1 = (xc + kExactLanes - 1) / ch;
    uint8_t any = 0;
    for (int p = p0; p <= p1; ++p) any |= missRow[p];
    if (!any) return false;
    int p = p0, r = xc - p0 * ch;
    for (int l = 0; l < kExactLanes; ++l) {
        const int miss = (int)missRow[p];
        minIndex[l] = miss < n ? miss : n;
        first[l] = miss < n ? miss : n - 1;
        if (++r == ch) { r = 0; ++p; }
    }
    return true;
}

// The decision over a block held in memory, written as plain loops.  `Masked` is a block
// in which some lane has sources with no sample; otherwise every lane counts all n and
// no mask is needed.  Same statistics, band and fallback as the register kernel below.
template <typename T, bool Masked>
STAR_AVX2_INLINE void
mergeExactBlock(const T (&blk)[kMergeMaxBlockSources][kExactLanes], int n, double k,
                const int *first, const int *minIndex, T *out)
{
    double S[kExactLanes], Q[kExactLanes], cnt[kExactLanes];
    for (int l = 0; l < kExactLanes; ++l) {
        S[l] = 0.0; Q[l] = 0.0;
        cnt[l] = Masked ? (double)(n - first[l]) : (double)n;
    }
    for (int i = 0; i < n; ++i) {
        for (int l = 0; l < kExactLanes; ++l) {
            double v = (double)blk[i][l];
            if constexpr (Masked) v = (i >= first[l]) ? v : 0.0;
            S[l] += v;
            Q[l] += v * v;
        }
    }

    // In "c times the value" units, where the samples are exact integers: a sample is
    // below the threshold exactly when c*v - S < u.
    double lo[kExactLanes], hi[kExactLanes];
    for (int l = 0; l < kExactLanes; ++l) {
        const double D = cnt[l] * Q[l] - S[l] * S[l];
        const double u = k * std::sqrt(D);
        const double band = 1e-6 * (cnt[l] + std::fabs(S[l] + u));
        lo[l] = u - band;
        hi[l] = u + band;
    }

    // `below` counts the sources certainly under the threshold, `notAbove` those not
    // certainly over it.  The values are sorted, so the first is a prefix, and the two
    // differ exactly when some counted value sits in the band.
    long long below[kExactLanes], notAbove[kExactLanes];
    for (int l = 0; l < kExactLanes; ++l) { below[l] = 0; notAbove[l] = 0; }
    for (int i = 0; i < n; ++i) {
        for (int l = 0; l < kExactLanes; ++l) {
            const double w = cnt[l] * (double)blk[i][l] - S[l];
            const bool counted = Masked ? (i >= first[l]) : true;
            below[l] += (counted && w < lo[l]) ? 1 : 0;
            notAbove[l] += (counted && w <= hi[l]) ? 1 : 0;
        }
    }

    T pick[kExactLanes];
    int needsWelford = 0;
    for (int l = 0; l < kExactLanes; ++l) {
        const int f = Masked ? first[l] : 0;
        const int mi = Masked ? minIndex[l] : 0;
        const bool allEqual = blk[n - 1][l] == blk[f][l];
        const bool tie = below[l] != notAbove[l];
        const int maxIndex = below[l] ? f + (int)below[l] - 1 : n;
        int idx = (mi + maxIndex) / 2;
        if (idx >= n) idx = n - 1;
        if (idx < f) idx = f;
        pick[l] = (T)idx;
        needsWelford |= (tie && !allEqual) ? (1 << l) : 0;
    }

    // out[l] = blk[pick[l]][l], as a select so it stays in vector registers.
    for (int l = 0; l < kExactLanes; ++l) out[l] = 0;
    for (int i = 0; i < n; ++i)
        for (int l = 0; l < kExactLanes; ++l)
            out[l] = (pick[l] == (T)i) ? blk[i][l] : out[l];

    if (!needsWelford) return;
    for (int l = 0; l < kExactLanes; ++l) {
        if (!(needsWelford & (1 << l))) continue;
        out[l] = welfordLane<T>(blk, l, n, Masked ? first[l] : 0, Masked ? minIndex[l] : 0, k);
    }
}

// What the blocks did not cover: the last few pixel-channels of a row.  The scalar path of
// the Welford kernel, unchanged.
template <typename T>
STAR_AVX2_INLINE void
exactScalarTail(const T *const *rowPtrs, std::vector<int> &vals, int n, int ch, int xc,
                int total, bool includeAll, double k, const uint8_t *missRow, T *outRow)
{
    for (; xc < total; ++xc) {
        for (int i = 0; i < n; ++i) vals[i] = rowPtrs[i][xc];
        small_sort(vals.data(), n);

        int minIndex = 0;
        if (!includeAll && missRow) {
            const int miss = (int)missRow[xc / ch];
            minIndex = miss < n ? miss : n;
        }
        const int first = (minIndex < n) ? minIndex : n - 1;
        const int count = n - first;

        double mean = 0.0, M2 = 0.0;
        for (int i = first; i < n; ++i) {
            double delta = vals[i] - mean;
            mean += delta / (i - first + 1);
            M2 += delta * (vals[i] - mean);
        }
        const double threshold = mean + k * std::sqrt(M2 / count);

        int maxIndex = n;
        if (!includeAll) {
            for (int z = first; z < n; ++z) {
                if (vals[z] < threshold) maxIndex = z;
                else break;
            }
        }

        int idx = (minIndex + maxIndex) / 2;
        if (idx >= n) idx = n - 1;
        if (idx < first) idx = first;
        outRow[xc] = clamp_cast_int<T>(vals[idx]);
    }
}

// The block kernel for any depth and source count, over a block copied into memory.
template <typename T>
STAR_AVX2 static void mergeRowsExactGeneric(const MergeJob<T> &job, int yStart, int yEnd)
{
    cv::Mat &output = *job.output;
    const std::vector<cv::Mat> &mats = *job.mats;
    const double k = job.k;
    const bool includeAll = job.includeAll;
    const int ch = job.ch;
    const MergeComparator *netData = job.net;
    const int netCount = job.netCount;
    const int n = (int)mats.size();
    const int total = job.cols * ch;
    const bool blocked = n <= kMergeMaxBlockSources && total >= kExactLanes;

    std::vector<int> vals(n);
    std::vector<const T*> rowPtrs(n);
    alignas(64) T blk[kMergeMaxBlockSources][kExactLanes];

    for (int y = yStart; y < yEnd; ++y) {
        for (int i = 0; i < n; ++i) rowPtrs[i] = mats[i].ptr<T>(y);
        T *outRow = output.ptr<T>(y);
        const uint8_t *missRow = job.misses.row(y);

        int xc = 0;
        if (blocked) {
            for (; xc + kExactLanes <= total; xc += kExactLanes) {
                for (int i = 0; i < n; ++i)
                    std::memcpy(blk[i], rowPtrs[i] + xc, sizeof(T) * kExactLanes);

                for (int c = 0; c < netCount; ++c) {
                    T *__restrict lo = blk[netData[c].a];
                    T *__restrict hi = blk[netData[c].b];
                    for (int l = 0; l < kExactLanes; ++l) {
                        const T x = lo[l], y2 = hi[l];
                        lo[l] = x < y2 ? x : y2;
                        hi[l] = x < y2 ? y2 : x;
                    }
                }

                if (includeAll) {
                    std::memcpy(outRow + xc, blk[n / 2], sizeof(T) * kExactLanes);
                    continue;
                }

                int first[kExactLanes], minIndex[kExactLanes];
                if (!blockMisses(missRow, xc, ch, n, first, minIndex))
                    mergeExactBlock<T, false>(blk, n, k, nullptr, nullptr, outRow + xc);
                else
                    mergeExactBlock<T, true>(blk, n, k, first, minIndex, outRow + xc);
            }
        }
        exactScalarTail<T>(rowPtrs.data(), vals, n, ch, xc, total, includeAll, k, missRow, outRow);
    }
}

// --- the register kernel, 16-bit data ---

// A sorting network as data a compile-time loop can unroll: the same construction as
// mergeSortNetwork above (Batcher over the largest power of two that fits, then each
// leftover bubbled into place), as constexpr so the comparators are constants and the N
// registers of a block are never indexed at run time.
struct ConstNet {
    MergeComparator c[96] = {};
    int count = 0;
};
constexpr void netPush(ConstNet &o, int a, int b) { o.c[o.count++] = {a, b}; }
constexpr void netMerge(ConstNet &o, int lo, int n, int r) {
    const int m = r * 2;
    if (m < n) {
        netMerge(o, lo, n, m);
        netMerge(o, lo + r, n, m);
        for (int i = lo + r; i + r < lo + n; i += m) netPush(o, i, i + r);
    } else {
        netPush(o, lo, lo + r);
    }
}
constexpr void netSort(ConstNet &o, int lo, int n) {
    if (n <= 1) return;
    const int m = n / 2;
    netSort(o, lo, m);
    netSort(o, lo + m, m);
    netMerge(o, lo, n, 1);
}
constexpr ConstNet makeNet(int n) {
    ConstNet o;
    if (n < 2) return o;
    int p = 1;
    while ((p << 1) <= n) p <<= 1;
    netSort(o, 0, p);
    for (int i = p; i < n; ++i)
        for (int j = i; j > 0; --j) netPush(o, j - 1, j);
    return o;
}
template <int N> inline constexpr ConstNet kNet = makeNet(N);

template <int N, int C>
STAR_AVX2_INLINE void applyNet(__m256i (&v)[N]) {
    if constexpr (C < kNet<N>.count) {
        constexpr int a = kNet<N>.c[C].a, b = kNet<N>.c[C].b;
        const __m256i lo = _mm256_min_epu16(v[a], v[b]);
        const __m256i hi = _mm256_max_epu16(v[a], v[b]);
        v[a] = lo;
        v[b] = hi;
        applyNet<N, C + 1>(v);
    }
}

// Four groups of four int32 bounds to 16 uint16 lanes in memory order, with -1 (a bound
// below every sample) saturated to 0 and flagged in `none`.  The packs work within each
// 128-bit half, which leaves the groups as 0 2 1 3.
STAR_AVX2_INLINE void narrowBounds(const __m128i (&g)[4], __m256i &value, __m256i &none)
{
    const __m256i lo = _mm256_set_m128i(g[1], g[0]), hi = _mm256_set_m128i(g[3], g[2]);
    value = _mm256_permute4x64_epi64(_mm256_packus_epi32(lo, hi), 0xD8);
    none = _mm256_permute4x64_epi64(
        _mm256_packs_epi32(_mm256_srai_epi32(lo, 31), _mm256_srai_epi32(hi, 31)), 0xD8);
}

// The decision for 16 pixel-channels, none of which has a source without a sample.
// Writes the picked values and returns the movemask of the lanes (two bits each) that
// have a sample in the band and so need the Welford recurrence.
template <int N>
STAR_AVX2_INLINE unsigned decideBlock16(const __m256i (&v)[N], double k, uint16_t *out)
{
    __m256d S[4], Q[4];
    for (int g = 0; g < 4; ++g) { S[g] = _mm256_setzero_pd(); Q[g] = _mm256_setzero_pd(); }
#pragma unroll
    for (int i = 0; i < N; ++i) {
        const __m128i lo = _mm256_castsi256_si128(v[i]);
        const __m128i hi = _mm256_extracti128_si256(v[i], 1);
        const __m256d d[4] = {
            _mm256_cvtepi32_pd(_mm_cvtepu16_epi32(lo)),
            _mm256_cvtepi32_pd(_mm_cvtepu16_epi32(_mm_srli_si128(lo, 8))),
            _mm256_cvtepi32_pd(_mm_cvtepu16_epi32(hi)),
            _mm256_cvtepi32_pd(_mm_cvtepu16_epi32(_mm_srli_si128(hi, 8))),
        };
        for (int g = 0; g < 4; ++g) {
            S[g] = _mm256_add_pd(S[g], d[g]);
            Q[g] = _mm256_add_pd(Q[g], _mm256_mul_pd(d[g], d[g]));
        }
    }

    const __m256d vN = _mm256_set1_pd((double)N), vk = _mm256_set1_pd(k);
    const __m256d one = _mm256_set1_pd(1.0), eps = _mm256_set1_pd(1e-6);
    const __m256d top = _mm256_set1_pd(65535.0), bottom = _mm256_set1_pd(-1.0);
    const __m256d absMask = _mm256_castsi256_pd(_mm256_set1_epi64x(0x7fffffffffffffffLL));
    __m128i yA[4], yB[4];
    for (int g = 0; g < 4; ++g) {
        const __m256d D = _mm256_sub_pd(_mm256_mul_pd(vN, Q[g]), _mm256_mul_pd(S[g], S[g]));
        const __m256d u = _mm256_mul_pd(vk, _mm256_sqrt_pd(D));
        const __m256d t = _mm256_div_pd(_mm256_add_pd(S[g], u), vN);
        const __m256d band = _mm256_mul_pd(eps, _mm256_add_pd(one, _mm256_and_pd(t, absMask)));
        // Samples <= y are the ones certainly below (yA) and the ones not certainly
        // above (yB) the threshold; clamped to the range a sample can take, with -1
        // meaning none.
        __m256d a = _mm256_sub_pd(_mm256_ceil_pd(_mm256_sub_pd(t, band)), one);
        __m256d b = _mm256_floor_pd(_mm256_add_pd(t, band));
        a = _mm256_min_pd(_mm256_max_pd(a, bottom), top);
        b = _mm256_min_pd(_mm256_max_pd(b, bottom), top);
        yA[g] = _mm256_cvtpd_epi32(a);
        yB[g] = _mm256_cvtpd_epi32(b);
    }

    __m256i yA16, noneA, yB16, noneB;
    narrowBounds(yA, yA16, noneA);
    narrowBounds(yB, yB16, noneB);

    __m256i cA = _mm256_setzero_si256(), cB = _mm256_setzero_si256();
#pragma unroll
    for (int i = 0; i < N; ++i) {
        cA = _mm256_sub_epi16(cA, _mm256_cmpeq_epi16(_mm256_min_epu16(v[i], yA16), v[i]));
        cB = _mm256_sub_epi16(cB, _mm256_cmpeq_epi16(_mm256_min_epu16(v[i], yB16), v[i]));
    }
    cA = _mm256_andnot_si256(noneA, cA);
    cB = _mm256_andnot_si256(noneB, cB);

    const __m256i settled = _mm256_or_si256(_mm256_cmpeq_epi16(cA, cB),
                                            _mm256_cmpeq_epi16(v[0], v[N - 1]));
    const unsigned needsWelford =
        ~(unsigned)_mm256_movemask_epi8(settled);

    // maxIndex = below ? below - 1 : N, and the midpoint of 0 and that.
    const __m256i maxIndex = _mm256_blendv_epi8(_mm256_sub_epi16(cA, _mm256_set1_epi16(1)),
                                                _mm256_set1_epi16((short)N),
                                                _mm256_cmpeq_epi16(cA, _mm256_setzero_si256()));
    const __m256i idx = _mm256_srli_epi16(maxIndex, 1);
    __m256i res = _mm256_setzero_si256();
#pragma unroll
    for (int i = 0; i < N; ++i)
        res = _mm256_blendv_epi8(res, v[i], _mm256_cmpeq_epi16(idx, _mm256_set1_epi16((short)i)));
    _mm256_storeu_si256((__m256i *)out, res);
    return needsWelford;
}

template <int N>
STAR_AVX2 static void mergeRowsExactVec(const MergeJob<uint16_t> &job, int yStart, int yEnd)
{
    cv::Mat &output = *job.output;
    const std::vector<cv::Mat> &mats = *job.mats;
    const double k = job.k;
    const bool includeAll = job.includeAll;
    const int ch = job.ch;
    const int total = job.cols * ch;

    std::vector<int> vals(N);
    const uint16_t *rp[N];
    alignas(64) uint16_t spill[kMergeMaxBlockSources][kExactLanes];

    for (int y = yStart; y < yEnd; ++y) {
        for (int i = 0; i < N; ++i) rp[i] = mats[i].ptr<uint16_t>(y);
        uint16_t *outRow = output.ptr<uint16_t>(y);
        const uint8_t *missRow = job.misses.row(y);

        int xc = 0;
        for (; xc + kExactLanes <= total; xc += kExactLanes) {
            __m256i v[N];
#pragma unroll
            for (int i = 0; i < N; ++i)
                v[i] = _mm256_loadu_si256((const __m256i *)(rp[i] + xc));
            applyNet<N, 0>(v);

            if (includeAll) {
                _mm256_storeu_si256((__m256i *)(outRow + xc), v[N / 2]);
                continue;
            }

            int first[kExactLanes], minIndex[kExactLanes];
            const bool anyMiss = blockMisses(missRow, xc, ch, N, first, minIndex);
            unsigned needsWelford = 0;
            if (!anyMiss) {
                needsWelford = decideBlock16<N>(v, k, outRow + xc);
                if (!needsWelford) continue;
            }
#pragma unroll
            for (int i = 0; i < N; ++i) _mm256_store_si256((__m256i *)spill[i], v[i]);
            if (anyMiss) {
                mergeExactBlock<uint16_t, true>(spill, N, k, first, minIndex, outRow + xc);
            } else {
                for (int l = 0; l < kExactLanes; ++l)
                    if (needsWelford & (1u << (2 * l)))
                        outRow[xc + l] = welfordLane<uint16_t>(spill, l, N, 0, 0, k);
            }
        }
        exactScalarTail<uint16_t>(rp, vals, N, ch, xc, total, includeAll, k, missRow, outRow);
    }
}

// The exact kernel for this job: the register kernel for 16-bit data with 2 to 17
// sources, the loop version for everything else.
template <typename T>
static void mergeRowsExactAvx2(const MergeJob<T> &job, int yStart, int yEnd)
{
    if constexpr (std::is_same_v<T, uint16_t>) {
        if (job.cols * job.ch >= kExactLanes) {
#define STAR_MERGE_VEC_CASE(N) case N: mergeRowsExactVec<N>(job, yStart, yEnd); return;
            switch ((int)job.mats->size()) {
                STAR_MERGE_VEC_CASE(2)  STAR_MERGE_VEC_CASE(3)  STAR_MERGE_VEC_CASE(4)
                STAR_MERGE_VEC_CASE(5)  STAR_MERGE_VEC_CASE(6)  STAR_MERGE_VEC_CASE(7)
                STAR_MERGE_VEC_CASE(8)  STAR_MERGE_VEC_CASE(9)  STAR_MERGE_VEC_CASE(10)
                STAR_MERGE_VEC_CASE(11) STAR_MERGE_VEC_CASE(12) STAR_MERGE_VEC_CASE(13)
                STAR_MERGE_VEC_CASE(14) STAR_MERGE_VEC_CASE(15) STAR_MERGE_VEC_CASE(16)
                STAR_MERGE_VEC_CASE(17)
                default: break;
            }
#undef STAR_MERGE_VEC_CASE
        }
    }
    mergeRowsExactGeneric<T>(job, yStart, yEnd);
}

#endif  // STAR_MERGE_HAS_AVX2_KERNEL

// --- Choosing a kernel ------------------------------------------------------------

enum class MergeKernel { Welford, ExactAvx2 };

// Test hook (see ia_debug_set_median_kernel): 1 forces the Welford reference kernel so a
// test can hold the exact one to it in a single process.  0 is the normal choice.
inline std::atomic<int> gMedianKernelOverride{0};

// `STAR_MEDIAN_KERNEL=welford` forces the reference kernel, for an A/B of one against the
// other on a real run.  Read once.
static MergeKernel mergeKernelForThisMachine() {
    static const MergeKernel chosen = [] {
        const char *env = std::getenv("STAR_MEDIAN_KERNEL");
        if (env && std::strcmp(env, "welford") == 0) return MergeKernel::Welford;
#ifdef STAR_MERGE_HAS_AVX2_KERNEL
        if (cpuRunsAvx2()) return MergeKernel::ExactAvx2;
#endif
        return MergeKernel::Welford;
    }();
    return gMedianKernelOverride.load(std::memory_order_relaxed) == 1 ? MergeKernel::Welford
                                                                      : chosen;
}

#ifdef STAR_MERGE_HAS_AVX2_KERNEL
// The exact kernels' band argument needs k in the range given in their comment; outside
// it, or NaN, the Welford kernel is the one that defines what the answer is.
static bool exactKernelAccepts(double k) { return k >= 0.0 && k <= 1e6; }
#endif

template <typename T>
static void medianMergeTyped(cv::Mat &output, const std::vector<cv::Mat>& mats,
                             double k, bool includeAll, int rows, int cols, int ch,
                             CoverageMisses misses = CoverageMisses()) {
    const int n = (int)mats.size();
    if (n <= 0) return;

    const std::vector<MergeComparator> net = mergeSortNetwork(n);
    MergeJob<T> job;
    job.output = &output;
    job.mats = &mats;
    job.k = k;
    job.includeAll = includeAll;
    job.rows = rows;
    job.cols = cols;
    job.ch = ch;
    job.misses = misses;
    job.net = net.data();
    job.netCount = (int)net.size();

#ifdef STAR_MERGE_HAS_AVX2_KERNEL
    if (mergeKernelForThisMachine() == MergeKernel::ExactAvx2 && exactKernelAccepts(k)) {
        cv::parallel_for_(cv::Range(0, rows), [&](const cv::Range &band) {
            mergeRowsExactAvx2<T>(job, band.start, band.end);
        });
        return;
    }
#endif
    cv::parallel_for_(cv::Range(0, rows), [&](const cv::Range &band) {
        mergeRowsWelford<T>(job, band.start, band.end);
    });
}
