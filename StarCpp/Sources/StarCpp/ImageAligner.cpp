// ImageAligner.cpp — Pure C++ implementation of image alignment operations
#include "ImageAligner.h"
#include "ImageCache_C.h"
#include "GPUOps_C.h"
#include "MatWrapper.h"
#include "MatWrapperImpl.hpp"
#include "OCVFeatureSetImpl.hpp"
#include "SIFTDetector.h"
#include "AKAZEDetector.h"
#include "logging_impl.hpp"
#include "MedianMerge.hpp"
#include "BoxBlur.hpp"
#include "ExactWarp.hpp"
#include "PairMatch.hpp"

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
#include <chrono>
#include <ctime>
#include <cmath>
#include <limits>

// Shares the buffer of a freshly produced cv::Mat the caller is about to drop.
// Never pass a live wrapper's mat here — use the deep constructor for that.
static MatWrapperRef wrap(const cv::Mat& mat) {
    return new MatWrapperImpl(MatWrapperImpl::Adopt{}, mat);
}

// Wraps `mat`'s existing buffer with no copy and no ownership transfer — the
// returned ref's mat.u is null, so mat_wrapper_release on it never touches
// `mat`'s own refcount or lifetime. Only ever used to hand a GPU handler a view
// into a cv::Mat this function already owns for the duration of the call
// (never returned, never retained past it): a per-neighbour warp source, a
// merge's sources/misses/output, all of which stay alive for as long as the
// registered Swift closure runs synchronously on this thread.
static MatWrapperRef wrapReadOnly(const cv::Mat& mat) {
    return new MatWrapperImpl((int)mat.rows, (int)mat.cols, mat.type(),
                              const_cast<uchar*>(mat.data), mat.step[0]);
}

// GPUOps_C.h declares only whether a handler is registered; ImageAligner.cpp is
// the one place that actually needs to call one, so these two (defined in
// GPUOps_C.cpp) are forward-declared here rather than added to the public
// header Swift sees.
extern "C" GPUWarpFunc gpu_ops_get_warp(void);
extern "C" GPUMedianMergeFunc gpu_ops_get_median_merge(void);
extern "C" GPUAlignedMergeFunc gpu_ops_get_aligned_merge(void);

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

// The median merge kernels (sorting network, Welford and exact-statistics block kernels,
// run-time choice between them) live in MedianMerge.hpp.

