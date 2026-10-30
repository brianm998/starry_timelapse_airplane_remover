// PairMatch.hpp — `BFMatcher(norm).knnMatch(query, train, matches, 2)`, with the work of the
// reverse match, which the partner frame's alignment op is about to ask for, done in the same pass.
//
// Every frame is aligned against the ones around it, and on a moving sequence that matches each
// unordered pair of frames twice: frame A's op matches B's descriptors against A's (query B, train
// A), and B's op, some seconds later, matches A's against B's.  The two are the rows and the
// columns of one distance matrix, and OpenCV's distances are symmetric to the bit — L2 is
// `sqrt(hal::normL2Sqr_(a, b))`, a sum of (a_i - b_i)^2 in a fixed order that does not care which
// of the two is `a`, and Hamming is a popcount of the XOR — so computing the matrix once gives
// both answers.
//
// What a BFMatcher returns for a query row, from reading `batchDistance` and
// `BFMatcher::knnMatchImpl` in the vendored 4.12.0:
//
//  * the distance of every train row, `float` for L2 (the square root taken in float) and `int`
//    for Hamming (converted to float afterwards);
//  * the K = min(2, train rows) smallest, by inserting in train order with a strict `<` against the
//    current K-th (compared as integers — non-negative floats order like their bit patterns), which
//    is the K smallest under (distance, train index): a tie goes to the lower index.  A distance
//    that is not below the sentinel (FLT_MAX / INT_MAX: an infinity, a NaN) is never inserted;
//  * `DMatch(queryIdx, trainIdx, 0, distance)`, one list per query row, shorter than K only when
//    fewer rows qualified.
//
// This computes that, forward for the rows of `query` against `train` and in the same pass
// backward for the rows of `train` against `query`, with the selection written as "the K smallest
// under (distance, index)" so that any order of visiting the pairs gives the same lists.  The
// backward result is kept, keyed by the content of the two descriptor sets, for whichever
// `knn2` call asks for exactly that match next; a call that finds its answer waiting skips the
// distance matrix altogether.  A stale or mismatched entry cannot be used: the key is a hash of
// the descriptors themselves, and a miss is simply computed.
//
// `STAR_MATCH=opencv` in the environment turns the whole thing off (BFMatcher as before), for an
// A/B of a real run.  Only CV_32F with NORM_L2 and CV_8U with NORM_HAMMING are handled here (the
// two star uses); anything else goes to BFMatcher.
#pragma once

#include <opencv2/core.hpp>
#include <opencv2/core/hal/hal.hpp>
#include <opencv2/core/utility.hpp>
#include <opencv2/features2d.hpp>

#include <atomic>
#include <cfloat>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <random>
#include <unordered_map>
#include <vector>

