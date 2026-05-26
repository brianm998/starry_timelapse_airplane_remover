// OCVFeatureSet.cpp — Pure C++ implementation
#include "OCVFeatureSet.h"
#include "OCVFeatureSetImpl.hpp"
#include "logging_impl.hpp"

#include <opencv2/core.hpp>
#include <opencv2/features2d.hpp>
#include <string>
#include <cstring>
#include <sys/stat.h>

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
        storage.release();

        if (fs->keypoints.empty() || fs->descriptors.empty()) {
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

int64_t ocv_feature_set_descriptor_rows(OCVFeatureSetRef ref) {
    return ref ? ref->descriptors.rows : 0;
}

int64_t ocv_feature_set_descriptor_cols(OCVFeatureSetRef ref) {
    return ref ? ref->descriptors.cols : 0;
}

int ocv_feature_set_descriptor_type(OCVFeatureSetRef ref) {
    return ref ? ref->descriptors.type() : 0;
}

bool ocv_feature_set_write(OCVFeatureSetRef ref, const char *filename,
                           const char **errorMsg) {
    if (!ref || ref->keypoints.empty() || ref->descriptors.empty()) {
        if (errorMsg) *errorMsg = "No features to write";
        return false;
    }

    try {
        cv::FileStorage storage(std::string(filename), cv::FileStorage::WRITE);
        if (!storage.isOpened()) {
            if (errorMsg) *errorMsg = "Failed to open file for writing";
            return false;
        }
        storage << "keypoints" << ref->keypoints;
        storage << "descriptors" << ref->descriptors;
        storage.release();
    } catch (...) {
        if (errorMsg) *errorMsg = "Exception writing feature file";
        return false;
    }
    return true;
}
