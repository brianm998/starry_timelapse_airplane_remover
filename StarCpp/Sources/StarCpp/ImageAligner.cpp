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
#include <thread>
#include <queue>
#include <mutex>
#include <condition_variable>

static MatWrapperRef wrap(const cv::Mat& mat) {
    return new MatWrapperImpl(mat);
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

template <typename T>
static inline T clamp_cast_int(int v) {
    if constexpr (std::is_same_v<T, uchar>) {
        return static_cast<uchar>(std::clamp(v, 0, 255));
    } else {
        return static_cast<uint16_t>(std::clamp(v, 0, 65535));
    }
}

template <typename T>
static void medianMergeTyped(cv::Mat &output, const std::vector<cv::Mat>& mats,
                             double k, bool includeAll, int rows, int cols, int ch) {
    const int n = (int)mats.size();
    std::vector<int> vals(n);

    for (int y = 0; y < rows; ++y) {
        std::vector<const T*> rowPtrs(n);
        for (int i = 0; i < n; ++i) rowPtrs[i] = mats[i].ptr<T>(y);
        T* outRow = output.ptr<T>(y);

        for (int x = 0; x < cols; ++x) {
            for (int c = 0; c < ch; ++c) {
                const int xc = x * ch + c;
                for (int i = 0; i < n; ++i) vals[i] = rowPtrs[i][xc];
                small_sort(vals.data(), n);

                double mean = 0.0, M2 = 0.0;
                for (int i = 0; i < n; ++i) {
                    double delta = vals[i] - mean;
                    mean += delta / (i + 1);
                    M2 += delta * (vals[i] - mean);
                }
                const double threshold = mean + k * std::sqrt(M2 / n);

                int minIndex = 0, maxIndex = n;
                if (!includeAll) {
                    for (int z = 0; z < n; ++z) {
                        if (vals[z] == 0) minIndex = z + 1;
                        if (vals[z] < threshold) maxIndex = z;
                        else break;
                    }
                }

                int idx = (minIndex + maxIndex) / 2;
                if (idx >= n) idx = n - 1;
                outRow[xc] = clamp_cast_int<T>(vals[idx]);
            }
        }
    }
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

static cv::Mat makeStarMask(const cv::Mat &gray, int dilateSize = 3, int thresholdVal = 200) {
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
            if (img) { mats.push_back(img->mat.clone()); mat_wrapper_release(img); }
        }
        return medianImageFromMats(mats, outlierThreshold, includeAll);
    } KHT_CATCH_LOG("ia_median_merge_filenames")
    return nullptr;
}

MatWrapperRef ia_median_merge_image_with_filenames(MatWrapperRef baseImage,
                                                    const char **filenames, int count,
                                                    double outlierThreshold, bool includeAll) {
    try {
        std::vector<cv::Mat> mats;
        if (baseImage) mats.push_back(baseImage->mat);
        for (int i = 0; i < count; i++) {
            MatWrapperRef img = image_cache_load(filenames[i]);
            if (img) { mats.push_back(img->mat.clone()); mat_wrapper_release(img); }
        }
        return medianImageFromMats(mats, outlierThreshold, includeAll);
    } KHT_CATCH_LOG("ia_median_merge_image_with_filenames")
    return nullptr;
}

