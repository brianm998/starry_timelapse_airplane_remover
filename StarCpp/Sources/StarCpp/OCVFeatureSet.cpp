// OCVFeatureSet.cpp — Pure C++ implementation
#include "OCVFeatureSet.h"
#include "OCVFeatureSetImpl.hpp"
#include "logging_impl.hpp"

#include <opencv2/core.hpp>
#include <opencv2/features2d.hpp>
#include <string>
#include <cstring>
#include <sys/stat.h>
#include <atomic>
#include <filesystem>
#include <cstdio>
#include <cstdint>
#include <cmath>
#ifdef _WIN32
  #include <process.h>
  static inline long featureWriterPid() { return _getpid(); }
#else
  #include <unistd.h>
  static inline long featureWriterPid() { return static_cast<long>(getpid()); }
#endif

// MSVC's <sys/stat.h> does not define the POSIX S_ISDIR macro; it only
// exposes the S_IFMT / S_IFDIR bit constants. Define S_ISDIR ourselves
// when it's missing so the same code compiles on Windows, Linux, and macOS.
#ifndef S_ISDIR
#define S_ISDIR(m) (((m) & S_IFMT) == S_IFDIR)
#endif

// ---- Binary layout (`.kpb`) -------------------------------------------------------------
// Header (all little-endian): magic "STARKP01" (8 bytes), then int64 keypoint count,
// int64 descriptor rows, int64 descriptor cols, int32 descriptor type, int32 descriptor encoding
// (0 raw bytes; 1 a CV_32F matrix whose values are all whole numbers in 0..255, which is what the
// SIFT detector produces, stored as one byte each and widened on load: lossless), int64 star count.
// Then keypoints (x, y, size, angle, response as float32; octave, class_id as int32: 28 bytes
// each), the descriptor bytes (rows * cols * elemSize, rows contiguous), and the stars as
// float32 (x, y) pairs.  The platforms star builds for are all little-endian.
static const char kBinaryMagic[8] = {'S','T','A','R','K','P','0','1'};
static const int64_t kMaxBinaryCount = (int64_t)1 << 32;

static bool endsWith(const std::string &s, const char *suffix) {
    const size_t n = strlen(suffix);
    return s.size() >= n && s.compare(s.size() - n, n, suffix) == 0;
}

static bool writeBinary(const OCVFeatureSetImpl *ref, const std::string &path) {
    cv::Mat desc = ref->descriptors.isContinuous() ? ref->descriptors : ref->descriptors.clone();
    int32_t encoding = 0;
    if (!desc.empty() && desc.type() == CV_32F) {
        const float *f = (const float *)desc.data;
        const size_t n = desc.total();
        bool whole = true;
        for (size_t i = 0; i < n && whole; i++) {
            const float v = f[i];
            whole = v >= 0.f && v <= 255.f && v == std::floor(v);
        }
        if (whole) encoding = 1;
    }
    std::vector<char> buf;
    const size_t descBytes = desc.empty() ? 0
        : (encoding == 1 ? desc.total() : desc.total() * desc.elemSize());
    buf.reserve(8 + 8*4 + 8 + ref->keypoints.size() * 28 + descBytes + ref->stars.size() * 8);
    auto put = [&](const void *p, size_t n) {
        const char *c = (const char *)p;
        buf.insert(buf.end(), c, c + n);
    };
    put(kBinaryMagic, 8);
    const int64_t nk = (int64_t)ref->keypoints.size();
    const int64_t rows = desc.rows, cols = desc.cols;
    const int32_t type = desc.empty() ? 0 : desc.type();
    const int64_t ns = (int64_t)ref->stars.size();
    put(&nk, 8); put(&rows, 8); put(&cols, 8); put(&type, 4); put(&encoding, 4); put(&ns, 8);
    for (const auto &k : ref->keypoints) {
        const float f[5] = {k.pt.x, k.pt.y, k.size, k.angle, k.response};
        const int32_t i[2] = {(int32_t)k.octave, (int32_t)k.class_id};
        put(f, 20); put(i, 8);
    }
    if (encoding == 1) {
        const float *f = (const float *)desc.data;
        for (size_t i = 0; i < descBytes; i++) { const char c = (char)(uint8_t)f[i]; put(&c, 1); }
    } else if (descBytes) {
        put(desc.data, descBytes);
    }
    for (const auto &p : ref->stars) {
        const float f[2] = {p.x, p.y};
        put(f, 8);
    }
    FILE *fp = fopen(path.c_str(), "wb");
    if (!fp) return false;
    const bool ok = fwrite(buf.data(), 1, buf.size(), fp) == buf.size();
    return (fclose(fp) == 0) && ok;
}