namespace pairmatch {

// Whether the pair matcher is used.  `gDisabled` is the same for a test, which holds the two to
// each other in one process.  The environment is read once.
inline std::atomic<int> gDisabled{0};
inline bool enabled() {
    static const bool allowed = [] {
        const char *env = std::getenv("STAR_MATCH");
        return !(env && std::strcmp(env, "opencv") == 0);
    }();
    return allowed && gDisabled.load(std::memory_order_relaxed) == 0;
}

// One query row's answer: up to two (key, train index) pairs, best first.  `key` is what the
// selection compares: the bit pattern of an L2 distance, the integer of a Hamming one.
struct Row {
    int32_t key[2];
    int32_t idx[2];
    int32_t count = 0;
};

constexpr int32_t kFloatSentinel = 0x7f7fffff;   // bits of FLT_MAX: nothing at or above it is inserted
constexpr int32_t kIntSentinel = INT_MAX;

// Offer (key, idx) to a row: kept if it is among the two smallest under (key, idx).
inline void offer(Row &r, int32_t key, int32_t idx, int32_t sentinel) {
    if (key >= sentinel) return;
    auto less = [](int32_t k1, int32_t i1, int32_t k2, int32_t i2) {
        return k1 < k2 || (k1 == k2 && i1 < i2);
    };
    if (r.count < 2) {
        if (r.count == 0) { r.key[0] = key; r.idx[0] = idx; r.count = 1; return; }
        if (less(key, idx, r.key[0], r.idx[0])) {
            r.key[1] = r.key[0]; r.idx[1] = r.idx[0]; r.key[0] = key; r.idx[0] = idx;
        } else {
            r.key[1] = key; r.idx[1] = idx;
        }
        r.count = 2;
        return;
    }
    if (!less(key, idx, r.key[1], r.idx[1])) return;
    if (less(key, idx, r.key[0], r.idx[0])) {
        r.key[1] = r.key[0]; r.idx[1] = r.idx[0]; r.key[0] = key; r.idx[0] = idx;
    } else {
        r.key[1] = key; r.idx[1] = idx;
    }
}

// The distance of one pair as a comparable integer, exactly as batchDistance forms it.
inline int32_t l2Key(const float *a, const float *b, int len) {
    const float d = std::sqrt(cv::hal::normL2Sqr_(a, b, len));
    int32_t bits;
    std::memcpy(&bits, &d, sizeof bits);
    return bits;
}
inline int32_t hammingKey(const uchar *a, const uchar *b, int len) {
    return cv::hal::normHamming(a, b, len);
}

// A hash of a descriptor set's content (and its shape): 64-bit, eight bytes at a time.
inline uint64_t hashDescriptors(const cv::Mat &m) {
    uint64_t h = 0x9E3779B97F4A7C15ull ^ ((uint64_t)m.rows * 0xBF58476D1CE4E5B9ull)
               ^ ((uint64_t)m.cols * 0x94D049BB133111EBull) ^ (uint64_t)m.type();
    const size_t rowBytes = (size_t)m.cols * m.elemSize();
    for (int y = 0; y < m.rows; ++y) {
        const uint8_t *p = m.ptr<uint8_t>(y);
        size_t i = 0;
        for (; i + 8 <= rowBytes; i += 8) {
            uint64_t w;
            std::memcpy(&w, p + i, 8);
            h = (h ^ w) * 0xFF51AFD7ED558CCDull;
            h ^= h >> 32;
        }
        for (; i < rowBytes; ++i) h = (h ^ p[i]) * 0x100000001B3ull;
        h ^= (uint64_t)y;
    }
    return h;
}

struct PairResult {
    std::vector<Row> forward;    // one per row of `query`: its two nearest rows of `train`
    std::vector<Row> reverse;    // one per row of `train`: its two nearest rows of `query`
};

// The distance matrix of `query` against `train`, both ways at once.
inline PairResult computePair(const cv::Mat &query, const cv::Mat &train, bool hamming) {
    const int N = query.rows, M = train.rows, len = query.cols;
    PairResult out;
    out.forward.assign((size_t)N, Row{});
    out.reverse.assign((size_t)M, Row{});
    if (N == 0 || M == 0) return out;
    const int32_t sentinel = hamming ? kIntSentinel : kFloatSentinel;

    // Chunks of query rows, each with its own reverse rows; merged afterwards.  The selection is
    // "the two smallest under (key, index)", so neither the chunking nor the order the chunks
    // are merged in can change a result.
    const int nChunks = std::max(1, std::min(N, cv::getNumThreads() * 2));
    const int chunkRows = (N + nChunks - 1) / nChunks;
    std::vector<std::vector<Row>> partial((size_t)nChunks);

    cv::parallel_for_(cv::Range(0, nChunks), [&](const cv::Range &r) {
        for (int c = r.start; c < r.end; ++c) {
            const int i0 = c * chunkRows, i1 = std::min(N, i0 + chunkRows);
            if (i0 >= i1) continue;
            std::vector<Row> &rev = partial[(size_t)c];
            rev.assign((size_t)M, Row{});
            for (int i = i0; i < i1; ++i) {
                Row &fwd = out.forward[(size_t)i];
                if (hamming) {
                    const uchar *q = query.ptr<uchar>(i);
                    for (int j = 0; j < M; ++j) {
                        const int32_t k = hammingKey(q, train.ptr<uchar>(j), len);
                        offer(fwd, k, j, sentinel);
                        offer(rev[(size_t)j], k, i, sentinel);
                    }
                } else {
                    const float *q = query.ptr<float>(i);
                    for (int j = 0; j < M; ++j) {
                        const int32_t k = l2Key(q, train.ptr<float>(j), len);
                        offer(fwd, k, j, sentinel);
                        offer(rev[(size_t)j], k, i, sentinel);
                    }
                }
            }
        }
    });

    for (int c = 0; c < nChunks; ++c) {
        const std::vector<Row> &rev = partial[(size_t)c];
        if (rev.empty()) continue;
        for (int j = 0; j < M; ++j) {
            const Row &p = rev[(size_t)j];
            for (int e = 0; e < p.count; ++e) offer(out.reverse[(size_t)j], p.key[e], p.idx[e], sentinel);
        }
    }
    return out;
}

// What DescriptorMatcher::knnMatch hands back for these rows.
inline void toMatches(const std::vector<Row> &rows, bool hamming,
                      std::vector<std::vector<cv::DMatch>> &matches)
{
    matches.clear();
    matches.reserve(rows.size());
    for (size_t q = 0; q < rows.size(); ++q) {
        matches.emplace_back();
        std::vector<cv::DMatch> &mq = matches.back();
        mq.reserve(2);
        for (int e = 0; e < rows[q].count; ++e) {
            float d;
            if (hamming) d = (float)rows[q].key[e];
            else std::memcpy(&d, &rows[q].key[e], sizeof d);
            mq.push_back(cv::DMatch((int)q, rows[q].idx[e], 0, d));
        }
    }
}

// The backward results waiting for the call that wants them.
class Waiting {
public:
    struct Key {
        uint64_t query, train;
        int norm;
        bool operator==(const Key &o) const { return query == o.query && train == o.train && norm == o.norm; }
    };
    struct KeyHash {
        size_t operator()(const Key &k) const {
            return (size_t)(k.query * 0x9E3779B97F4A7C15ull ^ (k.train + 0x7F4A7C15ull) * 0xC2B2AE3D27D4EB4Full ^ (uint64_t)k.norm);
        }
    };

