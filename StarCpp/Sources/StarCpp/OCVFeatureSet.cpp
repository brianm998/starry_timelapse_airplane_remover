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

OCVFeatureSetRef ocv_feature_set_create_empty(void) {
    return new OCVFeatureSetImpl();
}

OCVFeatureSetRef ocv_feature_set_load(const char *filename, const char **errorMsg) {
    struct stat sb;
    if (stat(filename, &sb) != 0 || S_ISDIR(sb.st_mode)) {
        if (errorMsg) *errorMsg = "Feature file does not exist";
        return nullptr;
    }

    auto *fs = new OCVFeatureSetImpl();
    try {
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
        {
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