// Returns 1 loaded, 0 not a binary file (no magic), -1 binary but corrupt.
static int readBinary(const std::string &path, OCVFeatureSetImpl *out) {
    FILE *fp = fopen(path.c_str(), "rb");
    if (!fp) return 0;
    char magic[8];
    if (fread(magic, 1, 8, fp) != 8 || memcmp(magic, kBinaryMagic, 8) != 0) {
        fclose(fp);
        return 0;
    }
    int64_t nk, rows, cols, ns;
    int32_t type, encoding;
    bool ok = fread(&nk, 8, 1, fp) == 1 && fread(&rows, 8, 1, fp) == 1 &&
              fread(&cols, 8, 1, fp) == 1 && fread(&type, 4, 1, fp) == 1 &&
              fread(&encoding, 4, 1, fp) == 1 && (encoding == 0 || (encoding == 1 && type == CV_32F)) &&
              fread(&ns, 8, 1, fp) == 1;
    if (!ok || nk < 0 || ns < 0 || rows < 0 || cols < 0 ||
        nk > kMaxBinaryCount || ns > kMaxBinaryCount || rows > kMaxBinaryCount || cols > kMaxBinaryCount) {
        fclose(fp);
        return -1;
    }
    std::vector<char> kb((size_t)nk * 28);
    ok = kb.empty() || fread(kb.data(), 1, kb.size(), fp) == kb.size();
    cv::Mat desc;
    if (ok && rows > 0 && cols > 0) {
        desc.create((int)rows, (int)cols, type);
        if (encoding == 1) {
            std::vector<uint8_t> bytes(desc.total());
            ok = fread(bytes.data(), 1, bytes.size(), fp) == bytes.size();
            float *f = (float *)desc.data;
            if (ok) for (size_t i = 0; i < bytes.size(); i++) f[i] = (float)bytes[i];
        } else {
            const size_t n = desc.total() * desc.elemSize();
            ok = fread(desc.data, 1, n, fp) == n;
        }
    }
    std::vector<float> sb((size_t)ns * 2);
    if (ok && !sb.empty()) ok = fread(sb.data(), 4, sb.size(), fp) == sb.size();
    fclose(fp);
    if (!ok) return -1;
    out->keypoints.resize((size_t)nk);
    for (int64_t j = 0; j < nk; j++) {
        float f[5]; int32_t i[2];
        memcpy(f, &kb[(size_t)j * 28], 20);
        memcpy(i, &kb[(size_t)j * 28 + 20], 8);
        cv::KeyPoint &k = out->keypoints[(size_t)j];
        k.pt = cv::Point2f(f[0], f[1]);
        k.size = f[2]; k.angle = f[3]; k.response = f[4];
        k.octave = i[0]; k.class_id = i[1];
    }
    out->descriptors = desc;
    out->stars.resize((size_t)ns);
    for (int64_t j = 0; j < ns; j++) out->stars[(size_t)j] = cv::Point2f(sb[(size_t)j*2], sb[(size_t)j*2+1]);
    return 1;
}

OCVFeatureSetRef ocv_feature_set_load(const char *filename, const char **errorMsg) {
    struct stat sb;
    if (stat(filename, &sb) != 0 || S_ISDIR(sb.st_mode)) {
        if (errorMsg) *errorMsg = "Feature file does not exist";
        return nullptr;
    }

    auto *fs = new OCVFeatureSetImpl();
    try {
        // The magic decides, not the extension: the binary layout, else cv::FileStorage for
        // the YAML older versions wrote.
        const int binary = readBinary(std::string(filename), fs);
        if (binary < 0) {
            if (errorMsg) *errorMsg = "Corrupt binary feature file";
            delete fs;
            return nullptr;
        }
        if (binary == 0) {
        cv::FileStorage storage(std::string(filename), cv::FileStorage::READ);
        if (!storage.isOpened()) {
            if (errorMsg) *errorMsg = "Failed to open feature file";
            delete fs;
            return nullptr;
        }
        storage["keypoints"] >> fs->keypoints;
        storage["descriptors"] >> fs->descriptors;
        // absent from earth files, and from sky files written before stars were kept
        cv::FileNode stars = storage["stars"];
        if (!stars.empty()) stars >> fs->stars;
        storage.release();
        }

        // A sky frame SIFT found nothing in can still have its stars, and they alone
        // can align it — see refineSkyHomographyWithStars.
        if ((fs->keypoints.empty() || fs->descriptors.empty()) && fs->stars.empty()) {
            if (errorMsg) *errorMsg = "Feature file contained no data";
            delete fs;
            return nullptr;
        }
    } catch (...) {
        if (errorMsg) *errorMsg = "Exception loading feature file";
        delete fs;
        return nullptr;
    }
    return fs;
}