    // At most this many bytes of results are kept; the oldest go first.  A partner op that never
    // comes (the end of a sequence, a frame without keypoints) must not accumulate.
    static constexpr size_t kMaxBytes = 128u << 20;

    void put(const Key &key, std::shared_ptr<const std::vector<Row>> rows) {
        const size_t bytes = rows->size() * sizeof(Row);
        if (bytes > kMaxBytes) return;
        std::lock_guard<std::mutex> lock(mutex_);
        if (map_.count(key)) return;
        map_.emplace(key, std::move(rows));
        order_.push_back(key);
        bytes_ += bytes;
        while (bytes_ > kMaxBytes && !order_.empty()) {
            auto it = map_.find(order_.front());
            if (it != map_.end()) { bytes_ -= it->second->size() * sizeof(Row); map_.erase(it); }
            order_.pop_front();
        }
    }

    // The waiting answer, which is then not waiting any more.
    std::shared_ptr<const std::vector<Row>> take(const Key &key) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = map_.find(key);
        if (it == map_.end()) return nullptr;
        auto rows = std::move(it->second);
        bytes_ -= rows->size() * sizeof(Row);
        map_.erase(it);
        return rows;
    }

    size_t count() {
        std::lock_guard<std::mutex> lock(mutex_);
        return map_.size();
    }

    void clear() {
        std::lock_guard<std::mutex> lock(mutex_);
        map_.clear();
        order_.clear();
        bytes_ = 0;
    }

private:
    std::mutex mutex_;
    std::unordered_map<Key, std::shared_ptr<const std::vector<Row>>, KeyHash> map_;
    std::deque<Key> order_;
    size_t bytes_ = 0;
};

inline Waiting &waiting() {
    static Waiting w;
    return w;
}

// How the calls have gone since the process started: asked for, answered from a waiting result,
// and computed (the rest, less the ones this does not handle).
struct Stats {
    std::atomic<uint64_t> calls{0}, hits{0}, computed{0};
};
inline Stats &stats() {
    static Stats st;
    return st;
}