static MatWrapperRef medianImageFromMats(const std::vector<cv::Mat>& mats,
                                          double k, bool includeAll,
                                          const cv::Mat &misses = cv::Mat(),
                                          bool useGPU = false) {
    if (mats.empty()) return wrap(cv::Mat());

    const cv::Mat& first = mats[0];
    int rows = first.rows, cols = first.cols, ch = first.channels(), depth = first.depth();

    for (size_t i = 1; i < mats.size(); ++i) {
        if (mats[i].rows != rows || mats[i].cols != cols || mats[i].type() != first.type())
            return wrap(cv::Mat());
    }

    // A plane that does not describe these sources is worse than none: it would
    // skip real samples at every pixel.  Refuse it rather than merge with it.
    if (!misses.empty() &&
        (misses.rows != rows || misses.cols != cols || misses.type() != CV_8UC1))
    {
        Log_e("median merge: coverage plane does not match the source geometry");
        return wrap(cv::Mat());
    }

    cv::Mat output(rows, cols, first.type());

    // GPU path: exact-integer sigma-clip median, registered (or not) from
    // StarCppBridge/GPUOps.swift — see GPUOps_C.h for why this differs, in a
    // small documented way, from medianMergeTyped's double Welford below.
    // uchar/uint16_t are medianMergeTyped's only two instantiations (see
    // clamp_cast_int above), so there is nothing to gain offering the GPU path
    // any other depth.
    if (useGPU && (depth == CV_8U || depth == CV_16U)) {
        if (GPUMedianMergeFunc gpuMerge = gpu_ops_get_median_merge()) {
            std::vector<MatWrapperRef> sourceRefs;
            sourceRefs.reserve(mats.size());
            for (const auto &m : mats) sourceRefs.push_back(wrapReadOnly(m));
            MatWrapperRef missesRef = misses.empty() ? nullptr : wrapReadOnly(misses);
            MatWrapperRef dstRef = wrapReadOnly(output);

            const bool ok = gpuMerge(sourceRefs.data(), (int)sourceRefs.size(), missesRef,
                                     k, includeAll, dstRef);

            for (MatWrapperRef ref : sourceRefs) mat_wrapper_release(ref);
            if (missesRef) mat_wrapper_release(missesRef);
            mat_wrapper_release(dstRef);

            if (ok) return wrap(output);
            // Fall through to the CPU kernel below on failure. It overwrites every
            // pixel of `output` unconditionally, so a partial GPU attempt cannot
            // leak through — no re-zeroing needed here, unlike warpInto.
        }
    }

    const CoverageMisses cover{misses};
    if (depth == CV_8U) medianMergeTyped<uchar>(output, mats, k, includeAll, rows, cols, ch, cover);
    else if (depth == CV_16U) medianMergeTyped<uint16_t>(output, mats, k, includeAll, rows, cols, ch, cover);
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
    //
    // `misses` is not banded with the sources: it stays whole and resident for the
    // life of the merge, and each band takes a view of its own rows.  At one byte a
    // pixel that is 40MB against the gigabytes streaming exists to avoid, and it is
    // the reason coverage is carried as a count rather than a mask per source —
    // masks would have to be spilled and read back with every band.
    MatWrapperRef merge(const std::vector<cv::Mat> &residentMats,
                        double k, bool includeAll,
                        const cv::Mat &misses = cv::Mat()) {
        if (rows_ <= 0 || cols_ <= 0) return wrap(cv::Mat());
        if (residentMats.empty() && files_.empty()) return wrap(cv::Mat());
        if (!misses.empty() &&
            (misses.rows != rows_ || misses.cols != cols_ || misses.type() != CV_8UC1))
        {
            Log_e("median merge: coverage plane does not match the source geometry");
            return wrap(cv::Mat());
        }

        const int depth = CV_MAT_DEPTH(type_);
        if (depth != CV_8U && depth != CV_16U) return wrap(cv::Mat());
        const int ch = CV_MAT_CN(type_);
        const int band = std::max(1, std::min(kMergeBandRows, rows_));

        // One reusable buffer per spilled source, allocated once for all bands.
        std::vector<std::vector<uint8_t>> bandBufs(files_.size());
        for (auto &b : bandBufs) b.resize(rowBytes_ * (size_t)band);

        cv::Mat output(rows_, cols_, type_);
        const CoverageMisses cover{misses};

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
            const CoverageMisses bandCover = cover.fromRow(y0);
            if (depth == CV_8U) medianMergeTyped<uchar>(outBand, bandMats, k, includeAll, n, cols_, ch, bandCover);
            else                medianMergeTyped<uint16_t>(outBand, bandMats, k, includeAll, n, cols_, ch, bandCover);
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
                                          const char *scratchDir,
                                          const cv::Mat &misses = cv::Mat())
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

    return spiller.merge(residentMats, k, includeAll, misses);
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
    // Clamp to the gradient distance and rescale to 0..255 in two passes rather
    // than five.  This used to convert the already-CV_32F distance map to CV_32F
    // (a full 42MP float copy that changed nothing), then allocate a fresh
    // full-frame temporary for each of min, divide and multiply.  Measured at
    // 42MP the tail after the distance transform went from 180 ms to 32 ms, and
    // the whole call from 417 ms to 308 ms.
    //
    // Bit-identical, not merely equivalent: checked pixel-for-pixel against the
    // old sequence over a 42MP wavy horizon for every gradientDistance from 1 to
    // 150 — zero differing pixels at every one.  Worth having checked, because
    // folding the divide into the convert's scale factor turns `(x/D)*255` into
    // `x*(255/D)`, and 255/D is not binary-exact for values like the default
    // ground extension of 100.
    cv::threshold(dist, dist, (double)gradientDistance, 0, cv::THRESH_TRUNC);
    cv::Mat gradientMask;
    dist.convertTo(gradientMask, CV_8UC1, 255.0 / (double)gradientDistance);
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
    cv::Mat dist;
    cv::distanceTransform(inverted, dist, cv::DIST_L2, 3);
    // Deliberately *not* the fused form used on the sky side.  Folding this
    // ramp into the convert as `-x*(255/D) + 255` is not bit-identical to
    // `(1 - x/D)*255`: swept over a wavy horizon it agreed everywhere except
    // D=121, where 33 pixels came out one value different.  So this keeps the
    // original arithmetic in its original order and only drops what was free —
    // the no-op CV_32F copy of an already-CV_32F distance map, the full-frame
    // temporary behind each of min/divide/subtract/multiply, and a `cv::Canny`
    // that computed a whole frame of edges into a local nothing ever read.
    cv::min(dist, (float)gradientDistance, dist);
    dist /= (float)gradientDistance;
    dist = 1.0f - dist;
    dist *= 255.0f;
    cv::Mat gradientMask;
    dist.convertTo(gradientMask, CV_8UC1);
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

// The intensity range inside a mask that detection stretches across 0-255, taken at
// percentiles of the masked pixels rather than at their extremes.
//
// cv::minMaxLoc answers with the single brightest and single darkest pixel in the
// selection, which puts the whole region's contrast at the mercy of one of them.  A
// ground region almost always contains one: a distant street light, a lit window, a
// passing headlight, a hot pixel.  Measured on frame 700 of a 24MP sequence whose
// ground held a near-saturated light (65448 of 65535) while 98.4% of the ground sat at
// exactly 0 and its 99th percentile was 64 — min/max gave a scale of 255/65448, so the
// entire ground quantised to 8-bit 0 before CLAHE ever saw it and AKAZE found 913
// keypoints crammed into a 163px band at the horizon.  The same frame's 0.1-99.9
// percentile range is 0..1765, 37x tighter, and yields the full 2000.
//
// 99.9 rather than something tighter because this also feeds the sky, where the bright
// tail is the signal: on a 33MP frame the sky's 99.9th percentile was 58445 against a
// maximum of 60304, a 3% change, so the star mask's threshold keeps meaning what it
// was tuned to mean.  A percentile deep enough to reject one light is still shallow
// enough to keep a sky full of stars.
//
// Values outside the range are not lost, they saturate: convertTo to CV_8U clamps, so
// the light that used to set the scale simply reads 255 like any other highlight.
static constexpr double kStretchLowPercentile  = 0.001;
static constexpr double kStretchHighPercentile = 0.999;

// The [low, high] intensities bounding `lowPercentile`..`highPercentile` of the pixels
// `mask` selects in `gray`.  False when there is nothing to measure or the answer would
// not be a usable range, which leaves the caller on min/max.
//
// An exact histogram rather than a sample: one pass, and at CV_16U the 65536 bins cost
// 512KB against a frame that is measured in hundreds of megabytes.
static bool maskedPercentileRange(const cv::Mat& gray, const cv::Mat& mask,
                                  double lowPercentile, double highPercentile,
                                  double& outLow, double& outHigh) {
    if (gray.empty() || mask.empty()) return false;
    if (gray.size() != mask.size()) return false;
    if (gray.channels() != 1 || mask.type() != CV_8U) return false;

    int bins;
    if (gray.depth() == CV_8U)       bins = 256;
    else if (gray.depth() == CV_16U) bins = 65536;
    else return false;               // float/signed depths keep the old behaviour

    std::vector<uint64_t> histogram((size_t)bins, 0);
    uint64_t total = 0;
    for (int y = 0; y < gray.rows; ++y) {
        const uchar *maskRow = mask.ptr<uchar>(y);
        if (gray.depth() == CV_8U) {
            const uchar *grayRow = gray.ptr<uchar>(y);
            for (int x = 0; x < gray.cols; ++x)
                if (maskRow[x]) { histogram[grayRow[x]]++; total++; }
        } else {
            const ushort *grayRow = gray.ptr<ushort>(y);
            for (int x = 0; x < gray.cols; ++x)
                if (maskRow[x]) { histogram[grayRow[x]]++; total++; }
        }
    }
    if (total == 0) return false;

    // Both bounds are the first bin at or past their share of the population, so a
    // region holding one value returns that value twice and is rejected below.
    //
    // At least one pixel, never zero: a selection smaller than 1/lowPercentile — under
    // a thousand pixels at 0.1% — rounds its share down to nothing, and a target of
    // zero is met by the first bin looked at whether or not anything is in it.  That
    // would answer 0 for a region whose darkest pixel is nowhere near it.
    auto binAtFraction = [&](double fraction) {
        const uint64_t want = std::max<uint64_t>(1, (uint64_t)(fraction * (double)total));
        uint64_t seen = 0;
        for (int i = 0; i < bins; ++i) {
            seen += histogram[(size_t)i];
            if (seen >= want) return i;
        }
        return bins - 1;
    };

    const int low  = binAtFraction(lowPercentile);
    const int high = binAtFraction(highPercentile);
    if (high <= low) return false;

    outLow  = (double)low;
    outHigh = (double)high;
    return true;
}

static cv::Mat toGray8UWithMask(const cv::Mat& src, const cv::Mat& mask) {
    cv::Mat gray;
    if (src.channels() > 1) cv::cvtColor(src, gray, cv::COLOR_BGR2GRAY);
    else gray = src.clone();

    if (!mask.empty() && mask.type() == CV_8U) {
        double lowVal, highVal;
        if (!maskedPercentileRange(gray, mask,
                                   kStretchLowPercentile, kStretchHighPercentile,
                                   lowVal, highVal)) {
            // Nothing a percentile can say about this selection — a depth the
            // histogram does not cover, or a region holding a single value.  The
            // extremes are no worse an answer here than they ever were.
            cv::minMaxLoc(gray, &lowVal, &highVal, nullptr, nullptr, mask);
        }
        double scale = (highVal > lowVal) ? 255.0 / (highVal - lowVal) : 1.0;
        double shift = -lowVal * scale;
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

// How far from the edge of the sky mask, in detection pixels, a sky keypoint has to be.
//
// toGray8UWithMask blacks out everything the mask excludes, and that leaves a hard step
// from lit sky to black along the mask's edge.  The erosion below moves the step up off
// the terrain, but it cannot remove it — the mask makes it — and wherever it sits it
// follows the horizon, so it moves with the ground, not the stars.  Under moonlight the
// sky just above the horizon is the brightest sky there is (179/255 after the stretch on
// the 10_17_2026 a9-1 sequence, against 51/255 overhead), which makes the step the
// strongest structure in the frame.  There, 23-28% of the sky keypoints sat on it, they
// were half of all descriptor matches (the edge looks the same along its length, so most
// matched the wrong place along it), and the 28-62 per pair that RANSAC accepted ran
// 3.8px per frame sideways off the stars — the ground's drift against the sky.  The fit
// bent between them and the stars: those in one corner survived the merge and the rest
// of the sky lost its stars.
//
// 40 clears the descriptor of every keypoint the step produced there (SIFT's descriptor
// reaches about 5.3x a keypoint's size, and the step's ran around 3-7px at detection
// scale).  It is in detection pixels because that is where SIFT's footprint is measured;
// at the default 1.5 divisor it keeps keypoints 60px clear of the cut, which with the
// 40px erosion is 100px off the ground — exactly what was measured.  Measured against
// thousands of star centroids, it took the frame that lost its stars from 1.5-7.5px
// wrong to 0.1-0.4px together with the tighter sky RANSAC below.  A band that narrow is
// a sliver of any real sky, so what it costs is a few stars right at the horizon.
static constexpr int kSkyKeypointCutMargin = 40;

// The part of `mask` (non-zero = keep) further than `margin` pixels from anything it
// excludes.  A mask with nothing excluded has no cut and comes back unchanged:
// distanceTransform measures the distance to the nearest zero pixel, and there is none.
static cv::Mat awayFromMaskEdge(const cv::Mat &mask, int margin) {
    cv::Mat binary, dist;
    cv::threshold(mask, binary, 0, 255, cv::THRESH_BINARY);
    cv::distanceTransform(binary, dist, cv::DIST_L2, 3);
    return dist > (float)margin;
}

// --- Star centroids ---------------------------------------------------------
//
// SIFT is a poor star matcher.  Stars all look alike, so their descriptors collide and
// Lowe's ratio test throws most of them away: on a moonlit 24MP frame ~750 genuine sky
// keypoints became 20-60 RANSAC inliers per neighbour, and in twilight 7-18.  The star
// *positions* carry far more: the same frames hold thousands of stars, and matched by
// position under a rough homography they fit one to 0.26-0.48px RMS from ~4000 pairs.
// So the sky keeps its stars' centroids next to its keypoints, and the homography is
// refined against them (refineSkyHomographyWithStars).
//
// A star here is a peak of a difference of Gaussians (sigma 1.2 minus sigma 4: a
// point-source filter that flattens sky glow, moonlit gradients and most cloud), more
// than kStarPeakSigmas above the sky's noise, located to sub-pixel by a 5x5 weighted
// centroid.  Found on the raw frame's own gray at full resolution, not on the 8-bit
// stretch SIFT gets and not at detection scale: a faint star on a bright moonlit sky is
// a few 8-bit levels high, and in deep twilight the full-resolution centroids paired
// roughly twice as many stars and took the fits that were 1.4-2.3px wrong at detection
// scale to 0.02-0.5px.  Run after SIFT, whose scale space is many times the size of
// these few full-frame float buffers, so it adds nothing to the op's memory peak.
static constexpr int    kMaxStarCentroids = 5000;
static constexpr double kStarPeakSigmas   = 6.0;

// `image` is the full-resolution frame and `skyMask` (non-zero = search) the same size.
// Returns centroids brightest first.
static std::vector<cv::Point2f> findStarCentroids(const cv::Mat &image, const cv::Mat &skyMask) {
    cv::Mat gray;
    if (image.channels() == 3)      cv::cvtColor(image, gray, cv::COLOR_BGR2GRAY);
    else if (image.channels() == 4) cv::cvtColor(image, gray, cv::COLOR_BGRA2GRAY);
    else                            gray = image;
    if (gray.size() != skyMask.size()) return {};

    cv::Mat f, narrow, wide;
    gray.convertTo(f, CV_32F);
    cv::GaussianBlur(f, narrow, cv::Size(), 1.2);
    cv::GaussianBlur(f, wide, cv::Size(), 4.0);
    const cv::Mat dog = narrow - wide;

    // The sky's noise, robustly: the median absolute deviation over a sample.
    std::vector<float> sample;
    for (int y = 0; y < dog.rows; y += 7) {
        const float *d = dog.ptr<float>(y);
        const uchar *m = skyMask.ptr<uchar>(y);
        for (int x = 0; x < dog.cols; x += 7) if (m[x]) sample.push_back(d[x]);
    }
    if (sample.size() < 100) return {};
    auto median = [](std::vector<float> &v) {
        std::nth_element(v.begin(), v.begin() + v.size() / 2, v.end());
        return v[v.size() / 2];
    };
    const float centre = median(sample);
    for (auto &v : sample) v = std::fabs(v - centre);
    const float threshold = centre + (float)kStarPeakSigmas * 1.4826f * median(sample);

    cv::Mat localMax;
    cv::dilate(dog, localMax, cv::getStructuringElement(cv::MORPH_RECT, cv::Size(7, 7)));

    struct Peak { cv::Point2f at; float value; };
    std::vector<Peak> peaks;
    for (int y = 4; y < dog.rows - 4; ++y) {
        const float *d = dog.ptr<float>(y), *mx = localMax.ptr<float>(y);
        const uchar *m = skyMask.ptr<uchar>(y);
        for (int x = 4; x < dog.cols - 4; ++x) {
            if (!m[x] || d[x] <= threshold || d[x] != mx[x]) continue;
            double sw = 0, sx = 0, sy = 0;
            for (int j = -2; j <= 2; ++j) {
                const float *row = dog.ptr<float>(y + j);
                for (int i = -2; i <= 2; ++i) {
                    const double w = std::max(0.f, row[x + i]);
                    sw += w; sx += w * (x + i); sy += w * (y + j);
                }
            }
            peaks.push_back({cv::Point2f((float)(sx / sw), (float)(sy / sw)), d[x]});
        }
    }
    std::sort(peaks.begin(), peaks.end(),
              [](const Peak &a, const Peak &b) { return a.value > b.value; });
    if ((int)peaks.size() > kMaxStarCentroids) peaks.resize(kMaxStarCentroids);

    std::vector<cv::Point2f> stars;
    stars.reserve(peaks.size());
    for (const auto &p : peaks) stars.push_back(p.at);
    return stars;
}

// --- Public API ---

MatWrapperRef ia_median_merge_filenames(const char **filenames, int count,
                                         double outlierThreshold, bool includeAll,
                                         bool useGPU) {
    try {
        std::vector<cv::Mat> mats;
        for (int i = 0; i < count; i++) {
            MatWrapperRef img = image_cache_load(filenames[i]);
            // Shallow push: the vector's cv::Mat holds a reference, so the buffer
            // outlives the release below. medianImageFromMats only reads its inputs.
            if (img) { mats.push_back(img->mat); mat_wrapper_release(img); }
        }
        return medianImageFromMats(mats, outlierThreshold, includeAll, cv::Mat(), useGPU);
    } KHT_CATCH_LOG("ia_median_merge_filenames")
    return nullptr;
}

// No coverage plane goes to the kernel from here, and that is the whole of what
// this entry point has to say about it: nothing is warped on the way in, so every
// source covers every pixel and there are no holes to describe.
//
// It used to say nothing and mean something else.  The kernel read coverage off the
// pixels — a zero was a hole — and this merge fed it originals, whose blacks are
// zeros.  A static earth merge of a black-clipped foreground (99.8% of its
// pixel-channels at exactly 0 on the 08_15_2026 a7riii sequence) therefore threw
// away every real sample it had and returned the median of the only "observations"
// left, which were car headlights: frame 1197's ground came back saturated where
// the frame itself recorded 581 of 65535, and each of the six frames a car crossed
// was painted into the twenty-two output frames that had it as a neighbour.
MatWrapperRef ia_median_merge_image_with_filenames(MatWrapperRef baseImage,
                                                    const char **filenames, int count,
                                                    double outlierThreshold, bool includeAll,
                                                    const char *scratchDir,
                                                    int64_t streamingThresholdBytes,
                                                    int loadConcurrency,
                                                    bool useGPU) {
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

        return medianImageFromMats(mats, outlierThreshold, includeAll, cv::Mat(), useGPU);
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
        cv::Mat mask = mask_ref->mat;
        if (mask.channels() > 1) {
            cv::Mat grey;
            cv::cvtColor(mask, grey, cv::COLOR_BGR2GRAY);
            mask = grey;
        }
        cv::Mat binary;
        cv::threshold(mask, binary, 0, 1, cv::THRESH_BINARY);

        if (accum_ref && !accum_ref->mat.empty()) {
            // In place: the accumulator is the caller's to update, and cloning its 168MB for
            // every frame was most of what this cost. The 8-bit 0/1 plane is added straight in
            // as CV_32S (no separate converted copy); a size mismatch throws before anything
            // is written, so a failed call leaves the accumulator as it was. The result
            // shares the accumulator's buffer.
            cv::add(accum_ref->mat, binary, accum_ref->mat, cv::noArray(), CV_32S);
            return new MatWrapperImpl(MatWrapperImpl::Alias{}, accum_ref->mat);
        }
        cv::Mat frame32s;
        binary.convertTo(frame32s, CV_32S);
        return wrap(frame32s);
    } KHT_CATCH_LOG("ia_accumulate_one_horizon_mask")
    return nullptr;
}

MatWrapperRef ia_accumulate_from_files(MatWrapperRef accum_ref, const char **filenames, int count,
                                       uint8_t *outLoaded) {
    try {
        if (outLoaded) for (int i = 0; i < count; ++i) outLoaded[i] = 0;
        cv::Mat total;
        if (accum_ref && !accum_ref->mat.empty()) {
            total = accum_ref->mat.clone();
        }
        for (int i = 0; i < count; ++i) {
            MatWrapperRef ref = image_cache_load(filenames[i]);
            if (!ref) continue;   // a mask that is not there is not in the vote
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
            if (outLoaded) outLoaded[i] = 1;
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
                                   bool useGPUForSift,
                                   bool useGPUForAKAZE,
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

            // Off the black step at the mask's edge, which is ground-locked — see
            // kSkyKeypointCutMargin.  The star mask alone does not keep keypoints off it:
            // the bright sky above the step clears its threshold, and its dilation then
            // reaches across the step into the black.  Applied to the mask rather than to
            // the keypoints afterwards, so the step cannot use up SIFT's keypoint cap. (That
            // premise holds for both SIFT paths now that each applies this mask before its cap;
            // cv::SIFT used to cap first, so the step could use up the cap there.)
            cv::Mat clear = awayFromMaskEdge(detectHorizonMask, kSkyKeypointCutMargin);
            if (cv::countNonZero(clear) > 0) {
                cv::bitwise_and(detectionMask, clear, detectionMask);
            } else {
                Log_d("sky region narrower than the %dpx keypoint margin, keeping the "
                      "keypoints it would have excluded", kSkyKeypointCutMargin);
            }
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

            // Kept as a plain constant (not just AKAZE's setThreshold argument
            // below) because the from-scratch GPU port below needs the exact
            // same value — see the long comment on it a few lines down.
            const float earthDetectorThreshold = 1e-4f;

            // useGPUForAKAZE: try the from-scratch GPU-accelerated port first —
            // see AKAZEDetector.cpp for why this exists as a separate
            // implementation rather than a hook into real cv::AKAZE, and
            // Config.useGPUForAKAZE's doc comment for why it defaults off and
            // is gated separately from Config.useGPU and Config.useGPUForSIFT.
            // Any failure (no GPU handler registered, or the handler itself
            // failing) falls back to real cv::AKAZE wholesale — not partially,
            // since there is no seam to fall back within a hand-ported
            // pipeline once it is committed to.
            bool usedGPUPort = false;
            if (useGPUForAKAZE) {
                usedGPUPort = star_akaze::akazeDetectAndComputeGPU(
                  baseImageProcessed, detectionMask, maxKeypoints, earthDetectorThreshold,
                  keypoints, descriptors);
            }
            if (usedGPUPort) {
                // Falls through to the coordinate-mapping/return code below,
                // exactly like real cv::AKAZE's output would.
            } else {

            cv::Ptr<cv::AKAZE> akazeBase = cv::AKAZE::create();

            // 1e-4, not the 1e-5 this was, and not OpenCV's 1e-3 default.
            //
            // Every keypoint past `maxKeypoints` is thrown away by retainBest below, so
            // the only thing the threshold has to do is leave comfortably more than that
            // cap standing.  1e-5 is AKAZE's `min_dthreshold` — the floor, not a choice —
            // and it leaves far more than comfortably more: on a 7008x4672 frame with a
            // real horizon mask it detects 105,792 candidates to keep 2,000, and the
            // extrema search for the other 103,792 is pure waste.
            //
            // Measured across three sequences (detect core-ms / raw candidates, against
            // the shipped preprocessing and real horizon masks):
            //
            //                         1e-5           1e-4            5e-4
            //   a7iv-1  7008x4672   27,538/105,792  15,746/80,714   12,160/31,120
            //   a7sii-1 4240x2832    8,426/ 56,468   4,307/15,860    6,137/ 2,230
            //
            // The retained 2,000 are *the same detections* at 1e-4 — identical position,
            // size, angle, response, octave and descriptor, verified byte for byte on
            // both sequences — because the threshold only removes candidates that ranked
            // below the cap anyway.  What it buys is about 2x off the detect half.
            //
            // The saving plateaus immediately (5e-5, 1e-4 and 2e-4 all land within noise
            // of each other), because what is left is the nonlinear diffusion pyramid,
            // which costs the same whatever the threshold.  So there is nothing to win by
            // going higher and a real margin to lose: at 5e-4 the a7sii frame detects
            // 2,230 against a cap of 2,000 and the retained set starts to change, and at
            // 1e-3 it finds 1,244 and misses the cap entirely.  1e-4 keeps roughly 8x the
            // cap on the thinnest ground measured here.
            //
            // The margin is what matters, not the speed, because the frames this could
            // hurt are the ones with almost no ground detail to begin with — see
            // toGray8UWithMask above for the 24MP frame that yielded 913 keypoints in a
            // 163px band.  A ground that thin already fails groundConsensusIsUsable and
            // drops out of the earth merge, so what is at stake is the margin before that
            // happens, which is why this sits two decades below where the saving stops.
            akazeBase->setThreshold(earthDetectorThreshold);

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

            } // usedGPUPort fallback
        } else {
            // useGPUForSift: try the from-scratch GPU-accelerated port first — see
            // SIFTDetector.cpp for why this exists as a separate implementation
            // rather than a hook into real cv::SIFT, and Config.useGPUForSIFT's
            // doc comment for why it defaults off and is gated separately from
            // Config.useGPU. Any failure (no GPU handler registered, or the
            // handler itself failing) falls back to real cv::SIFT wholesale —
            // not partially, since there is no seam to fall back within a
            // hand-ported pipeline once it is committed to.
            bool usedGPUPort = false;
            if (useGPUForSift) {
                usedGPUPort = star_sift::siftDetectAndComputeGPU(
                  detectGray, detectionMask, maxKeypoints, keypoints, descriptors);
            }
            if (!usedGPUPort) {
                // cv::SIFT applies its keypoint cap BEFORE the mask, so a capped detectAndCompute
                // keeps the strongest N of the whole frame and then drops those outside the mask
                // (the port above masks first). Detect uncapped with the mask, keep the strongest
                // N of what the mask allows, then describe only those.
                cv::Ptr<cv::SIFT> siftBase = cv::SIFT::create(0);
                siftBase->detect(detectGray, keypoints, detectionMask);
                if (maxKeypoints > 0 && (int)keypoints.size() > maxKeypoints) {
                    cv::KeyPointsFilter::retainBest(keypoints, maxKeypoints);
                }
                siftBase->compute(detectGray, keypoints, descriptors);
            }
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
        std::vector<cv::Point2f> stars;
        if (alignmentType == AlignmentTypeSky) {
            // The sky, held off the cut by the same margin the keypoints keep — given in
            // detection pixels, so scaled up to the full-resolution frame's.
            cv::Mat starMask = awayFromMaskEdge(
              horizonMask, (int)std::lround(kSkyKeypointCutMargin / scale));
            if (cv::countNonZero(starMask) == 0) starMask = horizonMask;
            stars = findStarCentroids(baseImage->mat, starMask);
            Log_d("frame %d: %zu sky keypoints, %zu star centroids",
                  frameIndex, keypoints.size(), stars.size());
        }
        auto *features = new OCVFeatureSetImpl(keypoints, descriptors);
        features->stars = std::move(stars);
        return features;
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

// Fit the transform relating two frames' correspondences: a full homography for the sky,
// a camera rotation for the ground.
//
// The sky gets 8 degrees of freedom because it has the geometry to support them —
// keypoints are stars, they cover the whole frame, and the fit is heavily
// over-determined.  Measured, feeding the *identical* sky feature set in reversed order
// moves the resulting warp's frame corners by 0.00-0.59px: RANSAC lands in the same place
// however it samples, which is what a well-conditioned fit looks like.
//
// The ground has none of that.  It is the bottom of the frame, so its inliers sit in a
// band measured at 87-98% of the frame width by **11-42% of its height** across seven
// pairs on two sequences.  Points that flat do not constrain a homography's vertical and
// perspective terms at all: the fit satisfies every inlier it sampled and is then free to
// do anything above and below them, and it does.  The same reversed-order test moves the
// ground warp 11.5-99.5px, and against phase correlation over the same band the fitted
// warp came out 8-25x the true ground motion.
//
// That is degeneracy, not noise, and nothing downstream can see it.  In particular
// groundConsensusIsUsable cannot: it reads an inlier *ratio*, which measured 0.87-0.88 on
// exactly these fits — high **because** the model has enough freedom to explain whatever
// RANSAC sampled.  A ratio asks whether the correspondences agree with the model, never
// whether they constrain it.
//
// So the ground gets a model its evidence can carry.  The first one was a 4-DOF
// similarity — rotation, uniform scale and translation, cv::estimateAffinePartial2D — and
// on those seven pairs it moved 0.00-4.65px under reordered input where the homography
// moved 11.5-99.5, and landed 2-5x closer to the motion phase correlation measured.
// Affine's 6 DOF sat in between (0.75-31.3px), and tightening the RANSAC threshold did not
// rescue the homography (10px: 99.3, 3px: 66.3, 1.5px: 110.1 on the first pair): the
// problem was the model, not the tolerance.  A guard rejecting fits whose inliers are too
// flat was the other candidate, and was rejected: the 42%-tall band is still degenerate,
// so the cutoff would have had to throw away nearly every ground fit.
//
// But a similarity is the wrong shape for what a panning head does.  A camera turning
// about its own centre moves everything it sees by a homography, K R K^-1, however far
// away it is, and the horizontal shift that homography gives a point grows towards the
// frame edges as 1 + x²/f²: with a 20mm lens on full frame the edges move nearly twice
// as far as the centre.  A similarity's shift is linear in x, so the best it can do is split
// the difference, and it leaves a U-shaped residual across the frame, mirrored between
// earlier and later neighbours.  Measured on the moving 10_17_2026 a9-1 sequence by
// phase-correlating every warped +-4 neighbour against its base frame in 384x256 patches
// just below the skyline (17 frames, 5984 measurements): the nine samples the merge picks
// from at a pixel sat 13.3px apart horizontally at the frame edges (median; p90 25.7),
// and 5.2px in the centre.  A median over samples spread that far is a sideways median
// filter.  The run's own earth merge, replayed bit for bit from its homography.db, kept
// 0.44 of the frame's medium-scale ground detail at the edges and 0.62 in the centre, and
// looked motion-blurred.  The same residual cost the similarity its stability there: many
// correspondences sat near the RANSAC threshold, and which consensus won depended on the
// sampling order (median 1.1px, worst 22.5px in the ground).
//
// So the ground is fitted as that rotation.  Three degrees of freedom, each with its own
// signature even on a thin band — yaw a shift with the 1 + x²/f² curvature, pitch a
// vertical shift, roll a vertical slope across the width — and no projective terms left
// over to do anything above and below the band.  Against the similarity it replaced, on
// the same correspondences:
//
//                  edge |dx| at +-4   inlier rms     reordered input, worst   edge detail kept
//   10_17 a9-1       6.83 -> 0.20     2.62 -> 1.70     22.5 -> 0.09px           0.44 -> 0.71
//   03_16 a9-2       4.25 -> 0.08     2.59 -> 1.25      9.3 -> 0.11             0.68 -> 0.89
//   08_15 a7iv       8.20 -> 0.73     2.74 -> 1.74     12.8 -> 0.00             0.25 -> 0.41
//
// |dx| and the detail are by phase correlation and band-pass energy against the base
// frame, as above, with the merge replayed; the rms is over the correspondences both fits
// keep, and lower on 94-100% of pairs.  On grounds too dark to show the curvature — a
// black mountain silhouette, a black-clipped foreground — most frames cannot calibrate
// (see calibrateGroundFocalLength) and the fit does about as well as the similarity did,
// rms 3.21 -> 3.24px and 2.79 -> 2.53px, still reorder-stable: nothing is lost where there
// was nothing to gain.
//
// The rotation needs the focal length, and these frames do not carry it: exported TIFFs
// have no EXIF.  The correspondences know it, because f sets the curvature above, so each
// frame calibrates its own over all of its neighbours — see calibrateGroundFocalLength.
// The principal point is the frame centre, which an uncropped frame satisfies.  A crop
// that moved it sideways is the model's weak point: 300px off cost 2.9px at the edges of
// the 10_17 frames above, and 600px 5.5px, most of the similarity's 6.8.
//
// The 3x3 is so everything downstream — warpInto, the continuity filter, homography.db,
// the earth chains, the deviation norm — keeps taking one kind of matrix.
//
// The sky's RANSAC tolerance is 3px, not the ground's 10.  A star homography fits real
// stars to a fraction of a pixel — thousands of matched star centroids sat within
// 0.27-0.48px RMS of one homography on every pair measured — so 10px never bought the
// sky anything but room for matches that are not stars.  Where stars are plentiful the
// consensus is wide enough that it does not matter; where they are few (moonlit and
// twilight frames, 20-60 star inliers per pair) it did: with the horizon keypoints
// already excluded (kSkyKeypointCutMargin), 10px still let three of eight neighbours of
// one frame lock onto a wrong consensus, 2.6-15px off, where 3px put all eight within
// 0.1-0.4px of the stars.
//
// Never the tolerance alone, though.  3px with the horizon keypoints still present looks
// better than it is: the ground-locked matches form a consensus of their own, and a fit
// to it is as consistent between neighbouring frames as a fit to the stars, so it passes
// the reciprocity check while 3px wrong.
static constexpr double kSkyRansacThreshold = 3.0;
static constexpr double kGroundRansacThreshold = 10.0;

namespace {
// A pinhole camera centred on the frame, which is what a ground rotation is expressed in.
struct GroundCamera {
    double f = 0, cx = 0, cy = 0;
};

// One neighbour's correspondences, for calibrateGroundFocalLength.
struct GroundPair {
    const std::vector<cv::Point2f> *from = nullptr, *to = nullptr;
    uint64_t seed = 0;
};
}

static GroundCamera groundCamera(int width, int height, double f) {
    GroundCamera camera;
    camera.f = f;
    camera.cx = (width - 1) / 2.0;
    camera.cy = (height - 1) / 2.0;
    return camera;
}

static std::vector<cv::Vec3d> groundBearings(const std::vector<cv::Point2f> &points,
                                             const GroundCamera &camera) {
    std::vector<cv::Vec3d> bearings(points.size());
    for (size_t i = 0; i < points.size(); ++i) {
        const cv::Vec3d v((points[i].x - camera.cx) / camera.f,
                          (points[i].y - camera.cy) / camera.f, 1.0);
        bearings[i] = v * (1.0 / cv::norm(v));
    }
    return bearings;
}

// Squared distance from `target` to where bearing `b` lands once the camera has turned by
// R.  A bearing turned behind the camera can only come from a nonsense hypothesis, and
// lands nowhere.
static double groundError2(const cv::Matx33d &R, const cv::Vec3d &b,
                           const cv::Point2f &target, const GroundCamera &camera) {
    const cv::Vec3d q = R * b;
    if (q[2] <= 1e-9) return std::numeric_limits<double>::infinity();
    const double dx = camera.cx + camera.f * q[0] / q[2] - target.x;
    const double dy = camera.cy + camera.f * q[1] / q[2] - target.y;
    return dx * dx + dy * dy;
}

static cv::Matx33d rotationFromVector(const cv::Vec3d &w) {
    const double angle = cv::norm(w);
    if (angle < 1e-15) return cv::Matx33d::eye();
    const cv::Vec3d k = w * (1.0 / angle);
    const cv::Matx33d K(0, -k[2], k[1], k[2], 0, -k[0], -k[1], k[0], 0);
    return cv::Matx33d::eye() + std::sin(angle) * K + (1 - std::cos(angle)) * (K * K);
}

// rotationFromVector's inverse, for the small rotations a pan makes between frames.
static cv::Vec3d rotationVector(const cv::Matx33d &R) {
    const cv::Vec3d axis(R(2, 1) - R(1, 2), R(0, 2) - R(2, 0), R(1, 0) - R(0, 1));
    const double s = 0.5 * cv::norm(axis);                     // sin of the angle
    const double c = 0.5 * (R(0, 0) + R(1, 1) + R(2, 2) - 1);  // cos of the angle
    if (s < 1e-12) return axis * 0.5;
    return axis * (std::atan2(s, c) / (2 * s));
}

// A ground rotation fitted at focal length `from`, carried to `to` so that it moves the
// middle of the frame by as many pixels as it did: pan and tilt shift the image by f
// times their angle, so they scale by from/to, and roll turns it whatever f is.
static cv::Matx33d carryGroundRotation(const cv::Matx33d &R, double from, double to) {
    cv::Vec3d w = rotationVector(R);
    w[0] *= from / to;
    w[1] *= from / to;
    return rotationFromVector(w);
}

// The rotation taking two bearings onto two others, least squares (Kabsch), with their
// cross products as a third pair so that two correspondences are enough.
static cv::Matx33d rotationFromTwoBearings(const cv::Vec3d &u1, const cv::Vec3d &u2,
                                           const cv::Vec3d &v1, const cv::Vec3d &v2) {
    const cv::Matx33d C = v1 * u1.t() + v2 * u2.t() + v1.cross(v2) * u1.cross(u2).t();
    cv::Matx31d w;
    cv::Matx33d U, Vt;
    cv::SVD::compute(C, w, U, Vt);
    const double d = cv::determinant(U * Vt) > 0 ? 1.0 : -1.0;
    return U * cv::Matx33d(1, 0, 0, 0, 1, 0, 0, 0, d) * Vt;
}

// Gauss-Newton on pixel reprojection error over `use`, updating R <- exp([w]x) R.  Three
// parameters and a good start, so it converges in two or three steps.
static cv::Matx33d refineGroundRotation(cv::Matx33d R, const std::vector<cv::Vec3d> &bearings,
                                        const std::vector<cv::Point2f> &to,
                                        const std::vector<int> &use,
                                        const GroundCamera &camera) {
    if (use.size() < 2) return R;
    for (int iteration = 0; iteration < 10; ++iteration) {
        cv::Matx33d JtJ = cv::Matx33d::zeros();
        cv::Vec3d Jtr(0, 0, 0);
        for (int i : use) {
            const cv::Vec3d q = R * bearings[i];
            const double iz = 1.0 / q[2];
            const cv::Vec2d r(camera.cx + camera.f * q[0] * iz - to[i].x,
                              camera.cy + camera.f * q[1] * iz - to[i].y);
            // dq/dw is -[q]x; then the projection's derivative
            const cv::Matx33d dq(0, q[2], -q[1], -q[2], 0, q[0], q[1], -q[0], 0);
            const cv::Matx23d dp(camera.f * iz, 0, -camera.f * q[0] * iz * iz,
                                 0, camera.f * iz, -camera.f * q[1] * iz * iz);
            const cv::Matx23d J = dp * dq;
            JtJ += J.t() * J;
            Jtr += J.t() * r;
        }
        const cv::Vec3d step = JtJ.solve(-Jtr, cv::DECOMP_CHOLESKY);
        R = rotationFromVector(step) * R;
        if (cv::norm(step) < 1e-8) break;
    }
    return R;
}

// The consensus of R at the RANSAC tolerance, least squares over it, and a fresh
// consensus from the result, until it stops changing (three rounds at most).  The first
// consensus comes from a two-point hypothesis, and in calibration from a focal length that
// may be well off; every correspondence it missed for either reason gets another chance
// against the refined rotation.  `inliers` and `truncatedCost` — the sum over every
// correspondence of its squared error, capped at the tolerance — describe the result.
static cv::Matx33d polishGroundRotation(cv::Matx33d R, const std::vector<cv::Vec3d> &bearings,
                                        const std::vector<cv::Point2f> &to,
                                        const GroundCamera &camera,
                                        std::vector<uchar> *inliers, double *truncatedCost) {
    const double limit = kGroundRansacThreshold * kGroundRansacThreshold;
    std::vector<int> use, previous;
    for (int round = 0; round < 3; ++round) {
        use.clear();
        for (size_t i = 0; i < bearings.size(); ++i) {
            if (groundError2(R, bearings[i], to[i], camera) < limit) use.push_back((int)i);
        }
        if (use.size() < 2 || use == previous) break;
        R = refineGroundRotation(R, bearings, to, use, camera);
        previous = use;
    }
    double cost = 0;
    if (inliers) inliers->assign(bearings.size(), 0);
    for (size_t i = 0; i < bearings.size(); ++i) {
        const double e = groundError2(R, bearings[i], to[i], camera);
        cost += std::min(e, limit);
        if (inliers && e < limit) (*inliers)[i] = 1;
    }
    if (truncatedCost) *truncatedCost = cost;
    return R;
}

static constexpr int    kGroundRansacMinIterations = 100;
static constexpr int    kGroundRansacMaxIterations = 2000;
static constexpr double kGroundRansacConfidence    = 0.995;

// The ground's rotation from its correspondences: RANSAC over two-correspondence samples,
// which is all a rotation needs, then polishGroundRotation.  Draws from cv::theRNG(), which
// the caller seeds per frame pair, so a pair always gets the same answer.
static bool fitGroundRotation(const std::vector<cv::Point2f> &from,
                              const std::vector<cv::Point2f> &to,
                              const GroundCamera &camera, cv::Matx33d &rotation,
                              std::vector<uchar> *inliers, double *truncatedCost) {
    const int n = (int)from.size();
    if (n < 2) return false;
    const std::vector<cv::Vec3d> fromBearings = groundBearings(from, camera);
    const std::vector<cv::Vec3d> toBearings = groundBearings(to, camera);
    const double limit = kGroundRansacThreshold * kGroundRansacThreshold;

    cv::RNG &rng = cv::theRNG();
    int bestCount = -1;
    double bestError = 0;
    cv::Matx33d best = cv::Matx33d::eye();
    int iterations = kGroundRansacMaxIterations;
    for (int it = 0; it < iterations; ++it) {
        const int a = rng.uniform(0, n), b = rng.uniform(0, n);
        // two correspondences in the same place say nothing about the roll
        if (a == b || cv::norm(from[a] - from[b]) < 4.0) continue;
        const cv::Matx33d R = rotationFromTwoBearings(fromBearings[a], fromBearings[b],
                                                      toBearings[a], toBearings[b]);
        int count = 0;
        double error = 0;
        for (int i = 0; i < n; ++i) {
            const double e = groundError2(R, fromBearings[i], to[i], camera);
            if (e < limit) { ++count; error += e; }
        }
        if (count > bestCount || (count == bestCount && error < bestError)) {
            bestCount = count;
            bestError = error;
            best = R;
            // how many draws until a clean pair has turned up with that confidence
            const double share = (double)count / n;
            const double miss = std::log(std::max(1e-12, 1.0 - share * share));
            const double needed = miss < 0
              ? std::ceil(std::log(1.0 - kGroundRansacConfidence) / miss)
              : (double)kGroundRansacMaxIterations;
            iterations = (int)std::min<double>(kGroundRansacMaxIterations,
                                               std::max<double>(kGroundRansacMinIterations, needed));
        }
    }
    if (bestCount < 2) return false;
    rotation = polishGroundRotation(best, fromBearings, to, camera, inliers, truncatedCost);
    return true;
}

// K R K^-1, scaled so its last element is 1 as the sky's is.
static cv::Mat groundHomography(const cv::Matx33d &R, const GroundCamera &camera) {
    const cv::Matx33d K(camera.f, 0, camera.cx, 0, camera.f, camera.cy, 0, 0, 1);
    const cv::Matx33d Kinv(1 / camera.f, 0, -camera.cx / camera.f,
                           0, 1 / camera.f, -camera.cy / camera.f, 0, 0, 1);
    cv::Matx33d H = K * R * Kinv;
    H *= 1.0 / H(2, 2);
    return cv::Mat(H, true);
}

// `camera` is the ground's, and is not read for the sky.
static cv::Mat estimateAlignment(AlignmentType alignmentType, const GroundCamera &camera,
                                 const std::vector<cv::Point2f> &from,
                                 const std::vector<cv::Point2f> &to,
                                 std::vector<uchar> &inlierMask) {
    if (alignmentType != AlignmentTypeEarth) {
        return cv::findHomography(from, to, cv::RANSAC, kSkyRansacThreshold, inlierMask);
    }
    cv::Matx33d R;
    if (!fitGroundRotation(from, to, camera, R, &inlierMask, nullptr)) return cv::Mat();
    return groundHomography(R, camera);
}

// The focal length a frame's ground rotations are fitted at, from that frame's own
// correspondences: the one whose rotations explain them best, summed over every neighbour.
//
// It can be found because the curvature of a pan can be seen: the edges of the ground move
// 1 + x²/f² times as far as its centre, and only the right f makes rotations reproduce that
// across the whole width.  The score is the sum over every correspondence of its squared
// reprojection error capped at the RANSAC tolerance, so a mismatch counts no more than a
// miss.  Each pair's consensus is drawn once, by RANSAC at a nominal focal length, and only
// carried to each candidate and polished there after that (carryGroundRotation), so the
// search costs least squares rather than RANSAC: a logarithmic scan from a quarter of the
// frame's width to twenty widths, then a golden section around the best of it.
//
// Measured per frame against plate solves of the same sequences (catalogue stars fitted
// with the same pinhole camera): 10_17 a9-1 3227px against a median of 3240 over 188
// frames (p10-p90 3187-3274), and the a7iv on 08_15 4596px against 4580 over 23 frames
// (4496-4630).  A 10% error would cost 0.8px at the edges of a +-4 neighbour on 10_17,
// where the similarity left 6.8, so that spread is immaterial.
//
// There is nothing to see when nothing moves, or when the ground is too dark to show it:
// then every focal length explains the correspondences about equally well and the scan's
// minimum is noise.  The gain over the longest focal length tells the two apart — at least
// 17.6% on every frame of two textured sequences, at most 6.0% on any of 91 frames of a
// black mountain silhouette, and under 10% on 10_17 only for the five frames before its
// pan gets going — and below kGroundFocalMinGain a frame takes the longest.  That one
// has no curvature to speak of, so its rotations pan like translations: what a ground that
// shows no curvature looks like, and harmless where nothing moved.
static constexpr double kGroundFocalMinWidths     = 0.25;
static constexpr double kGroundFocalMaxWidths     = 20.0;
static constexpr double kGroundFocalNominalWidths = 0.6;
static constexpr double kGroundFocalScanStep      = 1.25;
static constexpr int    kGroundFocalRefinements   = 14;
static constexpr double kGroundFocalMinGain       = 0.10;
// Correspondences per pair the search reads: an even sample, since f only has to be about
// right (see above) and the rotations are fitted from all of them afterwards.
static constexpr size_t kGroundFocalMaxCorrespondences = 400;

static double calibrateGroundFocalLength(const std::vector<GroundPair> &pairs,
                                         int width, int height, int frameIndex) {
    const double longest = kGroundFocalMaxWidths * width;

    // The sample is taken in the order of the base frame's points, not of the matches, so
    // that the focal length depends on which correspondences there are and not on the
    // order they arrived in — the same property the rotations themselves have.
    std::vector<std::vector<cv::Point2f>> from(pairs.size()), to(pairs.size());
    for (size_t k = 0; k < pairs.size(); ++k) {
        const std::vector<cv::Point2f> &base = *pairs[k].to;
        std::vector<size_t> order(base.size());
        for (size_t i = 0; i < order.size(); ++i) order[i] = i;
        std::sort(order.begin(), order.end(), [&](size_t a, size_t b) {
            return base[a].y != base[b].y ? base[a].y < base[b].y : base[a].x < base[b].x;
        });
        const size_t every = std::max<size_t>(
          1, (order.size() + kGroundFocalMaxCorrespondences - 1) / kGroundFocalMaxCorrespondences);
        for (size_t i = 0; i < order.size(); i += every) {
            from[k].push_back((*pairs[k].from)[order[i]]);
            to[k].push_back(base[order[i]]);
        }
    }

    const GroundCamera nominal =
      groundCamera(width, height, kGroundFocalNominalWidths * width);
    std::vector<cv::Matx33d> starts(pairs.size());
    std::vector<bool> started(pairs.size(), false);
    double correspondences = 0;
    for (size_t k = 0; k < pairs.size(); ++k) {
        cv::theRNG() = cv::RNG(pairs[k].seed);
        started[k] = fitGroundRotation(from[k], to[k], nominal, starts[k], nullptr, nullptr);
        if (started[k]) correspondences += from[k].size();
    }
    if (correspondences == 0) return longest;

    auto cost = [&](double f) {
        const GroundCamera camera = groundCamera(width, height, f);
        double total = 0;
        for (size_t k = 0; k < pairs.size(); ++k) {
            if (!started[k]) continue;
            double pairCost = 0;
            polishGroundRotation(carryGroundRotation(starts[k], nominal.f, f),
                                 groundBearings(from[k], camera), to[k], camera,
                                 nullptr, &pairCost);
            total += pairCost;
        }
        return total / correspondences;
    };

    std::vector<double> scanned, costs;
    for (double f = kGroundFocalMinWidths * width; f < longest; f *= kGroundFocalScanStep) {
        scanned.push_back(f);
        costs.push_back(cost(f));
    }
    scanned.push_back(longest);
    costs.push_back(cost(longest));
    const size_t best = std::min_element(costs.begin(), costs.end()) - costs.begin();

    double lo = std::log(scanned[best > 0 ? best - 1 : 0]);
    double hi = std::log(scanned[std::min(best + 1, scanned.size() - 1)]);
    const double golden = (std::sqrt(5.0) - 1) / 2;
    double x1 = hi - golden * (hi - lo), x2 = lo + golden * (hi - lo);
    double c1 = cost(std::exp(x1)), c2 = cost(std::exp(x2));
    for (int i = 0; i < kGroundFocalRefinements; ++i) {
        if (c1 < c2) {
            hi = x2; x2 = x1; c2 = c1;
            x1 = hi - golden * (hi - lo); c1 = cost(std::exp(x1));
        } else {
            lo = x1; x1 = x2; c1 = c2;
            x2 = lo + golden * (hi - lo); c2 = cost(std::exp(x2));
        }
    }
    const double f = std::exp(c1 < c2 ? x1 : x2);
    const double fCost = std::min(c1, c2);
    const double gain = costs.back() > 0 ? 1.0 - fCost / costs.back() : 0.0;
    if (gain < kGroundFocalMinGain) {
        Log_d("frame %d: ground focal length not observable (%.1f%% better than none at "
              "%.0fpx), fitting at %.0fpx", frameIndex, gain * 100, f, longest);
        return longest;
    }
    Log_d("frame %d: ground focal length %.0fpx (%.3f widths) over %zu neighbours, %.1f%% "
          "better than none", frameIndex, f, f / width, pairs.size(), gain * 100);
    return f;
}

// Whether RANSAC's consensus set is enough evidence to warp a frame's ground by the
// homography it elected.  Ground only — see below for why the sky is left alone.
//
// findHomography always returns a matrix if it can solve four points, and says nothing
// about whether the rest of the correspondences agreed.  On a ground that has features
// that is a formality: the fit explains nearly everything Lowe's ratio test let
// through.  On a ground that does not, RANSAC picks whichever quartet happened to be
// mutually consistent and reports it with the same confidence — and the result is not
// slightly wrong, it is a near-180-degree rotation that smears the terrain across the
// frame.  A whole sequence of those is what a black-clipped foreground produces, and
// nothing downstream can tell them from real motion: the continuity filter in
// AlignmentValidationOp compares each warp against its neighbours', which only works
// while the neighbours are right.
//
// So the test is on the evidence, not on the answer: no threshold here asks how far
// the warp moves the ground, because a fast pan legitimately moves it a long way.
// Measured across 29 frame pairs at offsets -1 and +4, on the two 08_15_2026 aurora
// sequences shot side by side — one exported 16-bit from raw, the other extracted from
// a 10-bit video whose ground had been crushed to black:
//
//                        inlier ratio     inliers
//   ground with detail   0.86 - 0.94     108 - 304     (13 pairs, every warp sane)
//   ground crushed flat  0.06 - 0.56       5 -  63     (16 pairs, every warp garbage)
//
// The two do not overlap and the gap is wide, so the cutoffs sit nearer the failing
// side: a sequence that is merely hard to track should keep being tracked.
//
// Those were homography fits; the rotation that replaced them reads the same.  On five
// sequences it passes every pair the similarity before it passed, and one more, and with
// a share of a pair's correspondences re-paired at random its inlier ratio follows the
// share left intact as the similarity's did — 0.79 with a fifth re-paired, 0.49 with
// half, 0.10 with nine tenths — so the cutoffs still mean what they were set to mean.
//
// Not applied to the sky, where a low ratio is normal rather than damning.  Stars all
// look alike, so SIFT descriptors collide and Lowe's test passes many pairs RANSAC
// then rejects.  The same measurement over the sky of the crushed sequence read
// ratios of 0.61, 0.73 and 0.94 for three homographies that were all correct (they
// moved the sky 4.9, 23.5 and 6.5px) — two of the three would have failed this test.
// The sky also has no graceful fallback: a missing ground warp costs one source in a
// median merge, a missing sky warp costs the frame.
static constexpr double kMinGroundInlierRatio = 0.65;
static constexpr int    kMinGroundInliers     = 20;

static bool groundConsensusIsUsable(AlignmentType alignmentType,
                                    const std::vector<uchar> &inlierMask,
                                    size_t correspondences,
                                    int frameIndex, int neighborFrameIndex) {
    if (alignmentType != AlignmentTypeEarth) return true;
    // RANSAC fills the mask; anything else leaves it empty and is not judged here.
    if (inlierMask.empty() || correspondences == 0) return true;

    int inliers = 0;
    for (uchar flag : inlierMask) if (flag) inliers++;
    const double ratio = (double)inliers / (double)correspondences;

    if (inliers >= kMinGroundInliers && ratio >= kMinGroundInlierRatio) return true;

    Log_d("frame %d ground homography to %d rejected: %d of %zu correspondences agreed "
          "(%.2f), below %d and %.2f",
          frameIndex, neighborFrameIndex, inliers, correspondences, ratio,
          kMinGroundInliers, kMinGroundInlierRatio);
    return false;
}

// --- Refining the sky homography against star centroids ----------------------
//
// The keypoint fit says roughly how the sky moved; the stars say exactly.  Under the
// rough fit each of the neighbour's stars should land within a few pixels of the same
// star in the base frame, so the true correction shows up as a sharp peak among the
// offsets to nearby stars, while chance neighbours spread thin.  The peak is found per
// region of the frame, not once, because a homography's error varies across the frame
// — that is how the moonlit failure looked, right in one corner and wrong elsewhere.
// The stars it gathers seed a least-squares fit, which then re-associates every star
// to its unique neighbour within kStarMatchRadius and refits, four times over.
//
// Measured on the moving moonlit 10_17_2026 a9-1 sequence against an independent fit
// of the same centroids: it agrees with clean dark-sky fits to 0.03-0.08px, recovers
// from a keypoint fit 19px wrong, and in twilight — where SIFT gets 7-18 inliers per
// pair and the shipped fits were off by up to 32px — converges to the same matrix from
// a donor's homography or from no motion at all (0.00-0.02px apart) with ~4000 pairs
// at 0.36px RMS.
static constexpr float  kStarVoteRadius    = 25.f;   // how wrong the seed may be
static constexpr float  kStarVoteBin       = 0.5f;
static constexpr int    kStarRegionsX      = 6, kStarRegionsY = 4;
static constexpr float  kStarMatchRadius   = 1.5f;
// A chance coincidence within kStarMatchRadius happens for about 1 star in 200 at
// these densities, so a few hundred pairs cannot be luck; a cloud-covered or empty sky
// simply fails this and keeps the keypoint fit.
static constexpr int    kStarMinPairs      = 100;
static constexpr double kStarMaxRmsPx      = 1.0;
// The pairs must reach at least half the regions that hold stars.  A seed that is right
// in one corner and wrong elsewhere can grow a "fit" from that corner alone: in twilight
// it reached 245-488 pairs at ~1px RMS while 58-108px wrong across the frame — and
// covered 5-8 of 24 regions, where every correct fit measured covered 12-24.
static constexpr double kStarMinCoverage   = 0.5;

// Points bucketed on a uniform grid, for "every point within r of q".
class StarGrid {
public:
    StarGrid(const std::vector<cv::Point2f> &points, float cell) : points_(points), cell_(cell) {
        if (points.empty()) return;
        float maxX = points[0].x, maxY = points[0].y;
        minX_ = maxX; minY_ = maxY;
        for (const auto &p : points) {
            minX_ = std::min(minX_, p.x); maxX = std::max(maxX, p.x);
            minY_ = std::min(minY_, p.y); maxY = std::max(maxY, p.y);
        }
        cols_ = (int)((maxX - minX_) / cell_) + 1;
        rows_ = (int)((maxY - minY_) / cell_) + 1;
        bins_.assign((size_t)cols_ * rows_, {});
        for (int i = 0; i < (int)points.size(); ++i) {
            const int cx = (int)((points[i].x - minX_) / cell_);
            const int cy = (int)((points[i].y - minY_) / cell_);
            bins_[(size_t)cy * cols_ + cx].push_back(i);
        }
    }

    // body(index, point - q) for every point within r of q.
    template <class Body>
    void within(cv::Point2f q, float r, Body &&body) const {
        if (bins_.empty()) return;
        const int x0 = std::max(0, (int)std::floor((q.x - r - minX_) / cell_));
        const int x1 = std::min(cols_ - 1, (int)std::floor((q.x + r - minX_) / cell_));
        const int y0 = std::max(0, (int)std::floor((q.y - r - minY_) / cell_));
        const int y1 = std::min(rows_ - 1, (int)std::floor((q.y + r - minY_) / cell_));
        for (int cy = y0; cy <= y1; ++cy) {
            for (int cx = x0; cx <= x1; ++cx) {
                for (int i : bins_[(size_t)cy * cols_ + cx]) {
                    const cv::Point2f d = points_[i] - q;
                    if (d.x * d.x + d.y * d.y <= r * r) body(i, d);
                }
            }
        }
    }

private:
    const std::vector<cv::Point2f> &points_;
    float cell_, minX_ = 0, minY_ = 0;
    int cols_ = 0, rows_ = 0;
    std::vector<std::vector<int>> bins_;
};

// The peak of a square 2-D histogram of `bins` x `bins` counts after a 3x3 box sum,
// and how far it stands above the typical occupied bin.
static void histogramPeak(const std::vector<int> &hist, int bins,
                          int &peakX, int &peakY, int &peak, double &contrast) {
    std::vector<int> summed((size_t)bins * bins, 0), occupied;
    peak = 0; peakX = peakY = bins / 2;
    for (int y = 1; y < bins - 1; ++y) {
        for (int x = 1; x < bins - 1; ++x) {
            int s = 0;
            for (int j = -1; j <= 1; ++j)
                for (int i = -1; i <= 1; ++i) s += hist[(size_t)(y + j) * bins + x + i];
            summed[(size_t)y * bins + x] = s;
            if (s > 0) occupied.push_back(s);
            if (s > peak) { peak = s; peakX = x; peakY = y; }
        }
    }
    if (occupied.empty()) { contrast = 0; return; }
    std::nth_element(occupied.begin(), occupied.begin() + occupied.size() / 2, occupied.end());
    contrast = (double)peak / std::max(1, occupied[occupied.size() / 2]);
}

// Star pairs (neighbour -> base) that agree, region by region, on one correction to
// `seed`.  A region with too few stars, or no clear peak, contributes none.
static void starPairsByRegionalVote(const std::vector<cv::Point2f> &nb,
                                    const std::vector<cv::Point2f> &base,
                                    const StarGrid &baseGrid, const cv::Mat &seed,
                                    std::vector<cv::Point2f> &src,
                                    std::vector<cv::Point2f> &dst) {
    std::vector<cv::Point2f> predicted;
    cv::perspectiveTransform(nb, predicted, seed);

    float minX = base[0].x, maxX = base[0].x, minY = base[0].y, maxY = base[0].y;
    for (const auto &p : base) {
        minX = std::min(minX, p.x); maxX = std::max(maxX, p.x);
        minY = std::min(minY, p.y); maxY = std::max(maxY, p.y);
    }
    const float regionW = std::max(1.f, (maxX - minX) / kStarRegionsX);
    const float regionH = std::max(1.f, (maxY - minY) / kStarRegionsY);

    struct Candidate { int nb, base; cv::Point2f offset; };
    std::vector<std::vector<Candidate>> regions(kStarRegionsX * kStarRegionsY);
    for (int i = 0; i < (int)predicted.size(); ++i) {
        const cv::Point2f q = predicted[i];
        const int rx = std::clamp((int)((q.x - minX) / regionW), 0, kStarRegionsX - 1);
        const int ry = std::clamp((int)((q.y - minY) / regionH), 0, kStarRegionsY - 1);
        auto &candidates = regions[(size_t)ry * kStarRegionsX + rx];
        baseGrid.within(q, kStarVoteRadius, [&](int k, cv::Point2f d) {
            candidates.push_back({i, k, d});
        });
    }

    const int bins = (int)(2 * kStarVoteRadius / kStarVoteBin);
    std::vector<int> hist((size_t)bins * bins);
    for (const auto &candidates : regions) {
        if (candidates.size() < 8) continue;
        std::fill(hist.begin(), hist.end(), 0);
        for (const auto &c : candidates) {
            const int bx = std::clamp((int)((c.offset.x + kStarVoteRadius) / kStarVoteBin), 0, bins - 1);
            const int by = std::clamp((int)((c.offset.y + kStarVoteRadius) / kStarVoteBin), 0, bins - 1);
            hist[(size_t)by * bins + bx]++;
        }
        int px, py, peak; double contrast;
        histogramPeak(hist, bins, px, py, peak, contrast);
        if (contrast < 4) continue;

        // the peak's bin centre, then the mean of the offsets around it
        cv::Point2f mode(-kStarVoteRadius + (px + 0.5f) * kStarVoteBin,
                         -kStarVoteRadius + (py + 0.5f) * kStarVoteBin);
        cv::Point2f sum(0, 0); int n = 0;
        for (const auto &c : candidates) {
            if (cv::norm(c.offset - mode) < 1.5) { sum += c.offset; ++n; }
        }
        if (n >= 3) mode = sum * (1.f / n);

        std::vector<const Candidate *> agreeing;
        for (const auto &c : candidates) {
            if (cv::norm(c.offset - mode) < 1.0) agreeing.push_back(&c);
        }
        if (agreeing.size() < 8) continue;
        for (const Candidate *c : agreeing) {
            src.push_back(nb[c->nb]);
            dst.push_back(base[c->base]);
        }
    }
}

// Of the regions holding at least 20 of the base frame's stars, the fraction holding at
// least 10 of `matched`, on the same 6x4 grid the vote uses.
static double starCoverage(const std::vector<cv::Point2f> &base,
                           const std::vector<cv::Point2f> &matched) {
    float minX = base[0].x, maxX = base[0].x, minY = base[0].y, maxY = base[0].y;
    for (const auto &p : base) {
        minX = std::min(minX, p.x); maxX = std::max(maxX, p.x);
        minY = std::min(minY, p.y); maxY = std::max(maxY, p.y);
    }
    const float regionW = std::max(1.f, (maxX - minX) / kStarRegionsX);
    const float regionH = std::max(1.f, (maxY - minY) / kStarRegionsY);
    auto region = [&](cv::Point2f p) {
        const int rx = std::clamp((int)((p.x - minX) / regionW), 0, kStarRegionsX - 1);
        const int ry = std::clamp((int)((p.y - minY) / regionH), 0, kStarRegionsY - 1);
        return ry * kStarRegionsX + rx;
    };
    std::vector<int> stars(kStarRegionsX * kStarRegionsY, 0), hits(stars.size(), 0);
    for (const auto &p : base) stars[region(p)]++;
    for (const auto &p : matched) hits[region(p)]++;
    int withStars = 0, covered = 0;
    for (size_t r = 0; r < stars.size(); ++r) {
        if (stars[r] < 20) continue;
        ++withStars;
        if (hits[r] >= 10) ++covered;
    }
    return withStars ? (double)covered / withStars : 0.0;
}

// Refine `seed` against the stars, or return an empty Mat when they do not support a
// fit (too few stars, too few that agree, or agreement confined to part of the sky).
static cv::Mat refineSkyFromSeed(const std::vector<cv::Point2f> &nb,
                                 const std::vector<cv::Point2f> &base,
                                 const StarGrid &baseGrid, const cv::Mat &seed,
                                 int &pairs, double &rms) {
    std::vector<cv::Point2f> src, dst;
    starPairsByRegionalVote(nb, base, baseGrid, seed, src, dst);
    if ((int)src.size() < kStarMinPairs) return cv::Mat();
    cv::Mat H = cv::findHomography(src, dst, 0);
    if (H.empty()) return cv::Mat();

    // A point at the same place in both frames is the sensor, not the sky: a hot pixel
    // or a dust shadow.  It cannot be a star wherever the sky has visibly moved, and
    // left in, it votes for no motion at all.
    std::vector<char> fixedPattern(nb.size(), 0);
    for (size_t i = 0; i < nb.size(); ++i) {
        baseGrid.within(nb[i], 0.5f, [&](int, cv::Point2f) { fixedPattern[i] = 1; });
    }

    std::vector<cv::Point2f> predicted;
    for (int iteration = 0; iteration < 4; ++iteration) {
        cv::perspectiveTransform(nb, predicted, H);
        src.clear(); dst.clear();
        for (size_t i = 0; i < nb.size(); ++i) {
            if (fixedPattern[i] && cv::norm(predicted[i] - nb[i]) > 1.0) continue;
            int match = -1, found = 0;
            baseGrid.within(predicted[i], kStarMatchRadius, [&](int k, cv::Point2f) {
                match = k; ++found;
            });
            if (found == 1) { src.push_back(nb[i]); dst.push_back(base[match]); }
        }
        if ((int)src.size() < kStarMinPairs) return cv::Mat();
        cv::Mat refit = cv::findHomography(src, dst, 0);
        if (refit.empty()) return cv::Mat();
        H = refit;
    }

    cv::perspectiveTransform(src, predicted, H);
    double sumSq = 0;
    for (size_t i = 0; i < src.size(); ++i) {
        const cv::Point2f d = predicted[i] - dst[i];
        sumSq += d.x * d.x + d.y * d.y;
    }
    pairs = (int)src.size();
    rms = std::sqrt(sumSq / src.size());
    if (rms > kStarMaxRmsPx) return cv::Mat();
    if (starCoverage(base, dst) < kStarMinCoverage) return cv::Mat();
    if (H.type() != CV_64F) H.convertTo(H, CV_64F);
    return H;
}

// A translation-only seed for a pair with no keypoint fit to start from: the most
// common offset between the brightest stars of the two frames, out to
// kStarSeedSearchRadius.  Rotation across the frame is left for the regional vote,
// whose kStarVoteRadius covers it at the neighbour distances star aligns over.
static constexpr int kStarSeedStars        = 1500;
static constexpr int kStarSeedSearchRadius = 100;

static cv::Mat translationSeedFromStars(const std::vector<cv::Point2f> &nb,
                                        const std::vector<cv::Point2f> &base) {
    const std::vector<cv::Point2f> nbBright(nb.begin(),
        nb.begin() + std::min<size_t>(nb.size(), kStarSeedStars));
    const std::vector<cv::Point2f> baseBright(base.begin(),
        base.begin() + std::min<size_t>(base.size(), kStarSeedStars));
    const float r = (float)kStarSeedSearchRadius;
    const StarGrid grid(baseBright, r);
    const int bins = 2 * kStarSeedSearchRadius + 1;
    std::vector<int> hist((size_t)bins * bins, 0);
    for (const auto &p : nbBright) {
        grid.within(p, r, [&](int, cv::Point2f d) {
            const int bx = std::clamp((int)std::lround(d.x) + kStarSeedSearchRadius, 0, bins - 1);
            const int by = std::clamp((int)std::lround(d.y) + kStarSeedSearchRadius, 0, bins - 1);
            hist[(size_t)by * bins + bx]++;
        });
    }
    int px, py, peak; double contrast;
    histogramPeak(hist, bins, px, py, peak, contrast);
    if (peak < 20 || contrast < 6) return cv::Mat();
    cv::Mat seed = cv::Mat::eye(3, 3, CV_64F);
    seed.at<double>(0, 2) = px - kStarSeedSearchRadius;
    seed.at<double>(1, 2) = py - kStarSeedSearchRadius;
    return seed;
}

// The sky homography from the stars: refined from the keypoint fit when there is one,
// otherwise (or if that fails) from a translation seed.  Empty when the stars cannot
// support a fit, which leaves the keypoint fit as it was.
static cv::Mat refineSkyHomographyWithStars(const cv::Mat &keypointFit,
                                            const std::vector<cv::Point2f> &nb,
                                            const std::vector<cv::Point2f> &base,
                                            int frameIndex, int neighborFrameIndex) {
    if ((int)nb.size() < kStarMinPairs || (int)base.size() < kStarMinPairs) return cv::Mat();
    const StarGrid baseGrid(base, kStarVoteRadius);
    // Both starting points, whichever explains more of the stars.  Not the keypoint fit
    // first and the vote only if it fails: in twilight the keypoint fit is often wrong in
    // a way the refinement can half-follow, and the half it finds can pass every other
    // test while the vote, from no keypoints at all, finds three times the pairs.
    int pairs = 0; double rms = 0;
    cv::Mat refined;
    const char *from = "keypoint fit";
    if (!keypointFit.empty()) refined = refineSkyFromSeed(nb, base, baseGrid, keypointFit, pairs, rms);
    const cv::Mat seed = translationSeedFromStars(nb, base);
    if (!seed.empty()) {
        int votePairs = 0; double voteRms = 0;
        cv::Mat fromVote = refineSkyFromSeed(nb, base, baseGrid, seed, votePairs, voteRms);
        if (!fromVote.empty() && (refined.empty() || votePairs > pairs)) {
            refined = fromVote; pairs = votePairs; rms = voteRms;
            from = "star translation vote";
        }
    }
    if (refined.empty()) {
        Log_d("frame %d sky homography to %d: stars (%zu, %zu) could not refine it",
              frameIndex, neighborFrameIndex, nb.size(), base.size());
    } else {
        Log_d("frame %d sky homography to %d refined from the %s: %d star pairs, %.2fpx rms",
              frameIndex, neighborFrameIndex, from, pairs, rms);
    }
    return refined;
}

// Whether the stars overrule a sky keypoint fit they could not confirm.
//
// When refineSkyHomographyWithStars finds no fit, the keypoint fit is all that is left,
// and on a sky full of stars that is damning evidence against it: a right fit would have
// been confirmed.  Measured on the twilight frames of two sequences from the same night
// (the moving, moonlit a9-1 and the static, cirrus-covered fx3-1), every keypoint fit the
// stars refused while both frames held 1000+ centroids was 170-2400px wrong, on a static
// camera whose sky moves a few pixels between frames — and kept, one such warp makes
// validation distrust the frame's whole set, so the frame lost its 6-7 good neighbours to
// a repair copied from frames away.  Reported as no homography instead, it costs one
// source in the merge.
//
// Only a thin fit is overruled.  Every one of those wrong fits stood on 1-11 RANSAC
// inliers, where fits standing on 32 or more agreed with the stars to 0.2px; a solid
// consensus the stars cannot confirm is more likely a sky the stars cannot speak for —
// cloud hiding most of it — than a wrong fit, and it keeps its say.
static constexpr int kStarsToOverrule  = 1000;
static constexpr int kThinSkyConsensus = 30;

static bool starsOverruleThinSkyFit(const std::vector<uchar> &inlierMask,
                                    size_t neighborStars, size_t baseStars,
                                    int frameIndex, int neighborFrameIndex) {
    if ((int)neighborStars < kStarsToOverrule || (int)baseStars < kStarsToOverrule) return false;
    const int inliers = (int)std::count_if(inlierMask.begin(), inlierMask.end(),
                                           [](uchar flag) { return flag != 0; });
    if (inliers >= kThinSkyConsensus) return false;
    Log_d("frame %d sky homography to %d dropped: %d keypoint inliers, and %zu and %zu stars "
          "that confirm no fit", frameIndex, neighborFrameIndex, inliers, baseStars,
          neighborStars);
    return true;
}

// The RANSAC seed for one frame pair.  cv::findHomography's RANSAC, and the ground's, draw
// random subsets via cv::theRNG(); without an explicit seed the chosen consensus set varies
// run-to-run, occasionally producing homographies whose deviation magnitude looks fine but
// whose tx/ty are off by several pixels.  Seeded per (baseFrame, neighborFrame), the same
// pair always gets the same RANSAC sequence.
static uint64_t pairSeed(int frameIndex, int neighborFrameIndex) {
    return (static_cast<uint64_t>(frameIndex) * 2654435761ULL) ^
           static_cast<uint64_t>(neighborFrameIndex);
}

int ia_compute_homography(OCVFeatureSetRef baseKeypoints,
                          int frameIndex,
                          const AlignmentNeighborData *neighbors, int neighborCount,
                          FeatureMatchMethod matchMethod,
                          AlignmentType alignmentType,
                          int maxKeypoints, bool writeDebugImages,
                          int imageWidth, int imageHeight,
                          AlignmentUpdateFunc updateHandler, void *updateContext,
                          AlignmentWarpInfoData *outWarpInfos,
                          const char **errorMsg) {
    if (!baseKeypoints || !outWarpInfos) {
        if (errorMsg) *errorMsg = "not given keypoints on base frame";
        return 0;
    }
    // The ground turns about the frame's centre, which cannot be found without the frame.
    if (alignmentType == AlignmentTypeEarth && (imageWidth <= 0 || imageHeight <= 0)) {
        if (errorMsg) *errorMsg = "ground alignment needs the frame size";
        return 0;
    }

    auto notify = [&](ObjCAlignmentStep step, int neighbor) {
        if (updateHandler) updateHandler(frameIndex, alignmentType, step, neighbor, updateContext);
    };

    try {
        notify(ObjCAlignmentStepStart, 0);

        std::vector<cv::KeyPoint>& kpBase = baseKeypoints->keypoints;
        cv::Mat& descBase = baseKeypoints->descriptors;

        auto recordSuccess = [&](int ii, const cv::Mat &H) {
            cv::Mat I = cv::Mat::eye(3, 3, H.type());
            outWarpInfos[ii].homography = wrap(H);
            outWarpInfos[ii].deviation = cv::norm(H - I, cv::NORM_L2);
            outWarpInfos[ii].alignmentState = AlignmentStateObjCHomographySuccess;
        };
        // The sky's stars, for when the keypoints alone cannot fit it at all —
        // twilight frames that SIFT finds next to nothing in.
        auto skyFromStarsAlone = [&](int ii) {
            if (alignmentType != AlignmentTypeSky) return false;
            cv::Mat H = refineSkyHomographyWithStars(
              cv::Mat(), neighbors[ii].keypoints->stars, baseKeypoints->stars,
              frameIndex, neighbors[ii].frameIndex);
            if (H.empty()) return false;
            recordSuccess(ii, H);
            return true;
        };

        // Every neighbour is matched before any is fitted: the ground's focal length is
        // calibrated over all of a frame's correspondences at once, and its rotations
        // cannot be fitted until it is.
        std::vector<std::vector<cv::Point2f>> matchedNeighbor(neighborCount),
                                              matchedBase(neighborCount);
        std::vector<bool> matched(neighborCount, false);

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

                if (descNeighbor.empty() || descBase.empty()) {
                    skyFromStarsAlone(ii);
                    continue;
                }

                notify(ObjCAlignmentStepNeighborKeypointMatch, ii);

                std::vector<cv::Point2f> &ptsNeighbor = matchedNeighbor[ii];
                std::vector<cv::Point2f> &ptsBase = matchedBase[ii];
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
                    pairmatch::knn2(descNeighbor, descBase, matchNorm, knnMatches);
                    {
                        const auto &st = pairmatch::stats();
                        const uint64_t calls = st.calls.load(std::memory_order_relaxed);
                        if (calls % 100 == 0)
                            Log_d("pair match: %llu matches asked for, %llu answered from the partner's pass, %llu computed, %d waiting",
                                  (unsigned long long)calls,
                                  (unsigned long long)st.hits.load(std::memory_order_relaxed),
                                  (unsigned long long)st.computed.load(std::memory_order_relaxed),
                                  (int)pairmatch::waiting().count());
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
                case FeatureMatchMethodFLANN: {
                    if (matchNorm == cv::NORM_HAMMING) {
                        // FLANN's default index is a KDTree over L2, which is the same
                        // mismatch the BFMatcher above had: widening packed bits to
                        // floats does not make Euclidean distance mean anything on
                        // them.  LSH would be the FLANN-side answer, but it brings
                        // tuning parameters nothing here can validate, so binary
                        // descriptors take the exact matcher instead.
                        pairmatch::knn2(descNeighbor, descBase, matchNorm, knnMatches);
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

                matched[ii] = true;
            } catch (const cv::Exception &e) {
                Log_e("frame %d Error: %s", frameIndex, e.what());
            } catch (const std::exception &e) {
                Log_e("frame %d Error: %s", frameIndex, e.what());
            }
        }

        GroundCamera camera;
        if (alignmentType == AlignmentTypeEarth) {
            std::vector<GroundPair> pairs;
            for (int ii = 0; ii < neighborCount; ++ii) {
                // a pair the consensus check would refuse anyway has nothing to add
                if (!matched[ii] || (int)matchedNeighbor[ii].size() < kMinGroundInliers) continue;
                pairs.push_back({&matchedNeighbor[ii], &matchedBase[ii],
                                 pairSeed(frameIndex, neighbors[ii].frameIndex)});
            }
            double f = kGroundFocalMaxWidths * imageWidth;
            try {
                f = calibrateGroundFocalLength(pairs, imageWidth, imageHeight, frameIndex);
            } catch (const std::exception &e) {
                Log_e("frame %d ground focal length calibration failed, fitting at %.0fpx: %s",
                      frameIndex, f, e.what());
            }
            camera = groundCamera(imageWidth, imageHeight, f);
        }

        for (int ii = 0; ii < neighborCount; ++ii) {
            if (!matched[ii]) continue;
            try {
                std::vector<cv::Point2f> &ptsNeighbor = matchedNeighbor[ii];
                std::vector<cv::Point2f> &ptsBase = matchedBase[ii];
                if (ptsNeighbor.size() >= 4) {
                    notify(ObjCAlignmentStepAligningNeighbor, ii);
                    cv::theRNG() = cv::RNG(pairSeed(frameIndex, neighbors[ii].frameIndex));
                    std::vector<uchar> inlierMask;
                    cv::Mat H = estimateAlignment(alignmentType, camera, ptsNeighbor, ptsBase,
                                                  inlierMask);
                    if (!H.empty() && H.type() != CV_64F) H.convertTo(H, CV_64F);
                    const bool fitted = !H.empty() && H.rows == 3 && H.cols == 3;

                    // The sky's keypoint fit is a starting point; its stars finish it.
                    if (alignmentType == AlignmentTypeSky) {
                        cv::Mat refined = refineSkyHomographyWithStars(
                          fitted ? H : cv::Mat(), neighbors[ii].keypoints->stars,
                          baseKeypoints->stars, frameIndex, neighbors[ii].frameIndex);
                        if (!refined.empty()) { recordSuccess(ii, refined); continue; }
                        if (fitted && starsOverruleThinSkyFit(
                              inlierMask, neighbors[ii].keypoints->stars.size(),
                              baseKeypoints->stars.size(), frameIndex,
                              neighbors[ii].frameIndex)) {
                            outWarpInfos[ii].alignmentState = AlignmentStateObjCNoHomographyFound;
                            continue;
                        }
                    }

                    if (fitted &&
                        groundConsensusIsUsable(alignmentType, inlierMask,
                                                ptsNeighbor.size(), frameIndex,
                                                neighbors[ii].frameIndex))
                    {
                        recordSuccess(ii, H);
                    } else {
                        outWarpInfos[ii].alignmentState = AlignmentStateObjCNoHomographyFound;
                    }
                } else if (!skyFromStarsAlone(ii)) {
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

static cv::Mat warpInto(const cv::Mat &src, const cv::Mat &H, bool useGPU) {
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
    // BORDER_TRANSPARENT leaves alone every destination pixel that maps outside the
    // source, so pre-zeroing the destination gets those zeroed by the same pass that
    // does the warp.  It does not leave the fringe alone — remapBilinear's transparent
    // branch renormalises a pixel whose window is only partly inside by the weights
    // that do land on real samples (imgwarp.cpp), so the boundary comes back at full
    // brightness rather than skipped.  Either way there is no dim fringe; it is worth
    // knowing which of the two it is before reimplementing this rule anywhere else,
    // because it is a property of the OpenCV in the tree and not of the flag's name.
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

    // GPU path: a Metal kernel reproducing OpenCV's fixed-point INTER_LINEAR +
    // BORDER_TRANSPARENT bilinear resample, registered (or not) from
    // StarCppBridge/GPUOps.swift at process startup — see GPUOps_C.h. `useGPU`
    // being true only means the caller's Config asked for it; the handler itself
    // checks GPUCapability and returns false immediately when there is no usable
    // device, so this is never the only path to a result.
    if (useGPU) {
        if (GPUWarpFunc gpuWarp = gpu_ops_get_warp()) {
            cv::Mat H64 = H;
            if (H64.type() != CV_64F) H.convertTo(H64, CV_64F);
            if (H64.isContinuous() && H64.rows == 3 && H64.cols == 3) {
                MatWrapperRef srcRef = wrapReadOnly(src);
                MatWrapperRef dstRef = wrapReadOnly(warped);
                const bool ok = gpuWarp(srcRef, H64.ptr<double>(), dstRef);
                mat_wrapper_release(srcRef);
                mat_wrapper_release(dstRef);
                if (ok) return warped;
                // The handler may have written some, but not all, of `warped`
                // before failing — never let a partial GPU attempt leak into
                // the CPU path below, which assumes a fresh zeroed destination.
                warped.setTo(cv::Scalar::all(0));
            }
        }
    }

#ifdef STAR_EXACT_WARP
    // The same call, byte for byte, without its per-block allocations and its scalar
    // 16-bit bilinear: see ExactWarp.hpp.
    if (exactwarp::enabled() && exactwarp::applies(src, H)) {
        exactwarp::warp(src, H, warped, nullptr);
        return warped;
    }
#endif
    cv::warpPerspective(src, warped, H, src.size(),
                        cv::INTER_LINEAR, cv::BORDER_TRANSPARENT);
    return warped;
}

// Which destination pixels warpInto reaches under `H`: 255 where the warp lands a
// sample, 0 where it does not.  `probe` is a solid frame-sized CV_8UC1 of 255s,
// passed in so a merge allocates one and every neighbour warps the same one.
//
// Exact by construction rather than by argument.  BORDER_TRANSPARENT decides
// whether to touch a destination pixel from that pixel, the homography and the
// source size, and reads no pixel values doing it, so running the identical call
// over a solid probe reproduces the image warp's untouched set byte for byte.  A
// covered pixel comes back at 255 whichever branch produced it: bilinear over
// samples that are all 255 is 255, and so is the renormalised partial-window case,
// which divides by exactly the weights it summed.
//
// The alternative is to compute the covered quadrilateral from H directly, which
// would cost nothing at all — but it means reimplementing OpenCV's boundary rule,
// and that rule is a detail of the copy of OpenCV in the tree.  Deriving it from
// the same call cannot drift from it.
//
// Literally the same call, now: this used to duplicate warpInto's body rather
// than call it, which was a second place a GPU (or any other) reimplementation
// of the warp could drift from the image path it has to stay consistent with.
// Delegating makes that impossible instead of merely documented.
//
// On the CPU the plane is derived from the coordinates instead of from a second warp of the
// probe, which gives the same plane (ExactWarp.hpp says why) for the cost of generating the
// maps only.  Not under `useGPU`: there the probe goes through the GPU warp, which draws a
// partly covered pixel its own way, and has to agree with the image that warp produced.
static cv::Mat warpCoverage(const cv::Mat &probe, const cv::Mat &H, bool useGPU) {
#ifdef STAR_EXACT_WARP
    if (!useGPU && exactwarp::enabled() && probe.type() == CV_8UC1 &&
        exactwarp::coverageApplies(probe.size(), H))
        return exactwarp::coverage(probe.size(), H);
#endif
    return warpInto(probe, H, useGPU);
}

// Attempts the batched GPU aligned merge for one frame's RESIDENT (all-in-memory)
// path only — see GPU_MERGE_BATCHING_FIX.md and GPUOps.swift's MetalGPUBackend.
// alignedMerge for why this exists and how it is implemented. Decodes every
// neighbour concurrently, exactly as the CPU resident path does (forEachMergeSource,
// bounded by loadConcurrency), filters out any that have no homography, failed to
// decode, or do not match the base's geometry, converts each surviving neighbour's
// homography to a flattened row-major 3x3 double array, and hands the base plus
// every surviving neighbour's still-unwarped pixels to the registered
// GPUAlignedMergeFunc in a single call — one Metal kernel does every warp and the
// final merge together, instead of `neighborCount * 2 + 1` separate round-trips,
// and on unified memory it reads these decoded neighbours and writes `output` in
// place, so all it costs in memory is what this function already holds.
//
// Returns nullptr on any failure or unsupported case, including "no handler
// registered" and "zero neighbours survived filtering" — the caller then runs the
// existing per-neighbour CPU path for the whole frame (which independently performs
// the same filtering and would reach the same "nothing to merge" conclusion in the
// zero-survivors case, so falling through there is correct, just not free — an
// acceptable cost for what should be a rare edge case, not the common path).
// `*outWarpCount` is only meaningful when this returns non-null.
static MatWrapperRef tryGPUAlignedMerge(const cv::Mat &base, int baseFrameIndex,
                                        const AlignmentNeighborData *neighbors, int neighborCount,
                                        const int *homographyKeys, MatWrapperRef *homographyValues,
                                        int homographyCount,
                                        double outlierThreshold, bool includeAll,
                                        int loadConcurrency, int *outWarpCount) {
    GPUAlignedMergeFunc gpuAlignedMerge = gpu_ops_get_aligned_merge();
    if (!gpuAlignedMerge) return nullptr;
    // The fused kernel (aligned_merge_u8/u16, see GPUOps.swift) binds at most 16
    // neighbours and selects from a fixed-size 17-element stack array — the same
    // cap GPUMedianMergeFunc already enforces for the un-batched, single-call GPU
    // merge used elsewhere in this file. Bailing before any decoding happens
    // (rather than discovering this only after loading every neighbour) keeps the
    // common "GPU unavailable/inapplicable" case just as cheap as it always was.
    if (neighborCount < 0 || neighborCount + 1 > 17) return nullptr;

    // One loaded neighbour, pending the same filtering warpNeighbour already does:
    // present iff it has a homography, decoded successfully, and matches the base's
    // rows/cols/type. `neighbor` is owned (released below); `homography` is not
    // (borrowed from `homographyValues`, exactly like `H` in warpNeighbour).
    struct LoadedNeighbour {
        MatWrapperRef neighbor = nullptr;
        MatWrapperRef homography = nullptr;
        std::string note;
        bool present = false;
    };
    std::vector<LoadedNeighbour> loaded((size_t)std::max(neighborCount, 0));
    forEachMergeSource(neighborCount, loadConcurrency, [&](int i) {
        LoadedNeighbour &out = loaded[(size_t)i];
        MatWrapperRef H = homographyForOffset(neighbors[i].frameIndex - baseFrameIndex,
                                              homographyKeys, homographyValues, homographyCount);
        if (!H) return;

        MatWrapperRef neighbor = image_cache_load(neighbors[i].filename);
        if (!neighbor) return;

        // Geometry is checked here, before warping, rather than after (as
        // warpNeighbour does) — this path never warps on the CPU, so there is no
        // post-warp cv::Mat to check, and warpInto never changes a source's rows/
        // cols anyway (its output is always `src.size()`), so checking the raw
        // neighbour against the base is exactly equivalent.
        if (neighbor->mat.rows != base.rows || neighbor->mat.cols != base.cols ||
            neighbor->mat.type() != base.type()) {
            out.note = std::string("aligned merge: ") + neighbors[i].filename +
                       " does not match the base geometry";
            mat_wrapper_release(neighbor);
            return;
        }

        out.neighbor = neighbor;
        out.homography = H;
        out.present = true;
    });

    std::vector<MatWrapperRef> presentNeighbours;
    std::vector<double> homographies;  // flattened row-major 3x3 per surviving neighbour
    presentNeighbours.reserve(loaded.size());
    homographies.reserve(loaded.size() * 9);
    for (auto &l : loaded) {
        if (!l.note.empty()) Log_w("%s", l.note.c_str());
        if (!l.present) continue;

        // Same CV_64F-and-3x3 precondition warpInto's own GPU branch already checks
        // before calling GPUWarpFunc — a homography that fails it here falls back to
        // the whole-frame CPU path below, rather than silently dropping just this one
        // neighbour, since that would make the GPU and CPU paths disagree on which
        // neighbours contribute.
        cv::Mat H64 = l.homography->mat;
        if (H64.type() != CV_64F) l.homography->mat.convertTo(H64, CV_64F);
        if (!H64.isContinuous() || H64.rows != 3 || H64.cols != 3) {
            for (MatWrapperRef n : presentNeighbours) mat_wrapper_release(n);
            mat_wrapper_release(l.neighbor);
            return nullptr;
        }

        presentNeighbours.push_back(l.neighbor);
        const double *h = H64.ptr<double>();
        homographies.insert(homographies.end(), h, h + 9);
    }

    MatWrapperRef result = nullptr;
    if (!presentNeighbours.empty()) {
        cv::Mat output(base.rows, base.cols, base.type());
        MatWrapperRef baseRef = wrapReadOnly(base);
        MatWrapperRef dstRef = wrapReadOnly(output);
        const bool ok = gpuAlignedMerge(baseRef, presentNeighbours.data(), (int)presentNeighbours.size(),
                                        homographies.data(), outlierThreshold, includeAll, dstRef);
        mat_wrapper_release(baseRef);
        mat_wrapper_release(dstRef);
        if (ok) {
            result = wrap(output);
            if (outWarpCount) *outWarpCount = (int)presentNeighbours.size();
        }
    }

    for (MatWrapperRef n : presentNeighbours) mat_wrapper_release(n);
    return result;
}

// --- Cloud-aware merge --------------------------------------------------------
//
// Specified in CLOUD_AWARE_MERGE_IMPLEMENTATION.md at the repository root, which is
// also where the numpy prototype these numbers were measured with lives.  The short
// version, for someone reading only this file:
//
// The star aligned merge above takes each pixel of a cloud that moves against the stars
// from a different one of its nine sources, so the cloud comes out banded and repeated.
// This stage measures how the clouds move, merges the neighbours a second time aligned
// to that motion, and uses that second merge wherever it explains the base frame better
// than the first, with the stars put back from the first.  It is a refinement of a
// finished merge, not a replacement: wherever it finds nothing to do the output is the
// star merge, byte for byte, which is what makes it safe to leave on for clear skies.
//
// Six decisions here are not obvious from the algorithm, and each was made to buy one
// property:
//
//  * Most frames have no cloud moving against the stars, and for those the stage must
//    cost next to nothing and change nothing.  It looks for moving cloud before anything
//    else, from a one-neighbour search on every other tile, and stops there when it finds
//    none.  The gate the algorithm calls for cannot do this job: at full frame scale the
//    star merge's error exceeds its noise floor over 2-16% of a clear frame's sky, so a
//    region derived from it covers most of the frame.  See kMovingSpeed.
//
//  * The sky the stage works in is the part the star merge can be trusted in, not the
//    sky mask itself: the neighbours' lifted ground contaminates the merge above the
//    horizon.  See trustedSky.
//
//  * Every blur in the full resolution part is cloudBoxBlur, an integer box filter, and
//    not cv::blur.  A float box filter keeps a running sum, so a pixel's value depends
//    on where its window started, in the last bits.  Run on a crop of the frame, it
//    would then differ from the same pixel computed on the whole frame, and "restricting
//    the stage to the region that matters changes nothing" would only be true to within
//    a rounding error that still flips whole output values.  Integer sums are exact in
//    any order, so a crop and the frame agree to the bit and the band-wise gate below
//    needs no care about where its bands start.
//
//  * The region the stage works on is derived from an upper bound.  The blend weight is
//    a product of two factors, one of which depends only on how badly the star merge
//    explains the base (eM below).  Blurring just that factor bounds the weight from
//    above everywhere, and the weight is snapped to 0 under 0.01, so any pixel whose
//    bound is under 0.01 provably stays the star merge.  Those pixels are never
//    computed, which keeps a frame with a small cloud from paying for the whole frame.
//
//  * Motion is measured on the whole frame, not on the region.  An unmeasured tile
//    (all ground, say) takes its value from the nearest measured one, and "nearest"
//    would change with the set of tiles measured.
//
//  * The ground is excluded and so are the frame edges.  The star aligned neighbours'
//    ground moves with the stars, the motion search locks onto it, and the weight would
//    turn on there for no visible effect; and where a warp does not reach, a source is
//    missing, which the merge kernel knows about but a correlation does not.
namespace {
namespace cloudaware {

// Motion is measured at 1/4 resolution: stars are about a pixel there and a 3x3 median
// removes them, while a cloud edge several pixels wide survives.
constexpr int kFactor = 4;
// Tiles are 96px at that resolution (384px full size) on a 48px step.  The search
// window around a tile must stay inside the tile's own extent, so the largest search
// radius must stay under kTile / 2.
constexpr int kTile = 96;
constexpr int kStep = 48;
constexpr int kVelocityRadius = 46;
constexpr int kNeighbourRadius = 16;
// After star alignment, stars sit at exactly zero shift and on starry frames they win
// the correlation.  Searching for the best *other* shift is safe: where there is no cloud
// the answer is arbitrary and the blend weight rejects it.
constexpr int kExcludeRadiusSq = 4;       // absolute shift, low-res px squared

// Relative test: how much of the star merge's error the cloud merge removes.
constexpr double kRelLow = 0.2;
constexpr double kRelHigh = 0.5;
// Noise floor, as a multiple of the robust per-pixel noise: 8 of the 0.05 that is left of
// a pixel's noise after the low-pass.  The guide's 6 is the smallest multiple that zeroed
// the weight on a clear frame (3 left patches up to 0.44), and it is what the numpy
// prototype used, but through this code it counted more of a frame as cloud than the
// prototype did: the share of the A3 crop with weight above 0.5 was 7-18 points larger on
// the faint-cloud frames (+0.099 on #45, +0.119 on #60, +0.184 on #72 against the
// prototype's), where today's output already matches the exposed frame well.  8 brings
// every one of twelve frames from 6 to 91 within +-0.08 of the prototype's share, and
// costs at most 0.003 of cloud correlation anywhere; 7 and 9 sit either side (frame 72
// still +0.12 at 7, frame 85 at -0.09 at 9, -0.14 at 10).  The weight's other ramp (0.2
// to 0.5 of the relative test) was tried and costs more fidelity for less share.  The
// minimum guards noiseless input (synthetic frames, 8-bit frames with clipped black),
// where the estimate can be zero.
constexpr double kFloorSigmaFactor = 8.0 * 0.05;
constexpr double kFloorMinimum = 1.0;
constexpr float kAlphaSnapLow = 0.01f;
constexpr float kAlphaSnapHigh = 0.99f;

constexpr int kLowPassMedian = 5;         // takes the stars out of the luma, full res
constexpr int kLowPassRadius = 6;
constexpr int kErrorRadius = 24;
constexpr int kAlphaRadius = 16;
// The relative test is averaged over this radius, over the pixels it can be computed at,
// before it is multiplied into the weight.  Computed per pixel, as the guide has it, it
// crosses its ramp in a different place on every frame over faint cloud: the weight came
// out as blobs a few hundred pixels across that moved from frame to frame, and the cloud
// under them switched between this stage's and the star merge's, which shows as shimmer.
// On frames 777-805 of the a9-3 moving sequence, averaging it over 48px took 40% out of
// that switching (the weight's change from the mean of the frames either side, times the
// difference between the two merges: 29 -> 18 per pixel of the cloud area) for 0.005 of
// cloud correlation; 32px got to 22, 64px to 15 for 0.008.  Blurring the weight itself
// that widely measured the same, but carried it 144px past the trusted sky, below the
// horizon.  Weights taken from the spread of the whole nine frame stack were steadier
// still (11) and cost 0.02 of correlation.
constexpr int kRelativeRadius = 48;
constexpr int kMorphSize = 7;

// Fixed-point scales for cloudBoxBlur: values are quantised to 1/scale before summing.
// Luma-sized values are bounded by 65535 and kErrorRadius' 49 taps still fit an int32
// row sum at 1/256; weights live in [0, 1] and get far finer than they need.
constexpr double kLumaScale = 256.0;
constexpr double kWeightScale = 65536.0;

// Rows per band for the gate, which would otherwise hold several frame sized float
// planes at once.  The halos are the full support of the filters in each pass, which is
// what lets bands be computed independently and agree exactly with the whole frame.
constexpr int kBandRows = 1024;
constexpr int kGateHalo = 96;             // 2 + 3*6 + 3*24 = 92, rounded up
constexpr int kWeightHalo = 48;           // 3*16

// Everything the weight at a pixel depends on lies within this many pixels of it:
// 3*16 (weight blur) + 3*48 (relative test's average) + 3*24 (error blur) + 3*6 + 2
// (low-pass) = 284.  The region the full resolution work runs on is the weight's support
// grown by this plus some slack, so that no filter ever reads the region's own border.
constexpr int kRegionMargin = 300;
static_assert(kRegionMargin >= 3 * kAlphaRadius + 3 * kRelativeRadius + 3 * kErrorRadius
                               + 3 * kLowPassRadius + 2,
              "the region must hold everything the weight depends on");

// Whether there is any cloud to follow at all, from the velocity field the motion search
// has already produced.  Not part of the guide's algorithm, and added because its gate
// cannot do this: the star merge's error (eM) sits at about 0.23 of the noise on a clear
// frame, against a floor of 0.3, so it exceeds the floor over 2-16% of a clear frame's sky
// at full frame scale, and everything after the gate would run on every frame.  The
// velocity field separates the two cleanly: after the grid median a clear frame has a
// handful of isolated tiles that moved (3 to 18 of 273 on four clear frames, from the
// stars' own correlation wings and what is left of the horizon), a frame with cloud has
// most of them (221 of 273).  Where the search found cloud moving at least
// kMovingSpeed low-res px a frame in fewer than kMinMovingTiles tiles of trusted sky,
// the stage stops and the output is the star merge.  A cloud that small is a loss of
// nothing much: it is a few tiles of banding the stage would have repaired.
constexpr float kMovingSpeed = 3.f;       // low-res px per frame: 12 at full size
// ...and a tile only counts when its best shift correlates this well in the searches the
// velocity came from.  Without it, noise alone makes a clear frame's velocities large and
// random (21 of 28 tiles on a synthetic one), where cloud correlates at 0.6 and above
// (478 of 546 searches on frame 30).
constexpr float kMovingPeak = 0.5f;
constexpr int kMinMovingTiles = 6;
constexpr double kTrustedTileShare = 0.95;
// The pre-filter's own threshold, on one neighbour's search: see the pre-filter.
constexpr int kPrefilterMovingTiles = 3;

// Test hook, see ia_debug_set_cloud_region_restriction.
std::atomic<bool> gRestrictToRegion{true};

inline int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

// --- exact box blur ---------------------------------------------------------------

// One pass of a (2r+1)x(2r+1) box filter over a CV_32F plane, in place, with BORDER_REPLICATE
// edges and arithmetic that does not depend on where the window starts: every value is rounded
// to a multiple of 1/scale first, the sums are integers, and the one division at the end is
// exactly rounded.  BoxBlur.hpp has the code, scalar and AVX2, which agree to the bit.
// `rowSums` is scratch.
static void boxBlurOnce(cv::Mat &plane, cv::Mat &rowSums, int r, double scale) {
#ifdef STAR_EXACT_WARP
    boxblur::boxBlurOnce(plane, rowSums, r, scale, exactwarp::enabled());
#else
    boxblur::boxBlurOnce(plane, rowSums, r, scale, false);
#endif
}

// Three successive box blurs of radius r, which is close to a Gaussian of sigma r.
static void cloudBoxBlur(cv::Mat &plane, int r, double scale) {
    cv::Mat scratch;
    for (int pass = 0; pass < 3; ++pass) boxBlurOnce(plane, scratch, r, scale);
}

// --- luma ---------------------------------------------------------------------------

template <typename T>
static void lumaRows(const cv::Mat &src, const cv::Rect &rc, cv::Mat &dst) {
    cv::parallel_for_(cv::Range(0, rc.height), [&](const cv::Range &rg) {
        for (int y = rg.start; y < rg.end; ++y) {
            const T *s = src.ptr<T>(rc.y + y) + 3 * rc.x;
            float *d = dst.ptr<float>(y);
            for (int x = 0; x < rc.width; ++x)
                d[x] = 0.0722f * (float)s[3 * x] + 0.7152f * (float)s[3 * x + 1]
                     + 0.2126f * (float)s[3 * x + 2];
        }
    });
}

// Rec.709 luma of a BGR frame's `rc`, in the frame's own units.
static cv::Mat lumaPlane(const cv::Mat &frame, const cv::Rect &rc) {
    cv::Mat out(rc.height, rc.width, CV_32F);
    if (frame.depth() == CV_8U) lumaRows<uchar>(frame, rc, out);
    else                        lumaRows<uint16_t>(frame, rc, out);
    return out;
}

// The same luma, averaged over each kFactor x kFactor block from the top left corner;
// the last few rows and columns of a frame whose size is not a multiple are dropped.
template <typename T>
static void lumaDownRows(const cv::Mat &src, cv::Mat &dst) {
    cv::parallel_for_(cv::Range(0, dst.rows), [&](const cv::Range &rg) {
        for (int ly = rg.start; ly < rg.end; ++ly) {
            float *d = dst.ptr<float>(ly);
            for (int lx = 0; lx < dst.cols; ++lx) {
                float sum = 0.f;
                for (int dy = 0; dy < kFactor; ++dy) {
                    const T *s = src.ptr<T>(ly * kFactor + dy) + 3 * lx * kFactor;
                    for (int dx = 0; dx < kFactor; ++dx)
                        sum += 0.0722f * (float)s[3 * dx] + 0.7152f * (float)s[3 * dx + 1]
                             + 0.2126f * (float)s[3 * dx + 2];
                }
                d[lx] = sum * (1.f / (kFactor * kFactor));
            }
        }
    });
}

static cv::Mat lumaDownsample(const cv::Mat &frame) {
    cv::Mat out(frame.rows / kFactor, frame.cols / kFactor, CV_32F);
    if (frame.depth() == CV_8U) lumaDownRows<uchar>(frame, out);
    else                        lumaDownRows<uint16_t>(frame, out);
    return out;
}

// lp(X) = box3(median5(X), 6): the luma with stars taken out, then smoothed.  The median
// is what removes them; a grey opening would add noise and bias.
static void lowPass(cv::Mat &luma) {
    cv::Mat med;
    cv::medianBlur(luma, med, kLowPassMedian);
    cloudBoxBlur(med, kLowPassRadius, kLumaScale);
    luma = med;
}

// --- gate ---------------------------------------------------------------------------

// What the weight can be at most at a pixel, from the star merge's error alone.
static inline float weightBound(float eM, float floorValue) {
    float g = (eM - floorValue) / floorValue;
    return g < 0.f ? 0.f : (g > 1.f ? 1.f : g);
}

// The part of the sky the star merge can be trusted in, where the weight may be above zero.
//
// The star warps move the neighbours' ground along with their stars, so wherever a warp
// lands ground above the base frame's own horizon the merge carries smeared terrain.
// Production knows this and takes those pixels from the earth image instead (see
// StarAlignedHorizonMask.swift, whose recipe this is: the sky mask intersected with
// itself warped by each homography, NEAREST, border white).  The merge's error there is
// the ground, not a cloud, and left in it would turn the stage on along the whole
// horizon of every frame, clear or not, for an effect the composite then throws away.
//
// The error (eM) is also a wide filter: its value at a pixel depends on the merge as
// far as kTrustRadius away.  So a pixel is trusted only when no untrusted pixel lies
// within that reach, which keeps the smeared ground out of the error as well as out of
// the weight.  Clouds that close to the horizon are left as the star merge makes them.
// Returns an empty Mat when there is no sky mask: the whole frame is sky then.
constexpr int kTrustRadius = kGateHalo;

static cv::Mat trustedSky(const cv::Mat &sky, const std::vector<cv::Mat> &homographies) {
    if (sky.empty()) return cv::Mat();
    // At the motion resolution: a full resolution erosion by 96px is a 193x193 kernel over
    // 12 million pixels, which cost more than the rest of the setup put together, and a
    // boundary good to 4px is as good as a mask for this needs.  A low-res pixel is sky
    // only where all sixteen full resolution ones are, so any error is on the safe side.
    const int h4 = sky.rows / kFactor, w4 = sky.cols / kFactor;
    cv::Mat low;
    cv::resize(sky(cv::Rect(0, 0, w4 * kFactor, h4 * kFactor)), low, cv::Size(w4, h4), 0, 0,
               cv::INTER_AREA);
    cv::threshold(low, low, 254, 255, cv::THRESH_BINARY);
    cv::Mat envelope = low.clone();
    for (const cv::Mat &Hm : homographies) {
        // D H D^-1, as the motion layers use
        cv::Mat Hl = Hm.clone();
        double *h = Hl.ptr<double>();
        h[2] /= kFactor; h[5] /= kFactor; h[6] *= kFactor; h[7] *= kFactor;
        cv::Mat warped(h4, w4, CV_8U, cv::Scalar(255));
        cv::warpPerspective(low, warped, Hl, low.size(), cv::INTER_NEAREST, cv::BORDER_TRANSPARENT);
        cv::bitwise_and(envelope, warped, envelope);
    }
    const int radius = (kTrustRadius + kFactor - 1) / kFactor + 1;
    cv::Mat eroded;
    cv::erode(envelope, eroded,
              cv::getStructuringElement(cv::MORPH_RECT, cv::Size(2 * radius + 1, 2 * radius + 1)));
    cv::Mat trusted;
    cv::resize(eroded, trusted, sky.size(), 0, 0, cv::INTER_NEAREST);
    return trusted;
}

struct Gate {
    cv::Mat eM;            // CV_32F: how badly the star merge explains the base
    float floorValue = 0;  // noise floor, image units
    double sigma = 0;      // robust per-pixel noise
    cv::Mat active;        // CV_8U, 255 where the weight may reach the snap threshold
    cv::Rect activeBox;    // bounding box of `active`
    bool any = false;
};

static double median(std::vector<float> &v) {
    const size_t mid = v.size() / 2;
    std::nth_element(v.begin(), v.begin() + (long)mid, v.end());
    return (double)v[mid];
}

// Steps A of the guide, plus the upper bound that turns it into a region.  `sky` (empty
// when everything is sky) is where the noise is measured; `trusted` (empty likewise) is
// where the star merge can be trusted and so where the weight may be above zero, see
// trustedSky.  Leaves `gate.any` false when nothing in the frame can be touched.
static void computeGate(const cv::Mat &base, const cv::Mat &merged, const cv::Mat &sky,
                        const cv::Mat &trusted, Gate &gate) {
    const int H = base.rows, W = base.cols;
    const bool haveSky = !sky.empty();
    const bool haveTrusted = !trusted.empty();
    gate.eM = cv::Mat(H, W, CV_32F);

    // Noise samples: horizontal luma differences of the base, over every row-stride'th
    // row.  Differences are what ignore stars, and the median of their absolute
    // deviation (not the deviation of a low-passed residual, which measures cloud
    // evolution) is the robust sigma.  Strided so a 42MP frame does not need 130MB of
    // samples to find a median; deterministic, and millions of samples either way.
    const int64_t rowStride = std::max<int64_t>(1, ((int64_t)H * W) / 6000000);
    std::vector<float> samples;
    samples.reserve((size_t)(((int64_t)H / rowStride + 1) * std::max(W - 1, 0)));

    float maxSkyEM = 0.f;
    for (int y0 = 0; y0 < H; y0 += kBandRows) {
        const int y1 = std::min(H, y0 + kBandRows);
        const int ey0 = std::max(0, y0 - kGateHalo), ey1 = std::min(H, y1 + kGateHalo);
        const cv::Rect rc(0, ey0, W, ey1 - ey0);

        cv::Mat lb = lumaPlane(base, rc);
        cv::Mat lm = lumaPlane(merged, rc);

        for (int y = y0; y < y1; ++y) {
            if (y % rowStride != 0) continue;
            const float *row = lb.ptr<float>(y - ey0);
            const uint8_t *s = haveSky ? sky.ptr<uint8_t>(y) : nullptr;
            for (int x = 0; x + 1 < W; ++x)
                if (!s || (s[x] && s[x + 1])) samples.push_back(row[x + 1] - row[x]);
        }

        lowPass(lb);
        lowPass(lm);
        cv::absdiff(lb, lm, lb);
        cloudBoxBlur(lb, kErrorRadius, kLumaScale);

        for (int y = y0; y < y1; ++y) {
            const float *src = lb.ptr<float>(y - ey0);
            std::memcpy(gate.eM.ptr<float>(y), src, sizeof(float) * (size_t)W);
            if (!haveTrusted) {
                for (int x = 0; x < W; ++x) maxSkyEM = std::max(maxSkyEM, src[x]);
            } else {
                const uint8_t *s = trusted.ptr<uint8_t>(y);
                for (int x = 0; x < W; ++x) if (s[x]) maxSkyEM = std::max(maxSkyEM, src[x]);
            }
        }
    }

    if (samples.size() < 100) return;          // no sky to speak of
    const double med = median(samples);
    for (float &v : samples) v = std::fabs(v - (float)med);
    const double mad = median(samples);
    gate.sigma = 1.4826 * mad / std::sqrt(2.0);
    gate.floorValue = (float)std::max(kFloorSigmaFactor * gate.sigma, kFloorMinimum);

    // The star merge explains the base everywhere in the sky: nothing to do.
    if (!(maxSkyEM > gate.floorValue)) return;

    // The weight's upper bound, banded, into `active`.
    gate.active = cv::Mat::zeros(H, W, CV_8U);
    int minX = W, minY = H, maxX = -1, maxY = -1;
    for (int y0 = 0; y0 < H; y0 += kBandRows) {
        const int y1 = std::min(H, y0 + kBandRows);
        const int ey0 = std::max(0, y0 - kWeightHalo), ey1 = std::min(H, y1 + kWeightHalo);
        cv::Mat g(ey1 - ey0, W, CV_32F);
        for (int y = ey0; y < ey1; ++y) {
            const float *e = gate.eM.ptr<float>(y);
            float *d = g.ptr<float>(y - ey0);
            const uint8_t *s = haveTrusted ? trusted.ptr<uint8_t>(y) : nullptr;
            for (int x = 0; x < W; ++x)
                d[x] = (!s || s[x]) ? weightBound(e[x], gate.floorValue) : 0.f;
        }
        cloudBoxBlur(g, kAlphaRadius, kWeightScale);
        for (int y = y0; y < y1; ++y) {
            const float *src = g.ptr<float>(y - ey0);
            uint8_t *dst = gate.active.ptr<uint8_t>(y);
            for (int x = 0; x < W; ++x) {
                if (src[x] >= kAlphaSnapLow) {
                    dst[x] = 255;
                    minX = std::min(minX, x); maxX = std::max(maxX, x);
                    minY = std::min(minY, y); maxY = std::max(maxY, y);
                }
            }
        }
    }
    if (maxX < 0) return;
    gate.activeBox = cv::Rect(minX, minY, maxX - minX + 1, maxY - minY + 1);
    gate.any = true;
}

// --- motion ---------------------------------------------------------------------------

// One neighbour at 1/4 resolution, star aligned: what the tile search correlates.
struct LowLayer {
    int offset = 0;
    bool ok = false;
    cv::Mat bp;                // band-passed luma
    cv::Mat uncoveredSum;      // integral image of "the warp did not reach this pixel"
};

static cv::Mat blurLow(const cv::Mat &src, int r) {
    cv::Mat out = src.clone();
    for (int i = 0; i < 3; ++i)
        cv::blur(out, out, cv::Size(2 * r + 1, 2 * r + 1), cv::Point(-1, -1),
                 cv::BORDER_REPLICATE);
    return out;
}

// bp(X) = box3(median3(X), 1) - box3(median3(X), 12).  Stars are about a pixel at this
// scale and the median takes them out; the large blur takes out the sky gradient.
static cv::Mat bandPass(const cv::Mat &lowLuma) {
    cv::Mat med;
    cv::medianBlur(lowLuma, med, 3);
    cv::Mat fine = blurLow(med, 1);
    cv::Mat coarse = blurLow(med, 12);
    return fine - coarse;
}

// A grid of per-tile vectors, (dy, dx) in low-res px.
struct Grid {
    int ny = 0, nx = 0;
    std::vector<float> v[2];
    std::vector<uint8_t> ok;
    std::vector<float> peak;     // the correlation at the chosen shift, where measured
    void init(int ny_, int nx_) {
        ny = ny_; nx = nx_;
        v[0].assign((size_t)ny * nx, 0.f);
        v[1].assign((size_t)ny * nx, 0.f);
        ok.assign((size_t)ny * nx, 0);
        peak.assign((size_t)ny * nx, 0.f);
    }
    size_t at(int i, int j) const { return (size_t)i * nx + j; }
};

struct TileGrid {
    int ny = 0, nx = 0, h4 = 0, w4 = 0;
    std::vector<uint8_t> sky;    // the tile holds a sky pixel
};

static TileGrid makeTileGrid(int h4, int w4, int fullH, int fullW, const cv::Mat &sky) {
    TileGrid tg;
    tg.h4 = h4; tg.w4 = w4;
    if (h4 >= kTile) tg.ny = (h4 - kTile) / kStep + 1;
    if (w4 >= kTile) tg.nx = (w4 - kTile) / kStep + 1;
    tg.sky.assign((size_t)tg.ny * tg.nx, 1);
    if (!sky.empty()) {
        for (int i = 0; i < tg.ny; ++i) for (int j = 0; j < tg.nx; ++j) {
            const cv::Rect rc(j * kStep * kFactor, i * kStep * kFactor,
                              kTile * kFactor, kTile * kFactor);
            tg.sky[(size_t)i * tg.nx + j] =
              cv::countNonZero(sky(rc & cv::Rect(0, 0, fullW, fullH))) > 0 ? 1 : 0;
        }
    }
    return tg;
}

static inline float parabola(float m, float z, float p) {
    // only around a true local maximum; the neighbours are unmasked correlation values
    // and may include the excluded zero-shift peak, which is no reason to extrapolate
    if (!(z >= m && z >= p)) return 0.f;
    const float d = m - 2.f * z + p;
    return d == 0.f ? 0.f : 0.5f * (m - p) / d;
}

// The shift d (low-res px) that maximises the normalised cross-correlation of the base
// tile at (ty0, tx0) with the neighbour displaced by it, searched within +-radius of the
// prediction (py, px), never at a shift of under 2px absolute and only where the whole
// displaced window lies in frame and in the warp's coverage.  False when no such shift
// exists.
static bool searchTile(const cv::Mat &baseBp, const LowLayer &nb, int ty0, int tx0,
                       int py, int px, int radius, float &outDy, float &outDx, float &outPeak) {
    const int H = baseBp.rows, W = baseBp.cols;
    const int r0 = std::max(0, ty0 + py - radius), r1 = std::min(H, ty0 + py + radius + kTile);
    const int c0 = std::max(0, tx0 + px - radius), c1 = std::min(W, tx0 + px + radius + kTile);
    if (r1 - r0 < kTile || c1 - c0 < kTile) return false;

    cv::Mat result;
    cv::matchTemplate(nb.bp(cv::Rect(c0, r0, c1 - c0, r1 - r0)),
                      baseBp(cv::Rect(tx0, ty0, kTile, kTile)), result, cv::TM_CCOEFF_NORMED);

    int bi = -1, bj = -1;
    float best = -std::numeric_limits<float>::infinity();
    for (int i = 0; i < result.rows; ++i) {
        const float *row = result.ptr<float>(i);
        const int oy = r0 + i, ay = oy - ty0;
        for (int j = 0; j < result.cols; ++j) {
            const int ox = c0 + j, ax = ox - tx0;
            if (ay * ay + ax * ax < kExcludeRadiusSq) continue;
            const float v = row[j];
            if (!(v > best)) continue;        // also drops NaN
            const int unc = nb.uncoveredSum.at<int>(oy + kTile, ox + kTile)
                          - nb.uncoveredSum.at<int>(oy, ox + kTile)
                          - nb.uncoveredSum.at<int>(oy + kTile, ox)
                          + nb.uncoveredSum.at<int>(oy, ox);
            if (unc != 0) continue;
            best = v; bi = i; bj = j;
        }
    }
    if (bi < 0) return false;

    float sy = 0.f, sx = 0.f;
    if (bi > 0 && bi < result.rows - 1)
        sy = parabola(result.at<float>(bi - 1, bj), result.at<float>(bi, bj), result.at<float>(bi + 1, bj));
    if (bj > 0 && bj < result.cols - 1)
        sx = parabola(result.at<float>(bi, bj - 1), result.at<float>(bi, bj), result.at<float>(bi, bj + 1));
    outDy = (float)(r0 + bi - ty0) + sy;
    outDx = (float)(c0 + bj - tx0) + sx;
    outPeak = best;
    return true;
}

// Every tile of one neighbour.  `pred` (nullable) holds the predicted absolute shift per
// tile, already rounded.  A tile with no sky in it is left unmeasured.
static Grid measureGrid(const cv::Mat &baseBp, const LowLayer &nb, const TileGrid &tg,
                        const Grid *pred, int radius, int stride = 1) {
    Grid g;
    g.init(tg.ny, tg.nx);
    cv::parallel_for_(cv::Range(0, tg.ny * tg.nx), [&](const cv::Range &rg) {
        for (int t = rg.start; t < rg.end; ++t) {
            if (!tg.sky[(size_t)t]) continue;
            const int i = t / tg.nx, j = t % tg.nx;
            if (i % stride != 0 || j % stride != 0) continue;
            const int py = pred ? (int)pred->v[0][(size_t)t] : 0;
            const int px = pred ? (int)pred->v[1][(size_t)t] : 0;
            float dy = 0.f, dx = 0.f, pk = 0.f;
            if (searchTile(baseBp, nb, i * kStep, j * kStep, py, px, radius, dy, dx, pk)) {
                g.v[0][(size_t)t] = dy; g.v[1][(size_t)t] = dx; g.ok[(size_t)t] = 1;
                g.peak[(size_t)t] = pk;
            }
        }
    });
    return g;
}

// Each unmeasured tile takes the value of the nearest measured one (Chebyshev distance on
// the grid, ties in row-major order), or the fallback's if none was measured at all.
static void fillUnmeasured(Grid &g, const Grid *fallback) {
    const Grid measured = g;
    bool any = false;
    for (uint8_t o : measured.ok) if (o) { any = true; break; }
    for (int i = 0; i < g.ny; ++i) for (int j = 0; j < g.nx; ++j) {
        const size_t t = g.at(i, j);
        if (measured.ok[t]) continue;
        long found = -1;
        if (any) {
            const int maxR = std::max(g.ny, g.nx);
            for (int r = 1; r <= maxR && found < 0; ++r) {
                for (int ri = i - r; ri <= i + r && found < 0; ++ri) {
                    if (ri < 0 || ri >= g.ny) continue;
                    if (ri == i - r || ri == i + r) {
                        for (int cj = j - r; cj <= j + r; ++cj) {
                            if (cj < 0 || cj >= g.nx) continue;
                            if (measured.ok[measured.at(ri, cj)]) { found = (long)measured.at(ri, cj); break; }
                        }
                    } else {
                        for (int cj : {j - r, j + r}) {
                            if (cj < 0 || cj >= g.nx) continue;
                            if (measured.ok[measured.at(ri, cj)]) { found = (long)measured.at(ri, cj); break; }
                        }
                    }
                }
            }
        }
        for (int c = 0; c < 2; ++c)
            g.v[c][t] = found >= 0 ? measured.v[c][(size_t)found]
                                   : (fallback ? fallback->v[c][t] : 0.f);
    }
}

// Componentwise 3x3 median over the grid, edges replicated: drops a tile that locked
// onto the wrong thing.
static void medianGrid(Grid &g) {
    const Grid src = g;
    for (int c = 0; c < 2; ++c)
        for (int i = 0; i < g.ny; ++i) for (int j = 0; j < g.nx; ++j) {
            float w[9]; int n = 0;
            for (int di = -1; di <= 1; ++di) for (int dj = -1; dj <= 1; ++dj)
                w[n++] = src.v[c][src.at(clampi(i + di, 0, g.ny - 1), clampi(j + dj, 0, g.nx - 1))];
            std::nth_element(w, w + 4, w + 9);
            g.v[c][g.at(i, j)] = w[4];
        }
}

struct Neighbour {
    int offset = 0;
    const char *filename = nullptr;
    cv::Mat H, Hinv;                     // CV_64F 3x3: neighbour -> base, and back
};

// A tile grid centre in full resolution, along one axis.
static inline double tileCentre(int i) { return (double)(kStep * kFactor) * i + (double)(kStep * kFactor); }

// How a full resolution coordinate sits between tile centres: cell, then weight of the
// next cell.  Held constant beyond the outermost centres.
struct FieldAxis { std::vector<int> idx; std::vector<float> t; };

static FieldAxis makeAxis(int start, int count, int tiles) {
    FieldAxis a;
    a.idx.resize((size_t)count); a.t.resize((size_t)count);
    for (int k = 0; k < count; ++k) {
        if (tiles <= 1) { a.idx[(size_t)k] = 0; a.t[(size_t)k] = 0.f; continue; }
        const double f = ((double)(start + k) + 0.5 - tileCentre(0)) / (double)(kStep * kFactor);
        const int i = clampi((int)std::floor(f), 0, tiles - 2);
        a.idx[(size_t)k] = i;
        a.t[(size_t)k] = (float)std::min(std::max(f - (double)i, 0.0), 1.0);
    }
    return a;
}

} // namespace cloudaware
} // namespace

// Wall and CPU time per phase of one run of the stage, for the debug directory.  CPU time
// is the process's, so it is only a clean figure when nothing else is running.
struct PhaseClock {
    std::chrono::steady_clock::time_point wall0 = std::chrono::steady_clock::now();
    std::clock_t cpu0 = std::clock();
    std::chrono::steady_clock::time_point wallLast = wall0;
    std::clock_t cpuLast = cpu0;
    std::string report;
    void mark(const char *phase) {
        const auto w = std::chrono::steady_clock::now();
        const std::clock_t c = std::clock();
        char line[160];
        std::snprintf(line, sizeof line, "phase %-10s wall %6.3f cpu %7.3f\n", phase,
                      std::chrono::duration<double>(w - wallLast).count(),
                      (double)(c - cpuLast) / CLOCKS_PER_SEC);
        report += line;
        wallLast = w; cpuLast = c;
    }
    double wall() const {
        return std::chrono::duration<double>(std::chrono::steady_clock::now() - wall0).count();
    }
    double cpu() const { return (double)(std::clock() - cpu0) / CLOCKS_PER_SEC; }
};

// Debug output the guide asks for: the blend weight, and the velocity grid.
static void cloudWriteDebug(const char *dir, int frameIndex, const cv::Mat &alphaFull8,
                            const cloudaware::Grid &velocity) {
    if (!dir || !*dir) return;
    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
    char name[512];
    std::snprintf(name, sizeof name, "%s/cloud-alpha-%d.tif", dir, frameIndex);
    cv::imwrite(name, alphaFull8);
    std::snprintf(name, sizeof name, "%s/cloud-velocity-%d.txt", dir, frameIndex);
    if (std::FILE *f = std::fopen(name, "w")) {
        const char *labels[2] = {"dx", "dy"};
        const int comp[2] = {1, 0};
        for (int b = 0; b < 2; ++b) {
            std::fprintf(f, "%s (full-res px/frame); first tile centre y=%.0f x=%.0f, step %d\n",
                         labels[b], cloudaware::tileCentre(0), cloudaware::tileCentre(0),
                         cloudaware::kStep * cloudaware::kFactor);
            for (int i = 0; i < velocity.ny; ++i) {
                for (int j = 0; j < velocity.nx; ++j)
                    std::fprintf(f, " %4.0f", velocity.v[comp[b]][velocity.at(i, j)] * cloudaware::kFactor);
                std::fprintf(f, "\n");
            }
        }
        std::fclose(f);
    }
}

// What the stage decided, for the debug directory: the same numbers the log carries, in
// a file that is still there after the run.
static void cloudWriteStats(const char *dir, int frameIndex, const char *outcome,
                            double sigma, double floorValue, const cv::Rect &region,
                            int frameW, int frameH, double weightShare,
                            const PhaseClock &clock, const std::string &evidence) {
    if (!dir || !*dir) return;
    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
    char name[512];
    std::snprintf(name, sizeof name, "%s/cloud-stats-%d.txt", dir, frameIndex);
    if (std::FILE *f = std::fopen(name, "w")) {
        std::fprintf(f, "outcome %s\nsigma %.2f\nfloor %.2f\nregion %d %d %d %d of %d x %d\n"
                        "weight_above_zero_share_of_region %.4f\n%s%stotal wall %.3f cpu %.3f\n",
                     outcome, sigma, floorValue, region.x, region.y, region.width, region.height,
                     frameW, frameH, weightShare, evidence.c_str(), clock.report.c_str(),
                     clock.wall(), clock.cpu());
        std::fclose(f);
    }
}

// Refines `merged` (the star aligned merge of `base` and its neighbours) in place.
// Returns true when it changed any pixel.  Never throws: this stage is an optional
// improvement, and a frame that cannot have it keeps the star merge.
//
// `starMisses` is the star merge's coverage plane (CV_8UC1, how many sources had no
// sample at each pixel), or empty when the caller has none, in which case it is derived.
static bool cloudAwareRefine(cv::Mat &merged, const cv::Mat &base, int baseFrameIndex,
                             const AlignmentNeighborData *neighbors, int neighborCount,
                             const int *homographyKeys, MatWrapperRef *homographyValues,
                             int homographyCount, double outlierThreshold,
                             const cv::Mat &skyIn, bool stream, const char *scratchDir,
                             int loadConcurrency, cv::Mat starMisses,
                             const char *debugDir) {
    using namespace cloudaware;
    try {
        PhaseClock clock;
        auto seconds = [&] { return clock.wall(); };

        const int H = base.rows, W = base.cols;
        if (merged.empty() || merged.rows != H || merged.cols != W || merged.type() != base.type()
            || base.channels() != 3 || (base.depth() != CV_8U && base.depth() != CV_16U)) {
            Log_d("cloud-aware merge: frame %d not eligible (type %d)", baseFrameIndex, base.type());
            return false;
        }
        const int h4 = H / kFactor, w4 = W / kFactor;
        if (h4 < kTile + kStep || w4 < kTile + kStep) {
            Log_d("cloud-aware merge: frame %d too small for a tile grid", baseFrameIndex);
            return false;
        }

        // The sky mask, as 0/255 CV_8UC1 in the base's geometry.
        cv::Mat sky;
        if (!skyIn.empty()) {
            cv::Mat m = skyIn;
            if (m.channels() > 1) {
                std::vector<cv::Mat> chans; cv::split(m, chans);
                cv::Mat any = chans[0] != 0;
                for (size_t c = 1; c < chans.size(); ++c) any |= (chans[c] != 0);
                m = any;
            }
            if (m.rows != H || m.cols != W) cv::resize(m, m, cv::Size(W, H), 0, 0, cv::INTER_NEAREST);
            sky = m != 0;
        }

        // --- neighbours ---
        std::vector<Neighbour> nbs;
        for (int i = 0; i < neighborCount; ++i) {
            MatWrapperRef hRef = homographyForOffset(neighbors[i].frameIndex - baseFrameIndex,
                                                     homographyKeys, homographyValues,
                                                     homographyCount);
            if (!hRef) continue;
            Neighbour n;
            n.offset = neighbors[i].frameIndex - baseFrameIndex;
            n.filename = neighbors[i].filename;
            hRef->mat.convertTo(n.H, CV_64F);
            if (n.H.rows != 3 || n.H.cols != 3 || !n.H.isContinuous()) continue;
            if (std::fabs(cv::determinant(n.H)) < 1e-12) continue;
            n.Hinv = n.H.inv();
            nbs.push_back(std::move(n));
        }
        if (nbs.empty()) return false;

        // The part of the sky the star merge can be trusted in, see trustedSky.
        std::vector<cv::Mat> warps;
        for (const auto &n : nbs) warps.push_back(n.H);
        const cv::Mat trusted = trustedSky(sky, warps);
        clock.mark("setup");

        // --- low-res star aligned layers ---
        const cv::Mat baseLow = lumaDownsample(base);
        const cv::Mat baseBp = bandPass(baseLow);
        const cv::Mat probeLow(h4, w4, CV_8U, cv::Scalar(255));
        std::vector<LowLayer> low(nbs.size());
        std::vector<std::string> notes(nbs.size());
        auto makeLayer = [&](int i) {
            MatWrapperRef ref = image_cache_load(nbs[(size_t)i].filename);
            if (!ref) return;
            const cv::Mat &src = ref->mat;
            if (src.rows != H || src.cols != W || src.type() != base.type()) {
                notes[(size_t)i] = std::string("cloud-aware merge: ") + nbs[(size_t)i].filename +
                                   " does not match the base geometry";
                mat_wrapper_release(ref);
                return;
            }
            cv::Mat lowLuma = lumaDownsample(src);
            mat_wrapper_release(ref);

            // D H D^-1 with D = diag(1/4, 1/4, 1)
            const cv::Mat &Hf = nbs[(size_t)i].H;
            cv::Mat Hl = Hf.clone();
            double *h = Hl.ptr<double>();
            h[2] /= kFactor; h[5] /= kFactor; h[6] *= kFactor; h[7] *= kFactor;

            cv::Mat warped = cv::Mat::zeros(h4, w4, CV_32F);
            cv::warpPerspective(lowLuma, warped, Hl, cv::Size(w4, h4), cv::INTER_LINEAR,
                                cv::BORDER_TRANSPARENT);
            cv::Mat covered = cv::Mat::zeros(h4, w4, CV_8U);
            cv::warpPerspective(probeLow, covered, Hl, cv::Size(w4, h4), cv::INTER_LINEAR,
                                cv::BORDER_TRANSPARENT);
            cv::Mat uncovered;
            cv::threshold(covered == 0, uncovered, 0, 1, cv::THRESH_BINARY);
            LowLayer &layer = low[(size_t)i];
            cv::integral(uncovered, layer.uncoveredSum, CV_32S);
            layer.bp = bandPass(warped);
            layer.offset = nbs[(size_t)i].offset;
            layer.ok = true;
        };

        // The pre-filter below needs one neighbour and nothing else, so that one is built
        // first and the other seven only if the frame gets past it: on a clear frame, which
        // is nearly all of them, that is the difference between decoding and downsampling
        // two frames and nine.  It is the neighbour the velocity search would use first.
        int probeIndex = -1;
        for (int offset : {2, -2, 1, -1}) {
            for (size_t i = 0; i < nbs.size(); ++i) if (nbs[i].offset == offset) { probeIndex = (int)i; break; }
            if (probeIndex >= 0) break;
        }
        if (probeIndex >= 0) makeLayer(probeIndex);

        // --- motion ---
        const TileGrid tg = makeTileGrid(h4, w4, H, W, sky);
        auto layerAt = [&](int offset) -> const LowLayer * {
            for (const auto &l : low) if (l.offset == offset) return &l;
            return nullptr;
        };
        // A tile is evidence of cloud when it lies in trusted sky; see kMovingSpeed.
        auto trustedTile = [&](int i, int j) {
            if (trusted.empty()) return true;
            const cv::Rect rc(j * kStep * kFactor, i * kStep * kFactor, kTile * kFactor, kTile * kFactor);
            const int inside = cv::countNonZero(trusted(rc & cv::Rect(0, 0, W, H)));
            return (double)inside >= kTrustedTileShare * (double)rc.area();
        };

        // Pre-filter: the full test below, on the one neighbour already built.  A clear
        // frame then never builds the other seven, and the search it makes here is one the
        // full test reuses rather than repeats.  It stops a frame only where even this one
        // neighbour shows fewer than kPrefilterMovingTiles moving tiles; the full test
        // makes the real decision for everything else.
        //
        // It used to be cheaper, every other tile with a median over that sparse grid, and
        // that median spans five tiles (1920px) in each direction: a band of cloud one or two
        // tiles tall along the horizon lost it to the clear sky above, so the pre-filter
        // stopped frames the full test found 20-40 moving tiles in.  On a 1407 frame moving
        // sequence it stopped 224 of the 864 frames the full test passes, in no particular
        // pattern from one frame to the next, and the clouds in the output flashed between
        // this stage's and the star merge's.  Replayed on that sequence's own tile searches,
        // this version stops none of those whose full count is above 8 (four at 6-8), and
        // still stops 427 of the 487 the full test fails.  A frame it stops costs 1.6-2.0
        // CPU-s at 24MP instead of 0.7-0.9 (the merge before it is ~27).
        // (Skipped when that neighbour could not be built: the full search then decides.)
        Grid probeGrid;                       // the probe neighbour's search, measured once
        int probeOffset = 0;
        const LowLayer *one = layerAt(2) ? layerAt(2) : layerAt(-2) ? layerAt(-2)
                            : layerAt(1) ? layerAt(1) : layerAt(-1);
        if (one) {
            const float displacement = std::abs(one->offset) * kMovingSpeed;   // low-res px
            probeGrid = measureGrid(baseBp, *one, tg, nullptr, kVelocityRadius);
            probeOffset = one->offset;
            Grid g = probeGrid;
            fillUnmeasured(g, nullptr);
            medianGrid(g);
            int moving = 0;
            for (int i = 0; i < tg.ny; ++i) for (int j = 0; j < tg.nx; ++j) {
                const size_t t = g.at(i, j);
                if (probeGrid.peak[t] >= kMovingPeak && std::hypot(g.v[0][t], g.v[1][t]) >= displacement
                    && trustedTile(i, j)) ++moving;
            }
            clock.mark("prefilter");
            if (moving < kPrefilterMovingTiles) {
                Log_d("cloud-aware merge: frame %d pre-filter found no cloud motion %.2fs", baseFrameIndex, seconds());
                char text[96];
                std::snprintf(text, sizeof text, "prefilter_moving_tiles %d (need %d)\n", moving,
                              kPrefilterMovingTiles);
                cloudWriteStats(debugDir, baseFrameIndex, "no cloud motion (pre-filter)", 0, 0,
                                cv::Rect(), W, H, 0, clock, text);
                return false;
            }
        }
        // The remaining neighbours.
        {
            std::vector<int> remaining;
            for (int i = 0; i < (int)nbs.size(); ++i) if (!low[(size_t)i].ok && i != probeIndex) remaining.push_back(i);
            forEachMergeSource((int)remaining.size(), loadConcurrency,
                               [&](int k) { makeLayer(remaining[(size_t)k]); });
        }
        for (const auto &n : notes) if (!n.empty()) Log_w("%s", n.c_str());

        // Drop the neighbours that did not load, from both lists together.
        {
            std::vector<Neighbour> keepN; std::vector<LowLayer> keepL;
            for (size_t i = 0; i < nbs.size(); ++i)
                if (low[i].ok) { keepN.push_back(std::move(nbs[i])); keepL.push_back(std::move(low[i])); }
            nbs = std::move(keepN); low = std::move(keepL);
        }
        if (nbs.empty()) return false;
        clock.mark("lowres");

        const cv::Mat probeFull(H, W, CV_8U, cv::Scalar(255));

        // How strongly the velocity searches found anything: the correlation of the best
        // shift in each measured tile, counted at a few levels.
        float peakMax = 0.f; int peakTiles = 0, peak30 = 0, peak40 = 0, peak50 = 0, peak60 = 0;
        auto measureFilled = [&](const LowLayer &l) {
            Grid g = (probeGrid.ny > 0 && l.offset == probeOffset)
                   ? probeGrid : measureGrid(baseBp, l, tg, nullptr, kVelocityRadius);
            for (size_t t = 0; t < g.ok.size(); ++t) {
                if (!g.ok[t]) continue;
                const float pk = g.peak[t];
                ++peakTiles; peakMax = std::max(peakMax, pk);
                peak30 += pk >= 0.3f; peak40 += pk >= 0.4f; peak50 += pk >= 0.5f; peak60 += pk >= 0.6f;
            }
            fillUnmeasured(g, nullptr);
            return g;
        };

        Grid velocity;
        velocity.init(tg.ny, tg.nx);
        auto combine = [&](const Grid *plus, const Grid *minus, float divisor) {
            for (int c = 0; c < 2; ++c)
                for (size_t t = 0; t < velocity.v[c].size(); ++t)
                    velocity.v[c][t] = ((plus ? plus->v[c][t] : 0.f) - (minus ? minus->v[c][t] : 0.f)) / divisor;
            // how well the searches behind each tile's velocity correlated: the weaker of the two
            for (size_t t = 0; t < velocity.peak.size(); ++t) {
                const float a = plus ? plus->peak[t] : 1.f, b = minus ? minus->peak[t] : 1.f;
                velocity.peak[t] = std::min(a, b);
            }
        };
        const LowLayer *p2 = layerAt(2), *m2 = layerAt(-2), *p1 = layerAt(1), *m1 = layerAt(-1);
        if (p2 && m2)      { Grid a = measureFilled(*p2), b = measureFilled(*m2); combine(&a, &b, 4.f); }
        else if (p2)       { Grid a = measureFilled(*p2); combine(&a, nullptr, 2.f); }
        else if (m2)       { Grid b = measureFilled(*m2); combine(nullptr, &b, 2.f); }
        else if (p1 && m1) { Grid a = measureFilled(*p1), b = measureFilled(*m1); combine(&a, &b, 2.f); }
        else if (p1)       { Grid a = measureFilled(*p1); combine(&a, nullptr, 1.f); }
        else if (m1)       { Grid b = measureFilled(*m1); combine(nullptr, &b, 1.f); }
        else {
            Log_d("cloud-aware merge: frame %d has no neighbour at +-1 or +-2", baseFrameIndex);
            return false;
        }
        medianGrid(velocity);
        clock.mark("velocity");
        char evidenceText[256];
        std::snprintf(evidenceText, sizeof evidenceText,
                      "velocity_peaks tiles %d max %.3f ge0.3 %d ge0.4 %d ge0.5 %d ge0.6 %d\n",
                      peakTiles, (double)peakMax, peak30, peak40, peak50, peak60);
        // How much of the trusted sky has cloud moving in it.
        int movingTiles = 0, evidenceTilesCount = 0;
        for (int i = 0; i < tg.ny; ++i) for (int j = 0; j < tg.nx; ++j) {
            if (!trustedTile(i, j)) continue;
            ++evidenceTilesCount;
            const size_t t = velocity.at(i, j);
            if (std::hypot(velocity.v[0][t], velocity.v[1][t]) >= kMovingSpeed &&
                velocity.peak[t] >= kMovingPeak) ++movingTiles;
        }
        char movingText[128];
        std::snprintf(movingText, sizeof movingText, "moving_tiles %d of %d trusted tiles (need %d)\n",
                      movingTiles, evidenceTilesCount, kMinMovingTiles);
        const std::string evidence = std::string(evidenceText) + movingText;
        if (movingTiles < kMinMovingTiles) {
            Log_d("cloud-aware merge: frame %d no cloud motion (%d moving tiles of %d) %.2fs",
                  baseFrameIndex, movingTiles, evidenceTilesCount, seconds());
            cloudWriteStats(debugDir, baseFrameIndex, "no cloud motion", 0, 0, cv::Rect(), W, H,
                            0, clock, evidence);
            return false;
        }

        // --- gate ---
        Gate gate;
        computeGate(base, merged, sky, trusted, gate);
        clock.mark("gate");
        if (!gate.any) {
            Log_d("cloud-aware merge: frame %d nothing to do (sigma %.1f, floor %.1f) %.2fs",
                  baseFrameIndex, gate.sigma, (double)gate.floorValue, seconds());
            cloudWriteStats(debugDir, baseFrameIndex, "nothing to do", gate.sigma,
                            (double)gate.floorValue, cv::Rect(), W, H, 0, clock, evidence);
            return false;
        }
        cv::Rect region = gate.activeBox;
        region.x -= kRegionMargin; region.y -= kRegionMargin;
        region.width += 2 * kRegionMargin; region.height += 2 * kRegionMargin;
        region &= cv::Rect(0, 0, W, H);
        if (!gRestrictToRegion.load()) region = cv::Rect(0, 0, W, H);

        std::vector<Grid> fields(low.size());
        for (size_t k = 0; k < low.size(); ++k) {
            Grid pred;
            pred.init(tg.ny, tg.nx);
            for (int c = 0; c < 2; ++c)
                for (size_t t = 0; t < pred.v[c].size(); ++t)
                    pred.v[c][t] = (float)std::nearbyint((double)low[k].offset * velocity.v[c][t]);
            Grid g = measureGrid(baseBp, low[k], tg, &pred, kNeighbourRadius);
            fillUnmeasured(g, &pred);
            medianGrid(g);
            fields[k] = std::move(g);
        }
        clock.mark("fields");

        // --- the cloud aligned stack, over the region ---
        const cv::Mat baseR = base(region);
        const FieldAxis axisY = makeAxis(region.y, region.height, tg.ny);
        const FieldAxis axisX = makeAxis(region.x, region.width, tg.nx);

        cv::Mat missesC = cv::Mat::zeros(region.size(), CV_8U);
        std::mutex missesMutex;

        // Build one neighbour's cloud aligned layer: the star warped neighbour sampled at
        // the cloud displacement, in one interpolation from the original.
        auto buildLayer = [&](size_t k, const cv::Mat &src) {
            const Grid &fld = fields[k];
            const double *hi = nbs[k].Hinv.ptr<double>();
            cv::Mat layer = cv::Mat::zeros(region.size(), base.type());
            cv::Mat covered = cv::Mat::zeros(region.size(), CV_8U);
#ifdef STAR_EXACT_FIELD
            // The maps below, rounded and interpolated the way cv::remap does it, a chunk of a
            // row at a time with no planes in between, and the pixels it writes marked as it
            // goes instead of by a second remap of a solid probe.  The same bytes in `layer`
            // and in `covered`, which is what ExactWarp.hpp is held to (KernelHarness/remap_bench,
            // and CloudAwareMergeTests.testTheExactRemapMakesTheSameMerge).
            if (exactwarp::remapEnabled() && src.type() == base.type() && src.size() == probeFull.size()
                && exactwarp::remapApplies(src, region.size())) {
                exactwarp::DisplacementField field;
                field.nx = fld.nx; field.ny = fld.ny;
                field.v[0] = fld.v[0].data(); field.v[1] = fld.v[1].data();
                field.colIdx = axisX.idx.data(); field.colT = axisX.t.data();
                field.rowIdx = axisY.idx.data(); field.rowT = axisY.t.data();
                field.originX = region.x; field.originY = region.y;
                field.scale = (float)kFactor;
                std::copy(hi, hi + 9, field.hi);
                exactwarp::remapField(src, field, region.size(), layer, &covered);
            } else
#endif
            {
                cv::Mat mapx(region.size(), CV_32F), mapy(region.size(), CV_32F);
                cv::parallel_for_(cv::Range(0, region.height), [&](const cv::Range &rg) {
                    for (int y = rg.start; y < rg.end; ++y) {
                        const int iy = axisY.idx[(size_t)y], iy2 = std::min(iy + 1, fld.ny - 1);
                        const float ty = axisY.t[(size_t)y];
                        float *mx = mapx.ptr<float>(y), *my = mapy.ptr<float>(y);
                        for (int x = 0; x < region.width; ++x) {
                            const int jx = axisX.idx[(size_t)x], jx2 = std::min(jx + 1, fld.nx - 1);
                            const float tx = axisX.t[(size_t)x];
                            float d[2];
                            for (int c = 0; c < 2; ++c) {
                                const float a = fld.v[c][fld.at(iy, jx)] * (1.f - ty) + fld.v[c][fld.at(iy2, jx)] * ty;
                                const float b = fld.v[c][fld.at(iy, jx2)] * (1.f - ty) + fld.v[c][fld.at(iy2, jx2)] * ty;
                                d[c] = (a * (1.f - tx) + b * tx) * (float)kFactor;
                            }
                            const double qx = (double)(region.x + x) + (double)d[1];
                            const double qy = (double)(region.y + y) + (double)d[0];
                            const double wd = hi[6] * qx + hi[7] * qy + hi[8];
                            if (std::fabs(wd) < 1e-12) { mx[x] = -1e6f; my[x] = -1e6f; continue; }
                            mx[x] = (float)((hi[0] * qx + hi[1] * qy + hi[2]) / wd);
                            my[x] = (float)((hi[3] * qx + hi[4] * qy + hi[5]) / wd);
                        }
                    }
                });
                cv::remap(src, layer, mapx, mapy, cv::INTER_LINEAR, cv::BORDER_TRANSPARENT);
                cv::remap(probeFull, covered, mapx, mapy, cv::INTER_LINEAR, cv::BORDER_TRANSPARENT);
            }
            cv::bitwise_not(covered, covered);          // 255 where nothing landed
            {
                std::lock_guard<std::mutex> lock(missesMutex);
                cv::add(missesC, cv::Scalar(1), missesC, covered);
            }
            return layer;
        };

        cv::Mat Rc;
        {
            std::vector<cv::Mat> layers((size_t)nbs.size());
            std::vector<uint8_t> built(nbs.size(), 0);
            std::unique_ptr<MergeSpiller> spiller;
            if (stream) {
                spiller = std::make_unique<MergeSpiller>(scratchDir);
                spiller->expect(baseR);
            }
            auto produce = [&](int i) {
                MatWrapperRef ref = image_cache_load(nbs[(size_t)i].filename);
                if (!ref) return;
                cv::Mat layer = buildLayer((size_t)i, ref->mat);
                mat_wrapper_release(ref);
                if (stream) { if (spiller->add(layer)) built[(size_t)i] = 1; }
                else        { layers[(size_t)i] = layer; built[(size_t)i] = 1; }
            };
            if (stream) for (int i = 0; i < (int)nbs.size(); ++i) produce(i);
            else forEachMergeSource((int)nbs.size(), loadConcurrency, produce);

            int nBuilt = 0;
            for (uint8_t b : built) nBuilt += b;
            if (nBuilt == 0) return false;
            if (nBuilt != (int)nbs.size())
                Log_w("cloud-aware merge: frame %d built %d of %zu cloud aligned layers",
                      baseFrameIndex, nBuilt, nbs.size());

            MatWrapperRef merged2;
            if (stream) {
                merged2 = spiller->merge({baseR}, outlierThreshold, false, missesC);
            } else {
                std::vector<cv::Mat> mats;
                mats.push_back(baseR);
                for (size_t i = 0; i < layers.size(); ++i) if (built[i]) mats.push_back(layers[i]);
                merged2 = medianImageFromMats(mats, outlierThreshold, false, missesC, false);
            }
            if (!merged2 || merged2->mat.empty()) {
                if (merged2) mat_wrapper_release(merged2);
                Log_w("cloud-aware merge: frame %d cloud aligned merge failed", baseFrameIndex);
                return false;
            }
            Rc = merged2->mat;
            mat_wrapper_release(merged2);
        }
        clock.mark("stack");

        // The star merge's coverage plane, when the caller has none: the batched GPU
        // merge returns before building one.  Derived the same way, and over the same
        // neighbours, since a neighbour that failed to load is absent from both stacks.
        // Here, and not up with the setup, because it is eight full frame warps and only
        // a frame that gets this far needs it.
        if (starMisses.empty()) {
            starMisses = cv::Mat::zeros(H, W, CV_8U);
            for (const auto &n : nbs) {
                cv::Mat covered = warpCoverage(probeFull, n.H, false);
                cv::bitwise_not(covered, covered);
                cv::add(starMisses, cv::Scalar(1), starMisses, covered);
            }
        }

        // --- the weight, over the region ---
        cv::Mat lpB = lumaPlane(base, region);
        lowPass(lpB);
        cv::Mat lpC = lumaPlane(Rc, cv::Rect(0, 0, region.width, region.height));
        lowPass(lpC);
        cv::absdiff(lpB, lpC, lpB);
        lpC.release();
        cloudBoxBlur(lpB, kErrorRadius, kLumaScale);       // eC, in lpB

        // The relative test where it can be computed (trusted sky, every source present),
        // averaged over kRelativeRadius among those pixels: `rel` carries the sum and
        // `relWeight` the count, both blurred, so pixels it cannot be computed at add
        // nothing and take nothing.
        cv::Mat rel(region.size(), CV_32F), relWeight(region.size(), CV_32F);
        auto usableAt = [&](int y, int x) {
            const uint8_t *s = trusted.empty() ? nullptr : trusted.ptr<uint8_t>(region.y + y) + region.x;
            return (!s || s[x]) && !starMisses.ptr<uint8_t>(region.y + y)[region.x + x]
                && !missesC.ptr<uint8_t>(y)[x];
        };
        cv::parallel_for_(cv::Range(0, region.height), [&](const cv::Range &rg) {
            for (int y = rg.start; y < rg.end; ++y) {
                const float *eC = lpB.ptr<float>(y);
                const float *eM = gate.eM.ptr<float>(region.y + y) + region.x;
                float *r = rel.ptr<float>(y), *n = relWeight.ptr<float>(y);
                for (int x = 0; x < region.width; ++x) {
                    if (!usableAt(y, x)) { r[x] = 0.f; n[x] = 0.f; continue; }
                    const float improvement = 1.f - eC[x] / std::max(eM[x], 1e-6f);
                    const float v = (improvement - (float)kRelLow) / (float)(kRelHigh - kRelLow);
                    r[x] = v < 0.f ? 0.f : (v > 1.f ? 1.f : v);
                    n[x] = 1.f;
                }
            }
        });
        lpB.release();
        cloudBoxBlur(rel, kRelativeRadius, kWeightScale);
        cloudBoxBlur(relWeight, kRelativeRadius, kWeightScale);

        cv::Mat alpha(region.size(), CV_32F);
        {
            const float floorValue = gate.floorValue;
            cv::parallel_for_(cv::Range(0, region.height), [&](const cv::Range &rg) {
                for (int y = rg.start; y < rg.end; ++y) {
                    const float *eM = gate.eM.ptr<float>(region.y + y) + region.x;
                    const float *r = rel.ptr<float>(y), *n = relWeight.ptr<float>(y);
                    float *a = alpha.ptr<float>(y);
                    for (int x = 0; x < region.width; ++x) {
                        const float bound = usableAt(y, x) ? weightBound(eM[x], floorValue) : 0.f;
                        // relWeight is the share of usable pixels around this one; under
                        // 1e-3 there is too little around it to average
                        a[x] = (bound > 0.f && n[x] > 1e-3f) ? std::min(1.f, r[x] / n[x]) * bound : 0.f;
                    }
                }
            });
        }
        rel.release();
        relWeight.release();
        cloudBoxBlur(alpha, kAlphaRadius, kWeightScale);
        clock.mark("weight");

        // Snap, and keep to the pixels the bound allows: outside `active` the weight is
        // under 0.01 in the full frame computation, and here it could be wrong near the
        // region's own border.
        size_t changedPixels = 0;
        {
            std::atomic<size_t> count{0};
            cv::parallel_for_(cv::Range(0, region.height), [&](const cv::Range &rg) {
                size_t local = 0;
                for (int y = rg.start; y < rg.end; ++y) {
                    float *a = alpha.ptr<float>(y);
                    const uint8_t *act = gate.active.ptr<uint8_t>(region.y + y) + region.x;
                    for (int x = 0; x < region.width; ++x) {
                        float v = act[x] ? a[x] : 0.f;
                        v = v < kAlphaSnapLow ? 0.f : (v > kAlphaSnapHigh ? 1.f : v);
                        a[x] = v;
                        if (v > 0.f) ++local;
                    }
                }
                count += local;
            });
            changedPixels = count.load();
        }

        // --- compose ---
        if (changedPixels > 0) {
            const cv::Mat kernel = cv::getStructuringElement(cv::MORPH_RECT, cv::Size(kMorphSize, kMorphSize));
            cv::Mat mergedR = merged(region);
            // A star is in the base and in the star merge.  The merge's own speckles are
            // not in the base, and a trail in the base is not in the merge, so the
            // smaller of the two top-hats keeps stars and drops both.
            cv::Mat stars, topB;
            cv::morphologyEx(mergedR, stars, cv::MORPH_TOPHAT, kernel);
            cv::morphologyEx(baseR, topB, cv::MORPH_TOPHAT, kernel);
            cv::min(stars, topB, stars);
            topB.release();
            cv::Mat cloudLayer;
            cv::morphologyEx(Rc, cloudLayer, cv::MORPH_OPEN, kernel);
            Rc.release();

            const bool is16 = base.depth() == CV_16U;
            cv::parallel_for_(cv::Range(0, region.height), [&](const cv::Range &rg) {
                for (int y = rg.start; y < rg.end; ++y) {
                    const float *a = alpha.ptr<float>(y);
                    for (int x = 0; x < region.width; ++x) {
                        const double av = a[x];
                        if (av == 0.0) continue;       // the star merge, bit for bit
                        for (int c = 0; c < 3; ++c) {
                            if (is16) {
                                uint16_t &m = mergedR.ptr<uint16_t>(y)[3 * x + c];
                                const double v = (1.0 - av) * m
                                    + av * ((double)cloudLayer.ptr<uint16_t>(y)[3 * x + c]
                                            + (double)stars.ptr<uint16_t>(y)[3 * x + c]);
                                m = cv::saturate_cast<uint16_t>(v);
                            } else {
                                uchar &m = mergedR.ptr<uchar>(y)[3 * x + c];
                                const double v = (1.0 - av) * m
                                    + av * ((double)cloudLayer.ptr<uchar>(y)[3 * x + c]
                                            + (double)stars.ptr<uchar>(y)[3 * x + c]);
                                m = cv::saturate_cast<uchar>(v);
                            }
                        }
                    }
                }
            });
        }

        clock.mark("compose");
        if (debugDir && *debugDir) {
            cv::Mat a8 = cv::Mat::zeros(H, W, CV_8U);
            for (int y = 0; y < region.height; ++y) {
                const float *a = alpha.ptr<float>(y);
                uint8_t *d = a8.ptr<uint8_t>(region.y + y) + region.x;
                for (int x = 0; x < region.width; ++x) d[x] = cv::saturate_cast<uchar>(a[x] * 255.f);
            }
            Grid vel = velocity;
            cloudWriteDebug(debugDir, baseFrameIndex, a8, vel);
            // how badly the star merge explained the base, in image units, for looking at
            cv::Mat err16;
            gate.eM.convertTo(err16, CV_16U);
            char name[512];
            std::snprintf(name, sizeof name, "%s/cloud-error-%d.tif", debugDir, baseFrameIndex);
            cv::imwrite(name, err16);
            cloudWriteStats(debugDir, baseFrameIndex, "stage ran", gate.sigma,
                            (double)gate.floorValue, region, W, H,
                            (double)changedPixels / ((double)region.width * region.height),
                            clock, evidence);
        }

        Log_d("cloud-aware merge: frame %d region %dx%d of %dx%d, weight above 0 on %.1f%% of it, "
              "sigma %.1f floor %.1f; %.2fs wall, %.2fs cpu",
              baseFrameIndex, region.width, region.height, W, H,
              100.0 * (double)changedPixels / ((double)region.width * region.height),
              gate.sigma, (double)gate.floorValue, clock.wall(), clock.cpu());
        return changedPixels > 0;
    } catch (const cv::Exception &e) {
        Log_w("cloud-aware merge: frame %d kept the star merge, OpenCV: %s", baseFrameIndex, e.what());
    } catch (const std::exception &e) {
        Log_w("cloud-aware merge: frame %d kept the star merge: %s", baseFrameIndex, e.what());
    } catch (...) {
        Log_w("cloud-aware merge: frame %d kept the star merge, unknown error", baseFrameIndex);
    }
    return false;
}

// Test hook: with restriction off the stage works on the whole frame instead of the
// region its weight can reach, which must change nothing.  See CloudAwareMergeTests.
extern "C" void ia_debug_set_cloud_region_restriction(bool restrict) {
    cloudaware::gRestrictToRegion.store(restrict);
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
                                        bool useGPU,
                                        bool cloudAware,
                                        MatWrapperRef skyMask,
                                        const char *cloudDebugDir,
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
        const cv::Mat &base = baseImage->mat;
        const uint64_t frameBytes = (uint64_t)base.total() * base.elemSize();
        const uint64_t residentBytes = frameBytes * (uint64_t)(neighborCount + 1);
        const bool stream = streamingThresholdBytes > 0 &&
                            residentBytes > (uint64_t)streamingThresholdBytes;

        // The cloud-aware stage, which refines a finished merge in place, and which every
        // path below runs once it has one.  Nothing happens unless it was asked for, and
        // never under includeAll, which has no coverage to speak of and which nothing in
        // production passes.  `starMisses` is the merge's own coverage plane, empty when
        // the path that made the merge has none (the batched GPU merge).
        auto refineClouds = [&](MatWrapperRef merged, const cv::Mat &starMisses) {
            if (cloudAware && !includeAll && merged) {
                cloudAwareRefine(merged->mat, base, baseFrameIndex, neighbors, neighborCount,
                                 homographyKeys, homographyValues, homographyCount,
                                 outlierThreshold,
                                 skyMask ? skyMask->mat : cv::Mat(), stream, scratchDir,
                                 loadConcurrency, starMisses, cloudDebugDir);
            }
            return merged;
        };

        // What the kernel is told about the holes the warps leave, in place of
        // reading them off the pixels.  One byte per pixel counting the neighbours
        // that landed nothing there; the base is never warped, so it never adds to
        // it.  See CoverageMisses for why a count is enough, and why it is not a
        // mask per source.
        //
        // Peak cost is the plane, the probe and one warped mask per worker in
        // flight — about 120MB at 42MP with the default one loader, against the
        // frame-sized copy per source that lifting every source off zero used to
        // take.  This is the cheaper of the two as well as the one that does not
        // put words in a pixel's mouth.
        // Neither is allocated under includeAll, which counts every source at every
        // pixel and never asks about coverage: an empty plane says "no holes".
        cv::Mat misses, coverageProbe;
        if (!includeAll) {
            misses = cv::Mat::zeros(base.rows, base.cols, CV_8U);
            coverageProbe = cv::Mat(base.rows, base.cols, CV_8U, cv::Scalar(255));
        }
        std::mutex missesMutex;

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
        //
        // `useGPUForThisWarp` is passed explicitly rather than closing over the
        // outer `useGPU`: the streaming branch below still wants this lambda's
        // original per-neighbour behaviour (unchanged by this file's batched-GPU
        // work — see tryGPUAlignedMerge's doc comment for why only the resident
        // path gets the batched entry point), while the resident branch's CPU
        // fallback — reached only once a batched GPU attempt has already failed
        // for the whole frame — must force this to false so it does not also
        // retry the old, slow one-round-trip-per-warp GPU shape this change
        // replaces.
        auto warpNeighbour = [&](int i, MergeSource &out, bool useGPUForThisWarp) {
            // The homography first: a neighbour without one contributes nothing, and
            // decoding it to find that out costs a full-resolution decode per source
            // per frame — the whole sequence's worth on footage where the ground
            // cannot be aligned at all, which is exactly when it is all wasted.
            MatWrapperRef H = homographyForOffset(neighbors[i].frameIndex - baseFrameIndex,
                                                  homographyKeys, homographyValues,
                                                  homographyCount);
            if (!H) return;

            MatWrapperRef neighbor = image_cache_load(neighbors[i].filename);
            if (!neighbor) return;

            // Where the warp landed, when the warp itself can say: the CPU's exact warp
            // marks the pixels it writes as it goes, which saves the second pass over the
            // maps.  Left empty otherwise and derived below, as it always was.
            cv::Mat covered;
            cv::Mat warped;
#ifdef STAR_EXACT_WARP
            if (!useGPUForThisWarp && exactwarp::enabled() &&
                exactwarp::applies(neighbor->mat, H->mat)) {
                warped = cv::Mat::zeros(neighbor->mat.size(), neighbor->mat.type());
                if (!includeAll) covered = cv::Mat::zeros(warped.size(), CV_8UC1);
                exactwarp::warp(neighbor->mat, H->mat, warped, includeAll ? nullptr : &covered);
            } else
#endif
            warped = warpInto(neighbor->mat, H->mat, useGPUForThisWarp);
            mat_wrapper_release(neighbor);

            if (warped.rows != base.rows || warped.cols != base.cols ||
                warped.type() != base.type()) {
                out.note = std::string("aligned merge: warp of ") + neighbors[i].filename +
                           " does not match the base geometry";
                return;
            }

            // Where this warp landed nothing, recorded before the source is handed
            // on.  Only for a neighbour that is going to be merged: a source the
            // kernel never sees must not be counted against the pixels it would
            // have missed, or the kernel skips a real sample for every one of them.
            //
            // Skipped entirely under includeAll, which counts every source at every
            // pixel and never asks.
            if (!includeAll) {
                if (covered.empty()) covered = warpCoverage(coverageProbe, H->mat, useGPUForThisWarp);
                cv::bitwise_not(covered, covered);  // 255 where the warp reached nothing
                std::lock_guard<std::mutex> lock(missesMutex);
                cv::add(misses, cv::Scalar(1), misses, covered);
            }

            out.mat = warped;
            out.present = true;
        };

        int warpCount = 0;
        if (stream) {
            // Serial on purpose.  Each warp is spilled and freed within the iteration
            // that produced it — that release is the whole point of fusing the merge
            // into the alignment, and workers in flight would each hold one.
            //
            // Deliberately NOT touched by the batched-GPU work below: a fully-batched
            // command buffer holding every neighbour's warp at once works against the
            // memory discipline streaming exists for (only one warp ever resident) —
            // see GPU_MERGE_BATCHING_FIX.md ยง6. This keeps calling warpInto/
            // warpCoverage exactly as before, one GPU (or CPU) round-trip at a time.
            for (int i = 0; i < neighborCount; ++i) {
                MergeSource src;
                warpNeighbour(i, src, useGPU);
                if (!src.note.empty()) Log_w("%s", src.note.c_str());
                if (!src.present) continue;
                if (!spiller.add(src.mat)) {   // logs its own failure
                    if (errorMsg) *errorMsg = "cannot spill warped frame to scratch";
                    return nullptr;
                }
                warpCount++;
            }
        } else {
            // When useGPU is set, try the batched GPU aligned merge first: one Metal
            // command buffer carries every neighbour's warp plus this frame's own
            // median merge, replacing what used to be `neighborCount * 2 + 1`
            // separate GPU round-trips (warpInto and warpCoverage per neighbour, then
            // a final merge call) with one. See GPUOps.swift's MetalGPUBackend.
            // alignedMerge for the Metal-side implementation and
            // GPU_MERGE_BATCHING_FIX.md for why that round-trip count was the whole
            // regression, not the kernel work itself.
            //
            // No partial fallback: if this fails for any reason (no handler
            // registered, more sources than the kernel's 17-source cap, or the
            // dispatch itself failing), every neighbour is re-warped from scratch on
            // the CPU below — matching the convention SIFTDetector.cpp /
            // AKAZEDetector.cpp already use for their own GPU pipelines. There is no
            // attempt to reuse a partially-completed GPU buffer, and the per-neighbour
            // loop below is forced to `useGPUForThisWarp: false` so it cannot also
            // retry the old, slow per-neighbour GPU shape this replaces. The final
            // medianImageFromMats call past the end of this if/else still honours
            // `useGPU` as it always has — that is a single round-trip either way,
            // never the thing this fix is about.
            if (useGPU) {
                int gpuWarpCount = 0;
                if (MatWrapperRef gpuResult = tryGPUAlignedMerge(
                      base, baseFrameIndex, neighbors, neighborCount,
                      homographyKeys, homographyValues, homographyCount,
                      outlierThreshold, includeAll, loadConcurrency, &gpuWarpCount)) {
                    if (outWarpCount) *outWarpCount = gpuWarpCount;
                    return refineClouds(gpuResult, cv::Mat());
                }
            }

            // The resident path is going to hold every warp anyway, so producing them
            // concurrently costs only the sources in flight.
            std::vector<MergeSource> sources((size_t)std::max(neighborCount, 0));
            forEachMergeSource(neighborCount, loadConcurrency, [&](int i) {
                warpNeighbour(i, sources[(size_t)i], /*useGPUForThisWarp=*/false);
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

        if (stream) {
            return refineClouds(spiller.merge({base}, outlierThreshold, includeAll, misses),
                                misses);
        }

        MatWrapperRef merged;
        {
            std::vector<cv::Mat> mats;
            mats.reserve(warps.size() + 1);
            mats.push_back(base);
            mats.insert(mats.end(), warps.begin(), warps.end());
            merged = medianImageFromMats(mats, outlierThreshold, includeAll, misses, useGPU);
        }
        // The star warps have done their job.  The cloud-aware stage reads the originals
        // again (decoded once already, so a cache hit while the frame's decodes are
        // pinned) and has no use for them, and holding them would put its own peak on top
        // of theirs.
        warps.clear();
        return refineClouds(merged, misses);
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

MatWrapperRef ia_masked_stretch_to_gray8(MatWrapperRef image, MatWrapperRef mask) {
    if (!image) return nullptr;
    try {
        return wrap(toGray8UWithMask(image->mat, mask ? mask->mat : cv::Mat()));
    } KHT_CATCH_LOG("ia_masked_stretch_to_gray8")
    return nullptr;
}

MatWrapperRef ia_debug_warp(MatWrapperRef src, MatWrapperRef homography, bool useGPU) {
    if (!src || !homography || homography->mat.rows != 3 || homography->mat.cols != 3) {
        return nullptr;
    }
    try {
        return wrap(warpInto(src->mat, homography->mat, useGPU));
    } KHT_CATCH_LOG("ia_debug_warp")
    return nullptr;
}

extern "C" void ia_debug_set_exact_warp(bool enabled) {
#ifdef STAR_EXACT_WARP
    exactwarp::gDisabled.store(enabled ? 0 : 1);
#else
    (void)enabled;
#endif
}

extern "C" bool ia_debug_exact_warp_is_available(void) {
#ifdef STAR_EXACT_WARP
    return exactwarp::enabled();
#else
    return false;
#endif
}

extern "C" void ia_debug_set_pair_match(bool enabled) {
    pairmatch::gDisabled.store(enabled ? 0 : 1);
}

extern "C" bool ia_debug_pair_match_is_enabled(void) {
    return pairmatch::enabled();
}

extern "C" int ia_debug_pair_match_waiting(bool clear) {
    if (clear) pairmatch::waiting().clear();
    return (int)pairmatch::waiting().count();
}

extern "C" int ia_debug_pair_match_selftest(int trials, unsigned int seed) {
    return pairmatch::selfTest(trials, seed);
}

extern "C" void ia_debug_set_median_kernel(bool forceReference) {
    gMedianKernelOverride.store(forceReference ? 1 : 0);
}

extern "C" bool ia_debug_median_kernel_is_exact(void) {
    return mergeKernelForThisMachine() == MergeKernel::ExactAvx2;
}

MatWrapperRef ia_debug_median_merge(MatWrapperRef *sources, int count, MatWrapperRef misses,
                                    double outlierThreshold, bool includeAll, bool useGPU) {
    if (!sources || count <= 0) return nullptr;
    try {
        std::vector<cv::Mat> mats;
        mats.reserve((size_t)count);
        for (int i = 0; i < count; ++i) {
            if (!sources[i]) return nullptr;
            mats.push_back(sources[i]->mat);
        }
        return medianImageFromMats(mats, outlierThreshold, includeAll,
                                   misses ? misses->mat : cv::Mat(), useGPU);
    } KHT_CATCH_LOG("ia_debug_median_merge")
    return nullptr;
}

OCVFeatureSetRef ia_debug_sift_reference(MatWrapperRef img, MatWrapperRef mask, int nfeatures) {
    if (!img || img->mat.empty()) return nullptr;
    try {
        std::vector<cv::KeyPoint> keypoints;
        cv::Mat descriptors;
        if (!star_sift::siftDetectAndComputeReference(
              img->mat, mask ? mask->mat : cv::Mat(), nfeatures, keypoints, descriptors)) {
            return nullptr;
        }
        return new OCVFeatureSetImpl(keypoints, descriptors);
    } KHT_CATCH_LOG("ia_debug_sift_reference")
    return nullptr;
}

OCVFeatureSetRef ia_debug_sift_gpu(MatWrapperRef img, MatWrapperRef mask, int nfeatures) {
    if (!img || img->mat.empty()) return nullptr;
    try {
        std::vector<cv::KeyPoint> keypoints;
        cv::Mat descriptors;
        if (!star_sift::siftDetectAndComputeGPU(
              img->mat, mask ? mask->mat : cv::Mat(), nfeatures, keypoints, descriptors)) {
            return nullptr;
        }
        return new OCVFeatureSetImpl(keypoints, descriptors);
    } KHT_CATCH_LOG("ia_debug_sift_gpu")
    return nullptr;
}

OCVFeatureSetRef ia_debug_sift_opencv(MatWrapperRef img, MatWrapperRef mask, int nfeatures) {
    if (!img || img->mat.empty()) return nullptr;
    try {
        std::vector<cv::KeyPoint> keypoints;
        cv::Mat descriptors;
        cv::Ptr<cv::SIFT> sift = cv::SIFT::create(nfeatures);
        sift->detectAndCompute(img->mat, mask ? mask->mat : cv::Mat(), keypoints, descriptors);
        return new OCVFeatureSetImpl(keypoints, descriptors);
    } KHT_CATCH_LOG("ia_debug_sift_opencv")
    return nullptr;
}

OCVFeatureSetRef ia_debug_akaze_reference(MatWrapperRef img, MatWrapperRef mask,
                                          int maxKeypoints, float threshold) {
    if (!img || img->mat.empty()) return nullptr;
    try {
        std::vector<cv::KeyPoint> keypoints;
        cv::Mat descriptors;
        if (!star_akaze::akazeDetectAndComputeReference(
              img->mat, mask ? mask->mat : cv::Mat(), maxKeypoints, threshold,
              keypoints, descriptors)) {
            return nullptr;
        }
        return new OCVFeatureSetImpl(keypoints, descriptors);
    } KHT_CATCH_LOG("ia_debug_akaze_reference")
    return nullptr;
}

OCVFeatureSetRef ia_debug_akaze_gpu(MatWrapperRef img, MatWrapperRef mask,
                                    int maxKeypoints, float threshold) {
    if (!img || img->mat.empty()) return nullptr;
    try {
        std::vector<cv::KeyPoint> keypoints;
        cv::Mat descriptors;
        if (!star_akaze::akazeDetectAndComputeGPU(
              img->mat, mask ? mask->mat : cv::Mat(), maxKeypoints, threshold,
              keypoints, descriptors)) {
            return nullptr;
        }
        return new OCVFeatureSetImpl(keypoints, descriptors);
    } KHT_CATCH_LOG("ia_debug_akaze_gpu")
    return nullptr;
}

// Mirrors this codebase's own earth branch above exactly (detect, cap by
// response, then describe) rather than a single detectAndCompute call, since
// that two-step shape — not AKAZE's own unused max_points — is what this
// codebase actually runs and what akazeDetectAndCompute{Reference,GPU} above
// are being compared against.
OCVFeatureSetRef ia_debug_akaze_opencv(MatWrapperRef img, MatWrapperRef mask,
                                       int maxKeypoints, float threshold) {
    if (!img || img->mat.empty()) return nullptr;
    try {
        std::vector<cv::KeyPoint> keypoints;
        cv::Mat descriptors;
        cv::Ptr<cv::AKAZE> akaze = cv::AKAZE::create();
        akaze->setThreshold(threshold);
        akaze->detect(img->mat, keypoints, mask ? mask->mat : cv::Mat());
        if (maxKeypoints > 0 && (int)keypoints.size() > maxKeypoints) {
            cv::KeyPointsFilter::retainBest(keypoints, maxKeypoints);
        }
        akaze->compute(img->mat, keypoints, descriptors);
        return new OCVFeatureSetImpl(keypoints, descriptors);
    } KHT_CATCH_LOG("ia_debug_akaze_opencv")
    return nullptr;
}
