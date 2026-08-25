// ImageAligner.cpp — Pure C++ implementation of image alignment operations
#include "ImageAligner.h"
#include "ImageCache_C.h"
#include "MatWrapper.h"
#include "MatWrapperImpl.hpp"
#include "OCVFeatureSetImpl.hpp"
#include "logging_impl.hpp"

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/features2d.hpp>
#include <opencv2/calib3d.hpp>

#include <vector>
#include <algorithm>
#include <stdexcept>
#include <string>
#include <iostream>
#include <cstring>
#include <cstdio>
#include <atomic>
#include <memory>
#include <filesystem>
#include <system_error>
#include <thread>
#include <queue>
#include <mutex>
#include <condition_variable>

// Shares the buffer of a freshly produced cv::Mat the caller is about to drop.
// Never pass a live wrapper's mat here — use the deep constructor for that.
static MatWrapperRef wrap(const cv::Mat& mat) {
    return new MatWrapperImpl(MatWrapperImpl::Adopt{}, mat);
}

static cv::Mat ensure8U(const cv::Mat& input) {
    if (input.depth() == CV_8U) return input;
    cv::Mat output;
    double minVal, maxVal;
    cv::minMaxLoc(input, &minVal, &maxVal);
    if (minVal == maxVal) {
        output = cv::Mat::zeros(input.size(), CV_MAKETYPE(CV_8U, input.channels()));
    } else {
        input.convertTo(output, CV_MAKETYPE(CV_8U, input.channels()),
                        255.0 / (maxVal - minVal),
                        -minVal * 255.0 / (maxVal - minVal));
    }
    return output;
}

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
// there is no reason to build runtime CPU dispatch for it.
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
template <typename T>
static void medianMergeTyped(cv::Mat &output, const std::vector<cv::Mat>& mats,
                             double k, bool includeAll, int rows, int cols, int ch) {
    const int n = (int)mats.size();
    if (n <= 0) return;

    const int total = cols * ch;
    const std::vector<MergeComparator> net = mergeSortNetwork(n);
    const MergeComparator *netData = net.data();
    const int netCount = (int)net.size();
    const bool blocked = n <= kMergeMaxBlockSources && total >= kMergeLanes;

    cv::parallel_for_(cv::Range(0, rows), [&](const cv::Range &band) {
        std::vector<int> vals(n);
        std::vector<const T*> rowPtrs(n);
        alignas(64) int blk[kMergeMaxBlockSources][kMergeLanes];

        for (int y = band.start; y < band.end; ++y) {
            for (int i = 0; i < n; ++i) rowPtrs[i] = mats[i].ptr<T>(y);
            T* outRow = output.ptr<T>(y);

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

                    // Leading zeros are "no source data here" — see the scalar path
                    // below for what happens when they are counted as observations.
                    int minIndex[kMergeLanes], first[kMergeLanes];
                    for (int l = 0; l < kMergeLanes; ++l) {
                        int zeros = 0;
                        for (int i = 0; i < n; ++i) zeros += blk[i][l] == 0 ? 1 : 0;
                        minIndex[l] = zeros;
                        first[l] = zeros < n ? zeros : n - 1;
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

                // vals is sorted ascending, so any zeros are leading.  A zero means
                // "no source data here": warpInto zeroes everything its warp does not
                // cover, so near the frame edges a neighbour simply has no sample to
                // offer.  Those slots are not observations and must stay out of both
                // the statistics and the selection below.
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
                int minIndex = 0;
                if (!includeAll) {
                    while (minIndex < n && vals[minIndex] == 0) ++minIndex;
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
    });
}

static MatWrapperRef medianImageFromMats(const std::vector<cv::Mat>& mats,
                                          double k, bool includeAll) {
    if (mats.empty()) return wrap(cv::Mat());

    const cv::Mat& first = mats[0];
    int rows = first.rows, cols = first.cols, ch = first.channels(), depth = first.depth();

    for (size_t i = 1; i < mats.size(); ++i) {
        if (mats[i].rows != rows || mats[i].cols != cols || mats[i].type() != first.type())
            return wrap(cv::Mat());
    }

    cv::Mat output(rows, cols, first.type());
    if (depth == CV_8U) medianMergeTyped<uchar>(output, mats, k, includeAll, rows, cols, ch);
    else if (depth == CV_16U) medianMergeTyped<uint16_t>(output, mats, k, includeAll, rows, cols, ch);
    else return wrap(cv::Mat());

    return wrap(output);
}

// --- Loading merge sources concurrently -------------------------------------
//
// A merge does nothing but load its sources: 9 originals for a star-aligned build,
// 17 for a static-earth one, and no other work reads a file.  Each source was
// decoded and warped before the next one started, and a decode is single-threaded,
// so the loop held one core while the rest of the machine waited on it.
//
// Measured on a 42MP 8-neighbour set, load and warp only, best of two runs each:
//
//     workers   wall          core-seconds   peak RSS
//     1         12.2 - 13.9s  45.7 - 47.1    2.13 GB
//     2         10.3 - 10.6s  35.0 - 38.8    2.36 GB
//     4          7.7 -  9.6s  29.6 - 32.8    2.83 GB
//     6          8.2 -  9.6s  29.3 - 30.1    3.07 GB
//     8          6.4 - 12.2s  36.5 - 42.6    3.78 GB
//
// Core-seconds bottom out at 4 to 6 and climb again at 8, because
// `warpPerspective` is already internally parallel — measured 15x to 19x on 36
// threads for a single call — so past that the workers are only competing with
// each other.  Four is the default: at the bottom of that curve and the cheapest
// of the options there in memory.
//
// What makes this safe for the output is not the ordering below: medianMergeTyped
// sorts each pixel's samples before it looks at them, so which source arrived
// first cannot change what it decides.  What could change it is losing or
// duplicating a source, which is what the slots are for — each worker fills its
// own and nothing is appended from a thread.
//
// The order is preserved anyway, collected in index order once the workers are
// done, so the sequence handed to the kernel, the warp count and the log lines do
// not depend on how the threads were scheduled.  A merge that reads the same
// whatever the machine was doing is worth more than the few lines it costs, and it
// means this does not quietly rest on a property of today's kernel.
//
// Only the all-resident paths use this.  The streaming paths exist to hold one
// source at a time; N workers in flight would hold N of them, which is the thing
// streaming is for.
namespace {

// One merge source, as its loader left it.  `present` rather than `mat.empty()`
// so that "nothing to merge here" never depends on what an empty Mat means.
struct MergeSource {
    cv::Mat mat;
    bool present = false;
    std::string note;      // logged by the caller, in source order
};

// Runs body(i) for every i in [0, count), on at most `concurrency` threads.
// A body that throws loses its source rather than the process: nothing may escape
// a std::thread, and one unreadable neighbour is not worth aborting a merge over.
// That one line does go to the log from the worker, unlike the routine notes the
// caller collects — an exception is rare enough to be worth reading interleaved,
// and losing it to keep the log tidy would be the wrong trade.
template <typename Body>
static void forEachMergeSource(int count, int concurrency, Body &&body) {
    if (count <= 0) return;
    const int workers = std::max(1, std::min(concurrency, count));

    auto guarded = [&body](int i) {
        try { body(i); }
        catch (const std::exception &e) { Log_e("merge source %d: %s", i, e.what()); }
        catch (...) { Log_e("merge source %d: unknown exception", i); }
    };

    if (workers == 1) {
        for (int i = 0; i < count; ++i) guarded(i);
        return;
    }

    std::atomic<int> next{0};
    std::vector<std::thread> pool;
    pool.reserve((size_t)workers);
    for (int w = 0; w < workers; ++w) {
        pool.emplace_back([&] {
            for (int i = next.fetch_add(1); i < count; i = next.fetch_add(1)) guarded(i);
        });
    }
    for (auto &t : pool) t.join();
}

} // namespace

// --- Streaming median merge ------------------------------------------------
//
// medianMergeTyped only ever needs row y of every input, so the whole set does
// not have to be resident.  A source is handed to MergeSpiller one at a time,
// written to a raw scratch file and released immediately; the merge then reads
// one band of rows back from each scratch file per iteration.
//
// Peak memory becomes (sources x bandRows x rowBytes) + the output frame rather
// than (sources x frameBytes) + the output frame.  At 42MP with 17 sources that
// is roughly 290MB instead of 4.4GB.
//
// Sources reach the spiller two ways: decoded from a filename
// (medianImageStreaming, for merges whose inputs are already on disk) or produced
// in memory and spilled on the spot (ia_align_and_median_merge, where each warp is
// spilled as soon as warpPerspective returns it).
//
// The result is bit-identical to medianImageFromMats: the same kernel sees the
// same values in the same order, only the storage behind the row pointers
// differs.  (vals is sorted before the mean/stddev pass, so even input order
// cannot perturb the floating point — but the order is preserved anyway.)
//
// The trade is disk I/O for RAM: each source is written once and read back once.
// Callers gate it on a byte threshold so small frames keep the all-resident path.

// Rows per band.  64 rows of a 42MP 16-bit 3-channel frame is ~3MB per source.
static const int kMergeBandRows = 64;

namespace {

// Portable 64-bit seek: `long` is 32-bit on Windows, and while one frame stays
// under 2GB today this removes the footgun.
static inline int mergeSeek(std::FILE *f, uint64_t offset) {
#ifdef _WIN32
    return _fseeki64(f, (long long)offset, SEEK_SET);
#else
    return fseeko(f, (off_t)offset, SEEK_SET);
#endif
}

// A raw dump of one source's pixels, removed when this goes out of scope.
class MergeScratch {
public:
    MergeScratch() = default;
    ~MergeScratch() { reset(); }
    MergeScratch(const MergeScratch&) = delete;
    MergeScratch& operator=(const MergeScratch&) = delete;

    bool create(const std::string &path) {
        reset();
        f_ = std::fopen(path.c_str(), "w+b");
        if (!f_) return false;
        path_ = path;
        return true;
    }

    // Row by row, so a non-continuous source Mat is handled correctly.
    bool write(const cv::Mat &m, size_t rowBytes) {
        for (int y = 0; y < m.rows; ++y)
            if (std::fwrite(m.ptr(y), 1, rowBytes, f_) != rowBytes) return false;
        return std::fflush(f_) == 0;
    }

    bool readBand(void *dst, size_t rowBytes, int firstRow, int rowCount) {
        if (mergeSeek(f_, (uint64_t)firstRow * rowBytes) != 0) return false;
        const size_t want = rowBytes * (size_t)rowCount;
        return std::fread(dst, 1, want, f_) == want;
    }

    void reset() {
        if (f_) { std::fclose(f_); f_ = nullptr; }
        if (!path_.empty()) { std::remove(path_.c_str()); path_.clear(); }
    }

private:
    std::FILE *f_ = nullptr;
    std::string path_;
};

// Collects merge sources spilled to raw scratch files, then merges them a band of
// rows at a time.  Sources are added one at a time and may be released as soon as
// add() returns, so the peak holds one source rather than all of them.  The files
// are removed when this goes out of scope, on every exit path.
class MergeSpiller {
public:
    explicit MergeSpiller(const char *scratchDir) {
        std::error_code ec;
        dir_ = (scratchDir && *scratchDir)
            ? std::string(scratchDir)
            : std::filesystem::temp_directory_path(ec).string();
        std::filesystem::create_directories(dir_, ec);

        // Unique per merge within this process; star does not run two instances
        // against one temp dir.
        static std::atomic<uint64_t> scratchSeq{0};
        batch_ = scratchSeq.fetch_add(1, std::memory_order_relaxed);
    }

    // Adopt the geometry every source has to match.  Called with the base frame so
    // a mismatched source is rejected even when it is the first one spilled.
    void expect(const cv::Mat &m) {
        if (rows_ != 0 || m.empty()) return;
        rows_ = m.rows;
        cols_ = m.cols;
        type_ = m.type();
        rowBytes_ = (size_t)m.cols * m.elemSize();
    }

    bool hasGeometry() const { return rows_ != 0; }
    bool matches(const cv::Mat &m) const {
        return m.rows == rows_ && m.cols == cols_ && m.type() == type_;
    }

    // Spill one source.  The caller may release it as soon as this returns.
    bool add(const cv::Mat &m) {
        if (m.empty()) return false;
        expect(m);                       // the first source defines the geometry
        if (!matches(m)) return false;

        char name[64];
        std::snprintf(name, sizeof name, "star_merge_%llu_%zu.raw",
                      (unsigned long long)batch_, files_.size());
        const std::string path = dir_ + "/" + name;
        auto sc = std::make_unique<MergeScratch>();
        if (!sc->create(path) || !sc->write(m, rowBytes_)) {
            Log_e("median merge: cannot write scratch file %s", path.c_str());
            return false;
        }
        files_.push_back(std::move(sc));
        return true;
    }

    // residentMats stay in RAM (there is at most one, the base image) and come
    // first, in the order given, then each spilled source in the order it was
    // added — the same order the all-resident path would see.
    MatWrapperRef merge(const std::vector<cv::Mat> &residentMats,
                        double k, bool includeAll) {
        if (rows_ <= 0 || cols_ <= 0) return wrap(cv::Mat());
        if (residentMats.empty() && files_.empty()) return wrap(cv::Mat());

        const int depth = CV_MAT_DEPTH(type_);
        if (depth != CV_8U && depth != CV_16U) return wrap(cv::Mat());
        const int ch = CV_MAT_CN(type_);
        const int band = std::max(1, std::min(kMergeBandRows, rows_));

        // One reusable buffer per spilled source, allocated once for all bands.
        std::vector<std::vector<uint8_t>> bandBufs(files_.size());
        for (auto &b : bandBufs) b.resize(rowBytes_ * (size_t)band);

        cv::Mat output(rows_, cols_, type_);

        std::vector<cv::Mat> bandMats;
        bandMats.reserve(residentMats.size() + files_.size());

        for (int y0 = 0; y0 < rows_; y0 += band) {
            const int n = std::min(band, rows_ - y0);

            bandMats.clear();
            for (const auto &m : residentMats) bandMats.push_back(m.rowRange(y0, y0 + n));
            for (size_t i = 0; i < files_.size(); ++i) {
                if (!files_[i]->readBand(bandBufs[i].data(), rowBytes_, y0, n)) {
                    Log_e("median merge: scratch read failed at row %d", y0);
                    return wrap(cv::Mat());
                }
                bandMats.push_back(cv::Mat(n, cols_, type_, bandBufs[i].data(), rowBytes_));
            }

            cv::Mat outBand = output.rowRange(y0, y0 + n);
            if (depth == CV_8U) medianMergeTyped<uchar>(outBand, bandMats, k, includeAll, n, cols_, ch);
            else                medianMergeTyped<uint16_t>(outBand, bandMats, k, includeAll, n, cols_, ch);
        }

        Log_d("median merge: streamed %zu sources in bands of %d rows",
              files_.size() + residentMats.size(), band);
        return wrap(output);
    }

private:
    std::string dir_;
    uint64_t batch_ = 0;
    int rows_ = 0, cols_ = 0, type_ = 0;
    size_t rowBytes_ = 0;
    std::vector<std::unique_ptr<MergeScratch>> files_;
};

} // namespace

// residentMats stay in RAM (there is at most one, the base image); every
// filename is decoded, spilled and released one at a time.  Returns an empty
// wrapper on geometry mismatch or I/O failure, matching medianImageFromMats'
// behaviour.
static MatWrapperRef medianImageStreaming(const std::vector<cv::Mat> &residentMats,
                                          const char **filenames, int fileCount,
                                          double k, bool includeAll,
                                          const char *scratchDir)
{
    MergeSpiller spiller(scratchDir);
    if (!residentMats.empty()) spiller.expect(residentMats[0]);

    for (int i = 0; i < fileCount; ++i) {
        MatWrapperRef img = image_cache_load(filenames[i]);
        if (!img) continue;                        // skip unreadable, as before
        if (img->mat.empty()) { mat_wrapper_release(img); continue; }

        if (spiller.hasGeometry() && !spiller.matches(img->mat)) {
            Log_w("median merge: %s does not match the base geometry", filenames[i]);
            mat_wrapper_release(img);
            return wrap(cv::Mat());
        }

        const bool spilled = spiller.add(img->mat);
        mat_wrapper_release(img);       // decoded frame released; only the file remains
        if (!spilled) return wrap(cv::Mat());
    }

    return spiller.merge(residentMats, k, includeAll);
}

// --- Gradient masks ---

static MatWrapperRef createGradientMaskIntoSky(const cv::Mat &binaryMask, int gradientDistance) {
    cv::Mat skyMask;
    cv::threshold(binaryMask, skyMask, 1, 255, cv::THRESH_BINARY);
    // distanceTransform requires CV_8UC1; convert regardless of input depth/channels
    cv::Mat skyMask8u;
    if (skyMask.type() != CV_8UC1) {
        if (skyMask.channels() > 1) cv::cvtColor(skyMask, skyMask, cv::COLOR_BGR2GRAY);
        skyMask.convertTo(skyMask8u, CV_8U);
    } else {
        skyMask8u = skyMask;
    }
    cv::Mat dist;
    cv::distanceTransform(skyMask8u, dist, cv::DIST_L2, 3);
    cv::Mat distNormalized;
    dist.convertTo(distNormalized, CV_32F);
    distNormalized = cv::min(distNormalized, (float)gradientDistance);
    distNormalized = distNormalized / (float)gradientDistance;
    distNormalized *= 255.0f;
    cv::Mat gradientMask;
    distNormalized.convertTo(gradientMask, CV_8UC1);
    cv::Mat output = cv::min(skyMask8u, gradientMask);
    return wrap(output);
}

static MatWrapperRef createGradientMaskIntoGround(const cv::Mat &binaryMask, int gradientDistance) {
    cv::Mat earthMask;
    cv::threshold(binaryMask, earthMask, 1, 255, cv::THRESH_BINARY);
    // distanceTransform requires CV_8UC1; convert regardless of input depth/channels
    cv::Mat earthMask8u;
    if (earthMask.type() != CV_8UC1) {
        if (earthMask.channels() > 1) cv::cvtColor(earthMask, earthMask, cv::COLOR_BGR2GRAY);
        earthMask.convertTo(earthMask8u, CV_8U);
    } else {
        earthMask8u = earthMask;
    }
    cv::Mat inverted;
    cv::bitwise_not(earthMask8u, inverted);
    cv::Mat edges;
    cv::Canny(inverted, edges, 50, 150);
    cv::Mat dist;
    cv::distanceTransform(inverted, dist, cv::DIST_L2, 3);
    cv::Mat distNormalized;
    dist.convertTo(distNormalized, CV_32F);
    distNormalized = cv::min(distNormalized, (float)gradientDistance);
    distNormalized = 1.0f - (distNormalized / (float)gradientDistance);
    distNormalized *= 255.0f;
    cv::Mat gradientMask;
    distNormalized.convertTo(gradientMask, CV_8UC1);
    cv::Mat output = cv::max(earthMask8u, gradientMask);
    return wrap(output);
}

// --- Helper: convert to 8-bit grayscale ---

static cv::Mat toGray8U(const cv::Mat& src) {
    cv::Mat tmp;
    if (src.depth() == CV_16U) src.convertTo(tmp, CV_8U, 1.0 / 256.0);
    else if (src.depth() != CV_8U) {
        double minVal, maxVal;
        cv::minMaxLoc(src, &minVal, &maxVal);
        double scale = maxVal > 0 ? 255.0 / maxVal : 1.0;
        src.convertTo(tmp, CV_8U, scale);
    } else tmp = src.clone();
    if (tmp.channels() > 1) cv::cvtColor(tmp, tmp, cv::COLOR_BGR2GRAY);
    return tmp;
}

static cv::Mat toGray8UWithMask(const cv::Mat& src, const cv::Mat& mask) {
    cv::Mat gray;
    if (src.channels() > 1) cv::cvtColor(src, gray, cv::COLOR_BGR2GRAY);
    else gray = src.clone();

    if (!mask.empty() && mask.type() == CV_8U) {
        double minVal, maxVal;
        cv::minMaxLoc(gray, &minVal, &maxVal, nullptr, nullptr, mask);
        double scale = (maxVal > minVal) ? 255.0 / (maxVal - minVal) : 1.0;
        double shift = -minVal * scale;
        cv::Mat test;
        gray.copyTo(test, mask);
        cv::Mat tmp;
        test.convertTo(tmp, CV_8U, scale, shift);
        if (tmp.channels() > 1) cv::cvtColor(tmp, tmp, cv::COLOR_BGR2GRAY);
        return tmp;
    } else {
        return toGray8U(gray);
    }
}

// No defaults: they were 3 and 200 while the config defaults are 20 and 100, so they
// only ever served to make a wrong call look plausible. Both arguments are ints in
// adjacent positions, which is how the threshold came to be passed the dilate size —
// so require every caller to say what it means.
static cv::Mat makeStarMask(const cv::Mat &gray, int dilateSize, int thresholdVal) {
    cv::Mat thresh, mask;
    cv::threshold(gray, thresh, thresholdVal, 255, cv::THRESH_BINARY);
    if (dilateSize > 0) {
        cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE,
            cv::Size(2*dilateSize+1, 2*dilateSize+1));
        cv::dilate(thresh, mask, kernel);
    } else mask = thresh;
    return mask;
}

// --- Public API ---

MatWrapperRef ia_median_merge_filenames(const char **filenames, int count,
                                         double outlierThreshold, bool includeAll) {
    try {
        std::vector<cv::Mat> mats;
        for (int i = 0; i < count; i++) {
            MatWrapperRef img = image_cache_load(filenames[i]);
            // Shallow push: the vector's cv::Mat holds a reference, so the buffer
            // outlives the release below. medianImageFromMats only reads its inputs.
            if (img) { mats.push_back(img->mat); mat_wrapper_release(img); }
        }
        return medianImageFromMats(mats, outlierThreshold, includeAll);
    } KHT_CATCH_LOG("ia_median_merge_filenames")
    return nullptr;
}

MatWrapperRef ia_median_merge_image_with_filenames(MatWrapperRef baseImage,
                                                    const char **filenames, int count,
                                                    double outlierThreshold, bool includeAll,
                                                    const char *scratchDir,
                                                    int64_t streamingThresholdBytes,
                                                    int loadConcurrency) {
    try {
        // The all-resident path below holds every source at once.  When that would
        // exceed the threshold, stream from scratch files instead: same result,
        // bounded memory, at the cost of writing and re-reading each source once.
        if (streamingThresholdBytes > 0 && baseImage && !baseImage->mat.empty()) {
            const uint64_t frameBytes =
                (uint64_t)baseImage->mat.total() * baseImage->mat.elemSize();
            const uint64_t residentBytes = frameBytes * (uint64_t)(count + 1);
            if (residentBytes > (uint64_t)streamingThresholdBytes) {
                Log_i("median merge: streaming %d sources "
                      "(all-resident would be %lluMB, threshold %lluMB)",
                      count + 1,
                      (unsigned long long)(residentBytes / (1024 * 1024)),
                      (unsigned long long)((uint64_t)streamingThresholdBytes / (1024 * 1024)));
                std::vector<cv::Mat> resident{baseImage->mat};
                return medianImageStreaming(resident, filenames, count,
                                            outlierThreshold, includeAll, scratchDir);
            }
        }

        std::vector<cv::Mat> mats;
        mats.reserve((size_t)std::max(count, 0) + 1);
        if (baseImage) mats.push_back(baseImage->mat);

        std::vector<MergeSource> sources((size_t)std::max(count, 0));
        forEachMergeSource(count, loadConcurrency, [&](int i) {
            MatWrapperRef img = image_cache_load(filenames[i]);
            // Shallow copy, matching baseImage above and ia_median_merge below: the
            // slot's cv::Mat keeps the buffer alive past the release, and
            // medianImageFromMats only reads its inputs.
            if (!img) return;
            sources[(size_t)i].mat = img->mat;
            sources[(size_t)i].present = true;
            mat_wrapper_release(img);
        });
        // in index order, so the merge sees what the serial loop handed it
        for (auto &src : sources) if (src.present) mats.push_back(src.mat);

        return medianImageFromMats(mats, outlierThreshold, includeAll);
    } KHT_CATCH_LOG("ia_median_merge_image_with_filenames")
    return nullptr;
}


MatWrapperRef ia_accumulate_horizon_masks(const char **filenames, int count) {
    if (count <= 0) return wrap(cv::Mat());
    try {
        // Queue shared between reader thread and accumulator (this thread).
        struct SharedQueue {
            std::queue<cv::Mat> items;
            std::mutex          mtx;
            std::condition_variable cv;
            bool                readerDone = false;
        } q;
        constexpr size_t kMaxQueueSize = 8;

        // Reader thread: load each mask, normalise to single-channel, push onto queue.
        std::thread reader([&]() {
            for (int i = 0; i < count; ++i) {
                MatWrapperRef ref = image_cache_load(filenames[i]);
                if (!ref) continue;
                cv::Mat mat = ref->mat.clone();
                mat_wrapper_release(ref);

                if (mat.channels() > 1) cv::cvtColor(mat, mat, cv::COLOR_BGR2GRAY);

                // Binary 0/1 frame ready for accumulation
                cv::Mat binary;
                cv::threshold(mat, binary, 0, 1, cv::THRESH_BINARY);
                cv::Mat frame;
                binary.convertTo(frame, CV_16U);

                std::unique_lock<std::mutex> lock(q.mtx);
                q.cv.wait(lock, [&] { return q.items.size() < kMaxQueueSize; });
                q.items.push(std::move(frame));
                lock.unlock();
                q.cv.notify_one();
            }
            {
                std::lock_guard<std::mutex> lock(q.mtx);
                q.readerDone = true;
            }
            q.cv.notify_all();
        });

        // Accumulator (this thread): sum per-pixel counts in a 32-bit mat.
        cv::Mat total;
        while (true) {
            std::unique_lock<std::mutex> lock(q.mtx);
            q.cv.wait(lock, [&] { return !q.items.empty() || q.readerDone; });
            if (q.items.empty()) { lock.unlock(); break; }
            cv::Mat frame = std::move(q.items.front());
            q.items.pop();
            lock.unlock();
            q.cv.notify_one();

            if (total.empty()) total = cv::Mat::zeros(frame.size(), CV_32S);
            cv::Mat frame32s;
            frame.convertTo(frame32s, CV_32S);
            total += frame32s;
        }
        reader.join();

        if (total.empty()) return wrap(cv::Mat());

        // Pixels seen in more than half the frames → sky (255), rest → ground (0).
        cv::Mat result;
        cv::compare(total, cv::Scalar(count / 2), result, cv::CMP_GT);
        return wrap(result);
    } KHT_CATCH_LOG("ia_accumulate_horizon_masks")
    return nullptr;
}

MatWrapperRef ia_accumulate_one_horizon_mask(MatWrapperRef accum_ref, MatWrapperRef mask_ref) {
    if (!mask_ref) return accum_ref ? wrap(accum_ref->mat.clone()) : wrap(cv::Mat());
    try {
        cv::Mat mask = mask_ref->mat.clone();
        if (mask.channels() > 1) cv::cvtColor(mask, mask, cv::COLOR_BGR2GRAY);
        cv::Mat binary;
        cv::threshold(mask, binary, 0, 1, cv::THRESH_BINARY);
        cv::Mat frame32s;
        binary.convertTo(frame32s, CV_32S);

        cv::Mat total;
        if (accum_ref && !accum_ref->mat.empty()) {
            total = accum_ref->mat.clone();
            total += frame32s;
        } else {
            total = frame32s;
        }
        return wrap(total);
    } KHT_CATCH_LOG("ia_accumulate_one_horizon_mask")
    return nullptr;
}

MatWrapperRef ia_accumulate_from_files(MatWrapperRef accum_ref, const char **filenames, int count) {
    try {
        cv::Mat total;
        if (accum_ref && !accum_ref->mat.empty()) {
            total = accum_ref->mat.clone();
        }
        for (int i = 0; i < count; ++i) {
            MatWrapperRef ref = image_cache_load(filenames[i]);
            if (!ref) continue;
            cv::Mat mat = ref->mat.clone();
            mat_wrapper_release(ref);

            if (mat.channels() > 1) cv::cvtColor(mat, mat, cv::COLOR_BGR2GRAY);
            cv::Mat binary;
            cv::threshold(mat, binary, 0, 1, cv::THRESH_BINARY);
            cv::Mat frame32s;
            binary.convertTo(frame32s, CV_32S);

            if (total.empty()) {
                total = frame32s;
            } else {
                total += frame32s;
            }
        }
        return total.empty() ? wrap(cv::Mat()) : wrap(total);
    } KHT_CATCH_LOG("ia_accumulate_from_files")
    return nullptr;
}

MatWrapperRef ia_finalize_horizon_accumulation(MatWrapperRef accum_ref, int32_t total_count) {
    if (!accum_ref || accum_ref->mat.empty() || total_count <= 0) return wrap(cv::Mat());
    try {
        cv::Mat result;
        cv::compare(accum_ref->mat, cv::Scalar(total_count / 2), result, cv::CMP_GT);
        return wrap(result);
    } KHT_CATCH_LOG("ia_finalize_horizon_accumulation")
    return nullptr;
}

OCVFeatureSetRef ia_find_features(MatWrapperRef baseImage, int frameIndex,
                                   FeatureMatchMethod matchMethod,
                                   MatWrapperRef mask,
                                   AlignmentType alignmentType,
                                   int maxKeypoints, bool writeDebugImages,
                                   int groundHorizonExtension,
                                   int skyHorizonExtension,
                                   int baseImageDilateSize,
                                   int baseImageThresholdValue,
                                   double detectionScale,
                                   const char **errorMsg) {
    if (!baseImage) { if (errorMsg) *errorMsg = "null base image"; return nullptr; }
    try {
        cv::Mat horizonMask;
        if (mask && !mask->mat.empty()) horizonMask = toGray8U(mask->mat);
        else horizonMask = cv::Mat(baseImage->mat.size(), CV_8U, cv::Scalar(255));

        if (alignmentType == AlignmentTypeEarth) {
            cv::bitwise_not(horizonMask, horizonMask);
            MatWrapperRef gradRef = createGradientMaskIntoSky(horizonMask, groundHorizonExtension);
            horizonMask = gradRef->mat.clone();
            mat_wrapper_release(gradRef);
        } else if (alignmentType == AlignmentTypeSky && skyHorizonExtension > 0) {
            // Pull the sky region up and away from the horizon before anything reads it.
            //
            // toGray8UWithMask zeroes everything outside this mask, so the horizon
            // becomes a hard step from lit sky to black.  That step is a strong,
            // perfectly repeatable edge, and it is locked to the GROUND — the terrain
            // silhouette, not the stars.  makeStarMask below does not remove it: the
            // sky just above a horizon is usually the brightest part of a night frame
            // (twilight glow, light pollution), so it clears the threshold, and the
            // dilate then grows the detection mask back down across the step.  Any
            // keypoint SIFT places there votes for a ground-locked homography.
            //
            // Eroding the white sky region by this many pixels moves the step up into
            // sky that the terrain cannot reach.  It also buys some tolerance for a
            // horizon mask that sits slightly too low, which leaves real lit terrain —
            // ridgelines, treetops, town glow — inside the sky region at full
            // brightness.  Only some: the erosion has to exceed the mask's error to
            // reach past it, so this is margin, not a defence against a bad mask.
            //
            // Erosion, not createGradientMaskIntoGround: a gradient would feather the
            // edge rather than remove it, and toGray8UWithMask treats any non-zero
            // mask value as "keep", so a feathered mask still admits the whole band.
            //
            // Done as a distance transform rather than cv::erode with a disc kernel.
            // The two agree to 0.0002px on the keypoints they produce — they are asking
            // the same question, "every sky pixel further than N from any ground pixel"
            // — but erode walks the whole kernel per pixel, so its cost grows with N²:
            // it added 0.6s at N=40 and 2.6s at N=80 to a 4240x2832 detection.  The
            // distance transform is two passes whatever N is, which holds the cost flat
            // at about 0.2s.
            //
            // With no horizon mask the mask is all-255.  distanceTransform measures the
            // distance to the nearest ZERO pixel and there are none, so nothing is
            // within N of anything and the mask survives untouched — an unmasked frame
            // keeps its full frame, edges included.
            cv::Mat binary;
            cv::threshold(horizonMask, binary, 0, 255, cv::THRESH_BINARY);
            cv::Mat dist;
            cv::distanceTransform(binary, dist, cv::DIST_L2, 3);
            cv::Mat eroded = (dist > (float)skyHorizonExtension);

            // A sky region thinner than the extension erodes away completely, and an
            // all-zero mask is worse than no erosion: toGray8UWithMask would ask
            // minMaxLoc to find the range of an empty selection, and detection would
            // then run on a frame with nothing left in it.  Keep the un-eroded mask and
            // say so — a frame that is nearly all ground has little sky to align on
            // either way, but it should fail on its own merits rather than on this.
            if (cv::countNonZero(eroded) > 0) {
                horizonMask = eroded;
            } else {
                Log_d("sky horizon extension %d erased the whole sky region, using the "
                      "horizon mask unchanged", skyHorizonExtension);
            }
        }

        cv::Mat baseImageGray = toGray8UWithMask(baseImage->mat, horizonMask);

        // Optionally run detection on a downscaled copy.  SIFT's scale space costs a
        // near-constant ~210 bytes per pixel of the image it is handed (measured 38.4x
        // the raw frame at 42MP), so halving each dimension cuts the detector's peak
        // by roughly 4x.  Keypoint coordinates are scaled back to full resolution
        // below, so homographies and everything downstream stay in full-frame space.
        const double scale = (detectionScale > 0.0 && detectionScale < 1.0) ? detectionScale : 1.0;
        cv::Mat detectGray = baseImageGray;
        cv::Mat detectHorizonMask = horizonMask;
        if (scale < 1.0) {
            const cv::Size ds(std::max(1, (int)std::lround(baseImageGray.cols * scale)),
                              std::max(1, (int)std::lround(baseImageGray.rows * scale)));
            cv::resize(baseImageGray, detectGray, ds, 0, 0, cv::INTER_AREA);
            // NEAREST keeps the mask strictly binary; INTER_AREA would blend the
            // edges into intermediate values that no longer read as pass/fail.
            if (!horizonMask.empty())
                cv::resize(horizonMask, detectHorizonMask, ds, 0, 0, cv::INTER_NEAREST);
            Log_d("detecting at %dx%d instead of %dx%d (scale %.3f)",
                  ds.width, ds.height, baseImageGray.cols, baseImageGray.rows, scale);
        }

        // Derived from the downscaled gray so the mask matches detection resolution.
        cv::Mat detectionMask = detectHorizonMask;
        if (alignmentType == AlignmentTypeSky) {
            // baseImageThresholdValue, not baseImageDilateSize. The dilate size was being
            // passed for both, so the threshold was whatever
            // alignmentBaseImageDilateSize happened to be (20 by default) rather than
            // alignmentBaseImageThresholdValue (100) — and alignmentBaseImageThresholdValue
            // was plumbed the whole way down here only to be ignored. On a gray that
            // toGray8UWithMask has normalised to 0-255, a threshold of 20 passes nearly
            // every pixel, so the "star mask" selected the whole frame and SIFT ranked
            // noise alongside stars.
            detectionMask = makeStarMask(detectGray, baseImageDilateSize, baseImageThresholdValue);
        }

        std::vector<cv::KeyPoint> keypoints;
        cv::Mat descriptors;

        if (alignmentType == AlignmentTypeEarth) {
            cv::Ptr<cv::CLAHE> clahe = cv::createCLAHE(4.0, cv::Size(8,8));
            cv::Mat baseImageProcessed;
            clahe->apply(detectGray, baseImageProcessed);
            baseImageProcessed.convertTo(baseImageProcessed, CV_32F, 1.0/255.0);
            cv::pow(baseImageProcessed, 0.5, baseImageProcessed);
            baseImageProcessed.convertTo(baseImageProcessed, CV_8U, 255.0);
            cv::Ptr<cv::AKAZE> akazeBase = cv::AKAZE::create();
            akazeBase->setThreshold(1e-5);

            // AKAZE has no nfeatures equivalent, so maxKeypoints has to be applied by
            // hand — it was reaching this function and being ignored, leaving earth
            // detection uncapped where sky is capped by SIFT::create below. With a 1e-5
            // threshold on a high-resolution frame that runs to six figures of
            // keypoints, and each one costs a 61-byte descriptor plus a KeyPoint, plus
            // its share of a YAML file that gets parsed back by every neighbour's
            // homography op and held in keypointCache.
            //
            // Detect, keep the strongest, and only then describe: computing descriptors
            // for every extremum and discarding most of them is the expensive half.
            akazeBase->detect(baseImageProcessed, keypoints, detectionMask);
            if (maxKeypoints > 0 && (int)keypoints.size() > maxKeypoints) {
                Log_d("earth keypoints: keeping the strongest %d of %zu",
                      maxKeypoints, keypoints.size());
                cv::KeyPointsFilter::retainBest(keypoints, maxKeypoints);
            }
            // compute() drops any keypoint it cannot describe, so the two stay in step.
            akazeBase->compute(baseImageProcessed, keypoints, descriptors);
        } else {
            cv::Ptr<cv::SIFT> siftBase = cv::SIFT::create(maxKeypoints);
            siftBase->detectAndCompute(detectGray, detectionMask, keypoints, descriptors);
        }

        // Map keypoints back into full-resolution coordinates.  Descriptors are left
        // as computed: they describe the patch at detection scale, which is why the
        // caller keys the cached feature file by scale — mixing full-res and
        // half-res descriptors in one matcher would silently degrade matching.
        if (scale < 1.0) {
            const float inv = (float)(1.0 / scale);
            for (auto &kp : keypoints) {
                kp.pt.x *= inv;
                kp.pt.y *= inv;
                kp.size *= inv;
            }
        }

        keypoints.shrink_to_fit();
        return new OCVFeatureSetImpl(keypoints, descriptors);
    } catch (const cv::Exception &e) {
        if (errorMsg) *errorMsg = "OpenCV exception in findFeatures";
        Log_e("Error: %s", e.what());
    } catch (const std::exception &e) {
        if (errorMsg) *errorMsg = e.what();
        Log_e("Error: %s", e.what());
    } catch (...) {
        if (errorMsg) *errorMsg = "Unknown exception";
    }
    return nullptr;
}

int ia_compute_homography(OCVFeatureSetRef baseKeypoints,
                          int frameIndex,
                          const AlignmentNeighborData *neighbors, int neighborCount,
                          FeatureMatchMethod matchMethod,
                          AlignmentType alignmentType,
                          int maxKeypoints, bool writeDebugImages,
                          AlignmentUpdateFunc updateHandler, void *updateContext,
                          AlignmentWarpInfoData *outWarpInfos,
                          const char **errorMsg) {
    if (!baseKeypoints || !outWarpInfos) {
        if (errorMsg) *errorMsg = "not given keypoints on base frame";
        return 0;
    }

    auto notify = [&](ObjCAlignmentStep step, int neighbor) {
        if (updateHandler) updateHandler(frameIndex, alignmentType, step, neighbor, updateContext);
    };

    try {
        notify(ObjCAlignmentStepStart, 0);

        std::vector<cv::KeyPoint>& kpBase = baseKeypoints->keypoints;
        cv::Mat& descBase = baseKeypoints->descriptors;

        for (int ii = 0; ii < neighborCount; ++ii) {
            notify(ObjCAlignmentStepNeighborKeypointDetection, ii);

            // Initialize with failure state
            outWarpInfos[ii].homography = nullptr;
            outWarpInfos[ii].deviation = 0;
            outWarpInfos[ii].frameIndex = neighbors[ii].frameIndex;
            outWarpInfos[ii].alignmentState = AlignmentStateObjCUnableToDetectKeypoints;

            try {
                if (!neighbors[ii].keypoints) continue;
                std::vector<cv::KeyPoint>& kpNeighbor = neighbors[ii].keypoints->keypoints;
                cv::Mat& descNeighbor = neighbors[ii].keypoints->descriptors;

                if (descNeighbor.empty() || descBase.empty()) continue;

                notify(ObjCAlignmentStepNeighborKeypointMatch, ii);

                std::vector<cv::Point2f> ptsNeighbor, ptsBase;
                std::vector<std::vector<cv::DMatch>> knnMatches;
                std::vector<cv::DMatch> matches;
                // The norm has to match the descriptor, and the two detectors here do
                // not produce the same kind.  SIFT (sky) gives 128 CV_32F gradient
                // histograms, where L2 is the right distance.  AKAZE (earth) gives
                // MLDB, 486 bits packed into 61 CV_8U bytes, where the only meaningful
                // distance is Hamming — the numeric gap between two packed bytes says
                // nothing about how many bits they share, so an L2 sum over them is
                // noise wearing a distance's clothes, and Lowe's ratio test then keeps
                // whichever pairs the noise happened to separate.
                //
                // This was NORM_L2 for both.  Measured on frame 672 of the 33MP aurora
                // sequence against its neighbours at offsets -1, -2, -4 and +4, going
                // to Hamming for the earth pass takes the surviving correspondences
                // from 82/82/89/70 to 197/193/195/180 — 2.4x — and the resulting warp
                // from 8px wrong at the left edge of the ground (where phase
                // correlation says the truth is a uniform -8px shift) to about 2px.
                const int matchNorm =
                    (descBase.depth() == CV_8U) ? cv::NORM_HAMMING : cv::NORM_L2;
                cv::BFMatcher matcher(matchNorm);

                switch (matchMethod) {
                case FeatureMatchMethodBruteForce: {
                    matcher.match(descNeighbor, descBase, matches);
                    double minDist = std::numeric_limits<double>::max();
                    for (auto &m : matches) minDist = std::min(minDist, (double)m.distance);
                    double cutoff = std::max(2 * minDist, 30.0);
                    for (auto &m : matches) {
                        if (m.distance <= cutoff) {
                            ptsNeighbor.push_back(kpNeighbor[m.queryIdx].pt);
                            ptsBase.push_back(kpBase[m.trainIdx].pt);
                        }
                    }
                    break;
                }
                case FeatureMatchMethodKNNLowes: {
                    matcher.knnMatch(descNeighbor, descBase, knnMatches, 2);
                    for (size_t i = 0; i < knnMatches.size(); i++) {
                        if (knnMatches[i].size() == 2) {
                            const auto &m1 = knnMatches[i][0], &m2 = knnMatches[i][1];
                            if (m1.distance < 0.75 * m2.distance) {
                                ptsNeighbor.push_back(kpNeighbor[m1.queryIdx].pt);
                                ptsBase.push_back(kpBase[m1.trainIdx].pt);
                            }
                        }
                    }
                    break;
                }
                case FeatureMatchMethodFLANN: {
                    if (matchNorm == cv::NORM_HAMMING) {
                        // FLANN's default index is a KDTree over L2, which is the same
                        // mismatch the BFMatcher above had: widening packed bits to
                        // floats does not make Euclidean distance mean anything on
                        // them.  LSH would be the FLANN-side answer, but it brings
                        // tuning parameters nothing here can validate, so binary
                        // descriptors take the exact matcher instead.
                        matcher.knnMatch(descNeighbor, descBase, knnMatches, 2);
                    } else {
                        cv::Mat dn32, db32;
                        descNeighbor.convertTo(dn32, CV_32F);
                        descBase.convertTo(db32, CV_32F);
                        cv::FlannBasedMatcher flann;
                        flann.knnMatch(dn32, db32, knnMatches, 2);
                    }
                    for (size_t i = 0; i < knnMatches.size(); i++) {
                        if (knnMatches[i].size() == 2) {
                            const auto &m1 = knnMatches[i][0], &m2 = knnMatches[i][1];
                            if (m1.distance < 0.75 * m2.distance) {
                                ptsNeighbor.push_back(kpNeighbor[m1.queryIdx].pt);
                                ptsBase.push_back(kpBase[m1.trainIdx].pt);
                            }
                        }
                    }
                    break;
                }
                }

                if (ptsNeighbor.size() >= 4) {
                    notify(ObjCAlignmentStepAligningNeighbor, ii);
                    // cv::findHomography with RANSAC draws random subsets via
                    // cv::theRNG().  Without an explicit seed the chosen
                    // consensus set varies run-to-run, occasionally producing
                    // homographies whose deviation magnitude looks fine but
                    // whose tx/ty are off by several pixels.  Seed
                    // per (baseFrame, neighborFrame) so the same pair always
                    // gets the same RANSAC sequence.
                    uint64_t rngSeed =
                        (static_cast<uint64_t>(frameIndex) * 2654435761ULL) ^
                        static_cast<uint64_t>(neighbors[ii].frameIndex);
                    cv::theRNG() = cv::RNG(rngSeed);
                    cv::Mat H = cv::findHomography(ptsNeighbor, ptsBase, cv::RANSAC, 10);
                    if (!H.empty() && H.type() != CV_64F) H.convertTo(H, CV_64F);

                    if (!H.empty() && H.rows == 3 && H.cols == 3) {
                        cv::Mat I = cv::Mat::eye(3, 3, H.type());
                        double deviation = cv::norm(H - I, cv::NORM_L2);
                        outWarpInfos[ii].homography = wrap(H);
                        outWarpInfos[ii].deviation = deviation;
                        outWarpInfos[ii].alignmentState = AlignmentStateObjCHomographySuccess;
                    } else {
                        outWarpInfos[ii].alignmentState = AlignmentStateObjCNoHomographyFound;
                    }
                } else {
                    outWarpInfos[ii].alignmentState = AlignmentStateObjCNotEnoughKeypoints;
                }
            } catch (const cv::Exception &e) {
                Log_e("frame %d Error: %s", frameIndex, e.what());
            } catch (const std::exception &e) {
                Log_e("frame %d Error: %s", frameIndex, e.what());
            }
        }

        notify(ObjCAlignmentStepComplete, 0);
        return neighborCount;
    } catch (const cv::Exception &e) {
        if (errorMsg) *errorMsg = "OpenCV exception";
        Log_e("Error: %s", e.what());
    } catch (...) {
        if (errorMsg) *errorMsg = "Unknown exception";
    }
    return 0;
}

// The homography for one neighbour, keyed by its offset from the base frame.
// Not owned; null when this neighbour has none and cannot be warped.
static MatWrapperRef homographyForOffset(int offset, const int *keys,
                                         MatWrapperRef *values, int count) {
    for (int j = 0; j < count; ++j) {
        if (keys[j] == offset) return values[j];
    }
    return nullptr;
}

static cv::Mat warpInto(const cv::Mat &src, const cv::Mat &H) {
    // Zero means "this neighbour has no sample here" to the merge downstream, and every
    // destination pixel the warp does not cover has to end up saying exactly that.
    //
    // BORDER_CONSTANT is not enough on its own.  It zeroes what falls outside, but the
    // boundary itself is interpolated: INTER_LINEAR blends the outermost real pixel with
    // the zero just past it and returns a one-pixel fringe at a fraction of its true
    // brightness — real-looking, non-zero, and indistinguishable from data by the time
    // the merge sees it.  On the first and last frames of a sequence, where a whole edge
    // is covered by nothing but fringe, that showed up as a dim ragged band: measured
    // down to 70% brightness across three columns on a 4240px frame.
    //
    // BORDER_TRANSPARENT skips any destination pixel whose interpolation window is not
    // wholly inside the source, leaving it as it found it — so pre-zeroing the
    // destination gets the fringe zeroed by the same pass that does the warp.
    //
    // The alternative, warping a solid mask through the same homography and rejecting
    // wherever it comes back short of full scale, was built and measured against this.
    // It reaches the same place at the frame edges (both leave every edge column within
    // 0.7% of the source frame, where the shipped code left them at 0 to 0.20), but not
    // by the same route: the two disagree on 0.14% of pixels, every one of them within
    // 16px of a frame edge — the boundary band itself, where they draw the fringe line
    // one pixel differently.  This is the cheaper of the two by a wide margin.  Best of 5
    // on a 4-neighbour 12MP merge, three runs each: 0.89/0.97/0.97s here, 1.12/1.49/1.62s
    // for plain BORDER_CONSTANT with the fringe left in, 1.78/1.82/1.90s for the mask.
    cv::Mat warped = cv::Mat::zeros(src.size(), src.type());
    cv::warpPerspective(src, warped, H, src.size(),
                        cv::INTER_LINEAR, cv::BORDER_TRANSPARENT);
    return warped;
}


MatWrapperRef ia_align_and_median_merge(MatWrapperRef baseImage, int baseFrameIndex,
                                        const AlignmentNeighborData *neighbors,
                                        int neighborCount,
                                        const int *homographyKeys,
                                        MatWrapperRef *homographyValues,
                                        int homographyCount,
                                        double outlierThreshold, bool includeAll,
                                        const char *scratchDir,
                                        int64_t streamingThresholdBytes,
                                        int loadConcurrency,
                                        int *outWarpCount,
                                        const char **errorMsg) {
    if (outWarpCount) *outWarpCount = 0;
    if (!baseImage || baseImage->mat.empty()) {
        if (errorMsg) *errorMsg = "null base image";
        return nullptr;
    }
    if (!neighbors) {
        if (errorMsg) *errorMsg = "no neighbors to align";
        return nullptr;
    }
    try {
        // Zero means "no source data here" to the merge kernel, because warpInto
        // zeroes whatever its warp does not cover.  That convention collides with
        // pixel-channels that are legitimately zero: a deep twilight sky exposes with
        // its red channel at exactly 0, so in that channel every source reads
        // "no data" and the one source with light there — a star's red component, an
        // airplane's red beacon — becomes the only observation the median sees.
        // Measured on a dusk frame: a saturated red stamp (54795 of 65535) in the
        // merged output at a position where the base frame recorded nothing, one per
        // source with a light there.  The merge exists to remove those.
        //
        // So every source is lifted off zero before merging: 0 becomes 1, an
        // observation one count above black, and only the warp borders are 0
        // afterwards because warpInto writes them after this.  Costs one extra
        // frame-sized buffer for the base and one per neighbour in flight.
        cv::Mat base;
        cv::max(baseImage->mat, 1, base);
        const uint64_t frameBytes = (uint64_t)base.total() * base.elemSize();
        const uint64_t residentBytes = frameBytes * (uint64_t)(neighborCount + 1);
        const bool stream = streamingThresholdBytes > 0 &&
                            residentBytes > (uint64_t)streamingThresholdBytes;

        // Only one of these is used: warps are either banked here or spilled there.
        std::vector<cv::Mat> warps;
        MergeSpiller spiller(scratchDir);
        if (stream) {
            Log_i("aligned merge: streaming %d sources "
                  "(all-resident would be %lluMB, threshold %lluMB)",
                  neighborCount + 1,
                  (unsigned long long)(residentBytes / (1024 * 1024)),
                  (unsigned long long)((uint64_t)streamingThresholdBytes / (1024 * 1024)));
            spiller.expect(base);
        } else {
            warps.reserve((size_t)std::max(neighborCount, 0));
        }

        // One neighbour: decode it and warp it by its homography.  A neighbour with
        // no file, no homography, or a warp whose geometry does not match the base
        // comes back absent, as it did before.  Anything worth saying goes in `note`
        // rather than straight to the log, because on the resident path this runs on
        // several threads at once and the lines would interleave with each other and
        // with other frames'.
        auto warpNeighbour = [&](int i, MergeSource &out) {
            MatWrapperRef neighbor = image_cache_load(neighbors[i].filename);
            if (!neighbor) return;

            MatWrapperRef H = homographyForOffset(neighbors[i].frameIndex - baseFrameIndex,
                                                  homographyKeys, homographyValues,
                                                  homographyCount);
            if (!H) { mat_wrapper_release(neighbor); return; }

            // lifted off zero before the warp, so that afterwards a zero means
            // exactly one thing: the warp did not cover this pixel — see the
            // comment on `base` above
            cv::Mat lifted;
            cv::max(neighbor->mat, 1, lifted);
            mat_wrapper_release(neighbor);
            cv::Mat warped = warpInto(lifted, H->mat);

            if (warped.rows != base.rows || warped.cols != base.cols ||
                warped.type() != base.type()) {
                out.note = std::string("aligned merge: warp of ") + neighbors[i].filename +
                           " does not match the base geometry";
                return;
            }
            out.mat = warped;
            out.present = true;
        };

        int warpCount = 0;
        if (stream) {
            // Serial on purpose.  Each warp is spilled and freed within the iteration
            // that produced it — that release is the whole point of fusing the merge
            // into the alignment, and workers in flight would each hold one.
            for (int i = 0; i < neighborCount; ++i) {
                MergeSource src;
                warpNeighbour(i, src);
                if (!src.note.empty()) Log_w("%s", src.note.c_str());
                if (!src.present) continue;
                if (!spiller.add(src.mat)) {   // logs its own failure
                    if (errorMsg) *errorMsg = "cannot spill warped frame to scratch";
                    return nullptr;
                }
                warpCount++;
            }
        } else {
            // The resident path is going to hold every warp anyway, so producing them
            // concurrently costs only the sources in flight.
            std::vector<MergeSource> sources((size_t)std::max(neighborCount, 0));
            forEachMergeSource(neighborCount, loadConcurrency, [&](int i) {
                warpNeighbour(i, sources[(size_t)i]);
            });
            for (auto &src : sources) {
                if (!src.note.empty()) Log_w("%s", src.note.c_str());
                if (!src.present) continue;
                warps.push_back(src.mat);
                warpCount++;
            }
        }

        if (outWarpCount) *outWarpCount = warpCount;
        if (warpCount == 0) return nullptr;   // caller falls back to the original frame

        if (stream) return spiller.merge({base}, outlierThreshold, includeAll);

        std::vector<cv::Mat> mats;
        mats.reserve(warps.size() + 1);
        mats.push_back(base);
        mats.insert(mats.end(), warps.begin(), warps.end());
        return medianImageFromMats(mats, outlierThreshold, includeAll);
    } catch (const cv::Exception &e) {
        if (errorMsg) *errorMsg = "OpenCV exception in aligned merge";
        Log_e("Error: %s", e.what());
    } catch (const std::exception &e) {
        if (errorMsg) *errorMsg = e.what();
        Log_e("Error: %s", e.what());
    } catch (...) {
        if (errorMsg) *errorMsg = "Unknown exception";
    }
    return nullptr;
}

MatWrapperRef ia_gradient_mask_into_sky(MatWrapperRef binaryMask, int gradientDistance) {
    if (!binaryMask) return nullptr;
    try {
        return createGradientMaskIntoSky(binaryMask->mat, gradientDistance);
    } KHT_CATCH_LOG("ia_gradient_mask_into_sky")
    return nullptr;
}

MatWrapperRef ia_gradient_mask_into_ground(MatWrapperRef binaryMask, int gradientDistance) {
    if (!binaryMask) return nullptr;
    try {
        return createGradientMaskIntoGround(binaryMask->mat, gradientDistance);
    } KHT_CATCH_LOG("ia_gradient_mask_into_ground")
    return nullptr;
}