// Whether `knn2` handles this combination itself.
inline bool handles(const cv::Mat &query, const cv::Mat &train, int normType) {
    if (query.dims != 2 || train.dims != 2 || query.rows < 1 || train.rows < 1) return false;
    if (query.type() != train.type() || query.cols != train.cols || query.cols < 1) return false;
    if (query.type() == CV_32FC1) return normType == cv::NORM_L2;
    if (query.type() == CV_8UC1) return normType == cv::NORM_HAMMING;
    return false;
}

// cv::BFMatcher(normType).knnMatch(query, train, matches, 2), sharing the pair's work.
inline void knn2(const cv::Mat &query, const cv::Mat &train, int normType,
                 std::vector<std::vector<cv::DMatch>> &matches)
{
    if (!enabled() || !handles(query, train, normType)) {
        cv::BFMatcher(normType).knnMatch(query, train, matches, 2);
        return;
    }
    const bool hamming = query.type() == CV_8UC1;
    const uint64_t hq = hashDescriptors(query), ht = hashDescriptors(train);
    stats().calls.fetch_add(1, std::memory_order_relaxed);

    if (auto waitingAnswer = waiting().take({hq, ht, normType})) {
        stats().hits.fetch_add(1, std::memory_order_relaxed);
        toMatches(*waitingAnswer, hamming, matches);
        return;
    }
    stats().computed.fetch_add(1, std::memory_order_relaxed);
    PairResult pair = computePair(query, train, hamming);
    toMatches(pair.forward, hamming, matches);
    // the match the partner will ask for: train's rows against query's
    waiting().put({ht, hq, normType}, std::make_shared<const std::vector<Row>>(std::move(pair.reverse)));
}

// Test hook: random descriptor sets (float L2 and packed-bit Hamming, with ties and overflowing
// sums among them) through `knn2` and its cache, against BFMatcher in both directions.  Returns
// the number of results that differ, 0 being a pass.
inline int selfTest(int trials, uint32_t seed) {
    std::mt19937_64 gen(seed);
    auto sameMatches = [](const std::vector<std::vector<cv::DMatch>> &a, const std::vector<std::vector<cv::DMatch>> &b) {
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
    };
    auto makeSet = [&](int rows, int cols, bool bits, int mode) {
        cv::Mat m(rows, cols, bits ? CV_8UC1 : CV_32FC1);
        for (int y = 0; y < rows; ++y)
            for (int x = 0; x < cols; ++x) {
                const uint64_t r = gen();
                if (bits) {
                    m.at<uchar>(y, x) = mode == 0 ? (uchar)(r & 0xff) : mode == 1 ? (uchar)((r & 3) ? 0 : 0xff) : (uchar)0x5a;
                } else {
                    m.at<float>(y, x) = mode == 0 ? (float)(r % 256) : mode == 1 ? (float)(r % 3)
                                      : mode == 2 ? 1.5f : ((r & 7) ? 3e19f : (float)(r % 7));
                }
            }
        return m;
    };
    const bool was = gDisabled.load();
    gDisabled.store(0);
    waiting().clear();
    int bad = 0;
    const int sizes[] = {1, 2, 3, 9, 40, 300};
    for (int t = 0; t < trials; ++t) {
        const bool bits = gen() & 1;
        const int N = sizes[gen() % 6], M = sizes[gen() % 6];
        const int len = bits ? 61 : 128, norm = bits ? cv::NORM_HAMMING : cv::NORM_L2;
        const int mode = (int)(gen() % (bits ? 3 : 4));
        cv::Mat q = makeSet(N, len, bits, mode), t2 = makeSet(M, len, bits, mode);
        std::vector<std::vector<cv::DMatch>> refF, refR, a, b;
        cv::BFMatcher(norm).knnMatch(q, t2, refF, 2);
        cv::BFMatcher(norm).knnMatch(t2, q, refR, 2);
        knn2(q, t2, norm, a);      // computes, keeps the reverse
        knn2(t2, q, norm, b);      // finds it waiting
        bad += !sameMatches(a, refF);
        bad += !sameMatches(b, refR);
    }
    waiting().clear();
    gDisabled.store(was ? 1 : 0);
    return bad;
}

}  // namespace pairmatch