MatWrapperRef ia_median_merge(MatWrapperRef *frames, int count,
                              double outlierThreshold, bool includeAll) {
    try {
        std::vector<cv::Mat> mats;
        for (int i = 0; i < count; i++) {
            if (frames[i]) mats.push_back(frames[i]->mat);
        }
        return medianImageFromMats(mats, outlierThreshold, includeAll);
    } KHT_CATCH_LOG("ia_median_merge")
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

OCVFeatureSetRef ia_find_features(MatWrapperRef baseImage, int frameIndex,
                                   FeatureMatchMethod matchMethod,
                                   MatWrapperRef mask,
                                   AlignmentType alignmentType,
                                   int maxKeypoints, bool writeDebugImages,
                                   int groundHorizonExtension,
                                   int baseImageDilateSize,
                                   int baseImageThresholdValue,
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
        }

        cv::Mat baseImageGray = toGray8UWithMask(baseImage->mat, horizonMask);

        cv::Mat detectionMask = horizonMask;
        if (alignmentType == AlignmentTypeSky) {
            detectionMask = makeStarMask(baseImageGray, baseImageDilateSize, baseImageDilateSize);
        }

        std::vector<cv::KeyPoint> keypoints;
        cv::Mat descriptors;

        if (alignmentType == AlignmentTypeEarth) {
            cv::Ptr<cv::CLAHE> clahe = cv::createCLAHE(4.0, cv::Size(8,8));
            cv::Mat baseImageProcessed;
            clahe->apply(baseImageGray, baseImageProcessed);
            baseImageProcessed.convertTo(baseImageProcessed, CV_32F, 1.0/255.0);
            cv::pow(baseImageProcessed, 0.5, baseImageProcessed);
            baseImageProcessed.convertTo(baseImageProcessed, CV_8U, 255.0);
            cv::Ptr<cv::AKAZE> akazeBase = cv::AKAZE::create();
            akazeBase->setThreshold(1e-5);
            akazeBase->detectAndCompute(baseImageProcessed, detectionMask, keypoints, descriptors);
        } else {
            cv::Ptr<cv::SIFT> siftBase = cv::SIFT::create(maxKeypoints);
            siftBase->detectAndCompute(baseImageGray, detectionMask, keypoints, descriptors);
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
                cv::BFMatcher matcher(cv::NORM_L2);

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
                    cv::Mat dn32, db32;
                    descNeighbor.convertTo(dn32, CV_32F);
                    descBase.convertTo(db32, CV_32F);
                    cv::FlannBasedMatcher flann;
                    flann.knnMatch(dn32, db32, knnMatches, 2);
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

int ia_align_with_homography(int baseFrameIndex,
                             const AlignmentNeighborData *neighbors, int neighborCount,
                             const int *homographyKeys,
                             MatWrapperRef *homographyValues, int homographyCount,
                             WarpedImageResultData *outResults,
                             const char **errorMsg) {
    if (!neighbors || !outResults) return 0;
    try {
        int resultCount = 0;
        for (int i = 0; i < neighborCount; ++i) {
            MatWrapperRef neighbor = image_cache_load(neighbors[i].filename);
            if (!neighbor) continue;

            int offset = neighbors[i].frameIndex - baseFrameIndex;

            // Find matching homography
            MatWrapperRef H = nullptr;
            for (int j = 0; j < homographyCount; j++) {
                if (homographyKeys[j] == offset) { H = homographyValues[j]; break; }
            }
            if (!H) { mat_wrapper_release(neighbor); continue; }

            cv::Mat warped;
            cv::warpPerspective(neighbor->mat, warped, H->mat, neighbor->mat.size(),
                                cv::INTER_LINEAR, cv::BORDER_CONSTANT, cv::Scalar(0,0,0,0));

            outResults[resultCount].warpedFrame = wrap(warped);
            outResults[resultCount].warpedHorizon = nullptr;

            if (neighbors[i].maskFilename) {
                MatWrapperRef maskImg = image_cache_load(neighbors[i].maskFilename);
                if (maskImg) {
                    cv::Mat warpedMask;
                    cv::warpPerspective(maskImg->mat, warpedMask, H->mat, maskImg->mat.size(),
                                        cv::INTER_LINEAR, cv::BORDER_CONSTANT, cv::Scalar(0,0,0,0));
                    outResults[resultCount].warpedHorizon = wrap(warpedMask);
                    mat_wrapper_release(maskImg);
                }
            }

            mat_wrapper_release(neighbor);
            resultCount++;
        }
        return resultCount;
    } catch (const cv::Exception &e) {
        if (errorMsg) *errorMsg = "OpenCV exception in align";
        Log_e("Error: %s", e.what());
    } catch (...) {
        if (errorMsg) *errorMsg = "Unknown exception";
    }
    return 0;
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