void ocv_feature_set_release(OCVFeatureSetRef ref) {
    delete ref;
}

int64_t ocv_feature_set_keypoint_count(OCVFeatureSetRef ref) {
    return ref ? (int64_t)ref->keypoints.size() : 0;
}

int64_t ocv_feature_set_star_count(OCVFeatureSetRef ref) {
    return ref ? (int64_t)ref->stars.size() : 0;
}

int64_t ocv_feature_set_descriptor_rows(OCVFeatureSetRef ref) {
    return ref ? ref->descriptors.rows : 0;
}

int64_t ocv_feature_set_descriptor_cols(OCVFeatureSetRef ref) {
    return ref ? ref->descriptors.cols : 0;
}

int ocv_feature_set_descriptor_type(OCVFeatureSetRef ref) {
    return ref ? ref->descriptors.type() : 0;
}

int64_t ocv_feature_set_keypoint_positions(OCVFeatureSetRef ref,
                                           double *xy, int64_t capacity) {
    if (!ref || !xy || capacity < 2) return 0;
    const int64_t want = (int64_t)ref->keypoints.size();
    const int64_t count = std::min(want, capacity / 2);
    for (int64_t i = 0; i < count; i++) {
        xy[i * 2]     = (double)ref->keypoints[(size_t)i].pt.x;
        xy[i * 2 + 1] = (double)ref->keypoints[(size_t)i].pt.y;
    }
    return count;
}

bool ocv_feature_set_write(OCVFeatureSetRef ref, const char *filename,
                           const char **errorMsg) {
    if (!ref || ((ref->keypoints.empty() || ref->descriptors.empty()) && ref->stars.empty())) {
        if (errorMsg) *errorMsg = "No features to write";
        return false;
    }

    // Written beside the destination and renamed into place. Written in place, a crash or a full
    // disk part way through left a torn file at the real name, and every neighbour's homography op
    // then failed to parse it. The temp name keeps the extension (cv::FileStorage picks YAML, XML or
    // JSON from it) and is unique per call, with the same `.tmp.<pid>-<n>` shape the image writer
    // uses, so a stale one is recognisable and removable.
    static std::atomic<unsigned long> sequence{0};
    const std::string target(filename);
    std::string base = target, extension;
    const size_t dot = target.find_last_of('.');
    const size_t slash = target.find_last_of("/\\");
    if (dot != std::string::npos && (slash == std::string::npos || dot > slash)) {
        base = target.substr(0, dot);
        extension = target.substr(dot);
    }
    const std::string temp = base + ".tmp." + std::to_string(featureWriterPid()) + "-" +
                             std::to_string(sequence.fetch_add(1)) + extension;
    std::error_code ignored;
    try {
        if (endsWith(target, ".kpb")) {
            if (!writeBinary(ref, temp)) {
                std::filesystem::remove(temp, ignored);
                if (errorMsg) *errorMsg = "Failed to write binary feature file";
                return false;
            }
        } else {
            cv::FileStorage storage(temp, cv::FileStorage::WRITE);
            if (!storage.isOpened()) {
                if (errorMsg) *errorMsg = "Failed to open file for writing";
                return false;
            }
            storage << "keypoints" << ref->keypoints;
            storage << "descriptors" << ref->descriptors;
            if (!ref->stars.empty()) storage << "stars" << ref->stars;
            storage.release();
        }
        std::error_code ec;
        std::filesystem::rename(temp, target, ec);
        if (ec) {
            std::filesystem::remove(temp, ignored);
            if (errorMsg) *errorMsg = "Failed to move the feature file into place";
            return false;
        }
    } catch (...) {
        std::filesystem::remove(temp, ignored);
        if (errorMsg) *errorMsg = "Exception writing feature file";
        return false;
    }
    return true;
}
