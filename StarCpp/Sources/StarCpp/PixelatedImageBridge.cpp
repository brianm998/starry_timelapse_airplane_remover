// PixelatedImageBridge.cpp — Pure C++ implementation of image processing operations
#include "PixelatedImageBridge.h"
#include "MatWrapper.h"
#include "MatWrapperImpl.hpp"
#include "logging_impl.hpp"

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/imgcodecs.hpp>

#include <set>
#include <algorithm>
#include <vector>
#include <limits>
#include <cmath>


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

// Shares the buffer of a freshly produced cv::Mat the caller is about to drop.
// Never pass a live wrapper's mat here — use the deep constructor for that.
static MatWrapperRef wrap(const cv::Mat& mat) {
    return new MatWrapperImpl(MatWrapperImpl::Adopt{}, mat);
}

// --- Implementation ---

MatWrapperRef pib_combine_image(MatWrapperRef image1, MatWrapperRef mask,
                                MatWrapperRef image2) {
    if (!image1 || !mask || !image2) return nullptr;
    try {
        cv::Mat mat1 = image1->mat;
        cv::Mat mat2 = image2->mat;
        cv::Mat matMask = mask->mat;

        // Ensure single channel
        if (matMask.channels() > 1) {
          cv::cvtColor(matMask, matMask, cv::COLOR_BGR2GRAY);
        }

        // Ensure 8-bit
        if (matMask.type() != CV_8U) {
          double minVal, maxVal;
          cv::minMaxLoc(matMask, &minVal, &maxVal);

          if (maxVal > 0) {
            matMask.convertTo(matMask, CV_8U, 255.0 / maxVal);
          } else {
            matMask = cv::Mat::zeros(matMask.size(), CV_8U);
          }
        }

        if (mat1.size() != mat2.size() || mat1.size() != matMask.size()) {
            Log_e("combineWithMask: Input Mats must have the same size.");
            return nullptr;
        }

        cv::Mat result;
        result.create(mat1.size(), mat1.type());

        cv::Mat matMaskThreshold;
        cv::threshold(matMask, matMaskThreshold, 128, 255, cv::THRESH_BINARY);

        // Only convert when there is actually an alpha channel to drop.  On 3-channel
        // input — which is what this pipeline produces — cvtColor(BGRA2BGR) accepts
        // scn==3 and just copies, so these were two full-frame copies that changed
        // nothing: ~482MB per call at 42MP.  Sharing instead of copying is safe here
        // because both are only ever read, as copyTo sources.
        //
        // Note the 4-channel branch was already broken and is left as it was: `result`
        // is created with mat1.type() above, so for 4-channel input it has 4 channels
        // while these have 3, and copyTo would throw on the mismatch.
        cv::Mat mat1_3, mat2_3;
        if (mat1.channels() == 3) mat1_3 = mat1;
        else cv::cvtColor(mat1, mat1_3, cv::COLOR_BGRA2BGR);
        if (mat2.channels() == 3) mat2_3 = mat2;
        else cv::cvtColor(mat2, mat2_3, cv::COLOR_BGRA2BGR);

        mat1_3.copyTo(result, matMaskThreshold);
        cv::bitwise_not(matMaskThreshold, matMaskThreshold);
        mat2_3.copyTo(result, matMaskThreshold);

        return wrap(result);
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception: %s", e.what());
    }
    return nullptr;
}

MatWrapperRef pib_filter_connected_components(MatWrapperRef image, int64_t n) {
    if (!image) return nullptr;
    try {
        cv::Mat owned = image->mat;
        if (owned.channels() > 1) {
            owned = image->mat.clone();
            cv::cvtColor(owned, owned, cv::COLOR_BGR2GRAY);
        }

        cv::Mat labels, stats, centroids;
        int nLabels = cv::connectedComponentsWithStats(owned, labels, stats, centroids, 8, CV_32S);

        std::vector<std::pair<int,int>> areas;
        for (int i = 1; i < nLabels; i++) {
            int area = stats.at<int>(i, cv::CC_STAT_AREA);
            areas.emplace_back(area, i);
        }
        std::sort(areas.begin(), areas.end(), std::greater<>());

        std::set<int> keep;
        for (int i = 0; i < std::min<int>((int)n, (int)areas.size()); i++) {
            keep.insert(areas[i].second);
        }

        cv::Mat filtered = cv::Mat::zeros(owned.size(), CV_8UC1);
        for (int y = 0; y < labels.rows; y++)
            for (int x = 0; x < labels.cols; x++)
                if (keep.count(labels.at<int>(y, x)))
                    filtered.at<uchar>(y, x) = 255;

        return wrap(filtered);
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception: %s", e.what());
    }
    return nullptr;
}

// Both of the functions below threshold at 127 and then hand the result to
// cv::connectedComponentsWithStats, which requires CV_8UC1 — it throws on anything else.  Neither
// used to convert the depth, so a 16 bit mask (what a reference horizon loaded straight off a tiff
// is) made them throw, get caught below, and return nullptr.
//
// In production this was latent: both callers pass a HorizonMask's image, which asHorizonMask has
// already normalised to 8 bit, and both wrap the call in `(try? ...) ?? original` anyway.  It still
// meant these could not be used on the project's own reference masks, which are 16 bit.
static cv::Mat pib_as_eight_bit_gray(const cv::Mat &input) {
    if (input.depth() == CV_8U) return input;

    cv::Mat converted;
    switch (input.depth()) {
        case CV_16U: input.convertTo(converted, CV_8U, 255.0 / 65535.0); break;
        case CV_32F:
        case CV_64F: input.convertTo(converted, CV_8U, 255.0); break;
        default:     input.convertTo(converted, CV_8U); break;
    }
    return converted;
}

MatWrapperRef pib_ground_only(MatWrapperRef image) {
    if (!image) return nullptr;
    try {
        cv::Mat owned = image->mat;
        if (owned.channels() > 1) {
            owned = image->mat.clone();
            cv::cvtColor(owned, owned, cv::COLOR_BGR2GRAY);
        }
        owned = pib_as_eight_bit_gray(owned);

        cv::Mat bin;
        cv::threshold(owned, bin, 127, 255, cv::THRESH_BINARY);
        cv::Mat inv;
        cv::bitwise_not(bin, inv);

        cv::Mat labels, stats, centroids;
        cv::connectedComponentsWithStats(inv, labels, stats, centroids, 8, CV_32S);

        std::set<int> bottomLabels;
        int bottomY = inv.rows - 1;
        for (int x = 0; x < labels.cols; x++) {
            int lbl = labels.at<int>(bottomY, x);
            if (lbl > 0) bottomLabels.insert(lbl);
        }

        cv::Mat groundMask = cv::Mat::zeros(inv.size(), CV_8UC1);
        for (int y = 0; y < labels.rows; y++)
            for (int x = 0; x < labels.cols; x++)
                if (bottomLabels.count(labels.at<int>(y, x)))
                    groundMask.at<uchar>(y, x) = 255;

        cv::Mat finalMask;
        cv::bitwise_not(groundMask, finalMask);
        return wrap(finalMask);
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception: %s", e.what());
    }
    return nullptr;
}

MatWrapperRef pib_sky_only(MatWrapperRef image) {
    if (!image) return nullptr;
    try {
        cv::Mat owned = image->mat;
        if (owned.channels() > 1) {
            owned = image->mat.clone();
            cv::cvtColor(owned, owned, cv::COLOR_BGR2GRAY);
        }
        owned = pib_as_eight_bit_gray(owned);

        cv::Mat bin;
        cv::threshold(owned, bin, 127, 255, cv::THRESH_BINARY);

        cv::Mat labels, stats, centroids;
        cv::connectedComponentsWithStats(bin, labels, stats, centroids, 8, CV_32S);

        std::set<int> topLabels;
        for (int x = 0; x < labels.cols; x++) {
            int lbl = labels.at<int>(0, x);
            if (lbl > 0) topLabels.insert(lbl);
        }

        cv::Mat skyMask = cv::Mat::zeros(bin.size(), CV_8UC1);
        for (int y = 0; y < labels.rows; y++)
            for (int x = 0; x < labels.cols; x++)
                if (topLabels.count(labels.at<int>(y, x)))
                    skyMask.at<uchar>(y, x) = 255;

        return wrap(skyMask);
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception: %s", e.what());
    }
    return nullptr;
}

HorizonResultData pib_horizon_extents(MatWrapperRef image) {
    HorizonResultData result = {-1, -1};
    if (!image) return result;
    try {
        cv::Mat mat = image->mat;
        if (mat.empty()) return result;

        cv::Mat gray;
        if (mat.channels() == 3) cv::cvtColor(mat, gray, cv::COLOR_BGR2GRAY);
        else if (mat.channels() == 4) cv::cvtColor(mat, gray, cv::COLOR_BGRA2GRAY);
        else if (mat.channels() == 1) gray = mat;
        else return result;

        cv::Mat binary;
        cv::threshold(gray, binary, 128, 255, cv::THRESH_BINARY);

        for (int y = 0; y < binary.rows; y++) {
            if (cv::countNonZero(binary.row(y) == 0) > 0) {
                result.horizonTopY = y;
                break;
            }
        }
        for (int y = binary.rows - 1; y >= 0; y--) {
            if (cv::countNonZero(binary.row(y) == 255) > 0) {
                result.horizonBottomY = y;
                break;
            }
        }
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception: %s", e.what());
    }
    return result;
}

MatWrapperRef pib_canny_edge_detect(MatWrapperRef img, double minThreshold,
                                    double maxThreshold, bool useL2Gradient) {
    if (!img) return nullptr;
    try {
        cv::Mat input = img->mat;
        cv::Mat gray;
        if (input.channels() == 3) cv::cvtColor(input, gray, cv::COLOR_BGR2GRAY);
        else gray = input.clone();
        gray = ensure8U(gray);
        cv::Mat edges;
        cv::Canny(gray, edges, minThreshold, maxThreshold, 3, useL2Gradient);
        return wrap(edges);
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception: %s", e.what());
    }
    return nullptr;
}

MatWrapperRef pib_shift_image_up(MatWrapperRef input, int shiftPixels) {
    if (!input || shiftPixels <= 0) return input ? new MatWrapperImpl(input->mat) : nullptr;
    try {
        cv::Mat src = input->mat;
        int shift = std::min(shiftPixels, src.rows);
        cv::Mat dst(src.size(), src.type());
        src.rowRange(shift, src.rows).copyTo(dst.rowRange(0, src.rows - shift));
        cv::Mat lastRow = src.row(src.rows - 1);
        for (int r = src.rows - shift; r < src.rows; r++)
            lastRow.copyTo(dst.row(r));
        return wrap(dst);
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception: %s", e.what());
    }
    return nullptr;
}

MatWrapperRef pib_bitwise_and(MatWrapperRef img, MatWrapperRef img1) {
    if (!img || !img1) return nullptr;
    try {
        cv::Mat gray, gray1;
        if (img->mat.channels() == 3) cv::cvtColor(img->mat, gray, cv::COLOR_BGR2GRAY);
        else gray = img->mat;
        if (img1->mat.channels() == 3) cv::cvtColor(img1->mat, gray1, cv::COLOR_BGR2GRAY);
        else gray1 = img1->mat;
        cv::Mat output;
        cv::bitwise_and(gray, gray1, output);
        return wrap(output);
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception: %s", e.what());
    }
    return nullptr;
}

MatWrapperRef pib_bitwise_or(MatWrapperRef img, MatWrapperRef img1) {
    if (!img || !img1) return nullptr;
    try {
        cv::Mat gray, gray1;
        if (img->mat.channels() == 3) cv::cvtColor(img->mat, gray, cv::COLOR_BGR2GRAY);
        else gray = img->mat;
        if (img1->mat.channels() == 3) cv::cvtColor(img1->mat, gray1, cv::COLOR_BGR2GRAY);
        else gray1 = img1->mat;
        cv::Mat output;
        cv::bitwise_or(gray, gray1, output);
        return wrap(output);
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception: %s", e.what());
    }
    return nullptr;
}

MatWrapperRef pib_bitwise_not(MatWrapperRef img) {
    if (!img) return nullptr;
    try {
        cv::Mat gray;
        if (img->mat.channels() == 3) cv::cvtColor(img->mat, gray, cv::COLOR_BGR2GRAY);
        else gray = img->mat;
        cv::Mat output;
        cv::bitwise_not(gray, output);
        return wrap(output);
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception: %s", e.what());
    }
    return nullptr;
}

MatWrapperRef pib_detect_horizon(MatWrapperRef img) {
    if (!img) return nullptr;
    try {
        cv::Mat input = img->mat;
        cv::Mat gray;
        if (input.channels() == 3) cv::cvtColor(input, gray, cv::COLOR_BGR2GRAY);
        else gray = input.clone();
        gray = ensure8U(gray);
        cv::Mat edges;
        cv::Canny(gray, edges, 30, 150);
        return wrap(edges);
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception: %s", e.what());
    }
    return nullptr;
}

MatWrapperRef pib_subtract_image(MatWrapperRef img2, MatWrapperRef img1) {
    if (!img1 || !img2) return nullptr;
    try {
        cv::Mat gray1, gray2;
        if (img1->mat.channels() == 1) gray1 = img1->mat.clone();
        else cv::cvtColor(img1->mat, gray1, cv::COLOR_BGR2GRAY);
        if (img2->mat.channels() == 1) gray2 = img2->mat.clone();
        else cv::cvtColor(img2->mat, gray2, cv::COLOR_BGR2GRAY);

        int targetDepth = std::max(gray1.depth(), gray2.depth());
        int cvTargetType;
        switch (targetDepth) {
            case CV_8U:  cvTargetType = CV_8U; break;
            case CV_16U: cvTargetType = CV_16U; break;
            case CV_16S: cvTargetType = CV_16S; break;
            case CV_32S: cvTargetType = CV_32S; break;
            case CV_32F: cvTargetType = CV_32F; break;
            case CV_64F: cvTargetType = CV_64F; break;
            default:     cvTargetType = CV_32F; break;
        }

        cv::Mat gray1f, gray2f;
        gray1.convertTo(gray1f, cvTargetType);
        gray2.convertTo(gray2f, cvTargetType);
        cv::Mat diff;
        cv::subtract(gray1f, gray2f, diff);
        cv::Mat diffClipped;
        cv::max(diff, 0, diffClipped);
        return wrap(diffClipped);
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception: %s", e.what());
    }
    return nullptr;
}

MatWrapperRef pib_shrink_dark_regions(MatWrapperRef img, int radius) {
    if (!img) return nullptr;
    try {
        cv::Mat binaryImage = img->mat;
        int kernelSize = 2 * radius + 1;
        cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(kernelSize, kernelSize));
        cv::Mat inverted, result;
        cv::bitwise_not(binaryImage, inverted);
        cv::erode(inverted, inverted, kernel);
        cv::bitwise_not(inverted, result);
        return wrap(result);
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception: %s", e.what());
    }
    return nullptr;
}

MatWrapperRef pib_grow_dark_regions(MatWrapperRef img, int radius) {
    if (!img) return nullptr;
    try {
        cv::Mat binaryImage = img->mat;
        int kernelSize = 2 * radius + 1;
        cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(kernelSize, kernelSize));
        cv::Mat inverted, result;
        cv::bitwise_not(binaryImage, inverted);
        cv::dilate(inverted, inverted, kernel);
        cv::bitwise_not(inverted, result);
        return wrap(result);
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception: %s", e.what());
    }
    return nullptr;
}

double pib_max_brightness_scale(MatWrapperRef image, MatWrapperRef mask) {
    if (!image || !mask) return 1.0;
    try {
        cv::Mat owned = image->mat;
        cv::Mat ownedMask = mask->mat;

        if (ownedMask.channels() > 1) {
            ownedMask = mask->mat.clone();
            cv::cvtColor(ownedMask, ownedMask, cv::COLOR_BGR2GRAY);
        }

        cv::Mat groundMask;
        cv::bitwise_not(ownedMask, groundMask);

        std::vector<cv::Mat> chans;
        cv::split(owned, chans);
        double maxValOverall = 0.0;
        for (auto &ch : chans) {
            double minVal, maxVal;
            cv::minMaxLoc(ch, &minVal, &maxVal, nullptr, nullptr, groundMask);
            maxValOverall = std::max(maxValOverall, maxVal);
        }

        if (maxValOverall <= 0.0) return 1.0;

        double maxAllowed = 255.0;
        switch (owned.depth()) {
            case CV_8U:  maxAllowed = 255.0; break;
            case CV_16U: maxAllowed = 65535.0; break;
            case CV_32F: maxAllowed = 1.0; break;
            default:     maxAllowed = 255.0; break;
        }
        return maxAllowed / maxValOverall;
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception: %s", e.what());
    }
    return 1.0;
}

MatWrapperRef pib_brighten_darks(MatWrapperRef image, MatWrapperRef mask, double amount) {
    if (!image || !mask) return nullptr;
    try {
        cv::Mat owned = image->mat;
        cv::Mat ownedMask = mask->mat;
        if (owned.empty() || ownedMask.empty()) return mat_wrapper_clone(image);

        cv::Mat maskGray;
        if (ownedMask.channels() > 1) cv::cvtColor(ownedMask, maskGray, cv::COLOR_BGR2GRAY);
        else maskGray = ownedMask;

        cv::Mat binMask;
        cv::threshold(maskGray, binMask, 128, 255, cv::THRESH_BINARY);

        double factor = std::max(0.0001, 1.0 + amount);
        cv::Mat result = owned.clone();
        for (int y = 0; y < owned.rows; y++) {
            const uint16_t* src = owned.ptr<uint16_t>(y);
            uint16_t* dst = result.ptr<uint16_t>(y);
            const uchar* m = binMask.ptr<uchar>(y);
            for (int x = 0; x < owned.cols * owned.channels(); x++) {
                if (m[x / owned.channels()] == 255)
                    dst[x] = cv::saturate_cast<uint16_t>(src[x] / factor);
            }
        }
        return wrap(result);
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception: %s", e.what());
    }
    return nullptr;
}

MatWrapperRef pib_darken_darks(MatWrapperRef image, MatWrapperRef mask, double amount) {
    if (!image || !mask) return nullptr;
    try {
        cv::Mat owned = image->mat;
        cv::Mat ownedMask = mask->mat;
        if (owned.empty() || ownedMask.empty()) return mat_wrapper_clone(image);

        cv::Mat maskGray;
        if (ownedMask.channels() > 1) cv::cvtColor(ownedMask, maskGray, cv::COLOR_BGR2GRAY);
        else maskGray = ownedMask;

        cv::Mat binMask;
        cv::threshold(maskGray, binMask, 128, 255, cv::THRESH_BINARY);

        double factor = std::max(0.0, 1.0 + amount);
        cv::Mat result = owned.clone();
        for (int y = 0; y < owned.rows; y++) {
            const uint16_t* src = owned.ptr<uint16_t>(y);
            uint16_t* dst = result.ptr<uint16_t>(y);
            const uchar* m = binMask.ptr<uchar>(y);
            for (int x = 0; x < owned.cols * owned.channels(); x++) {
                if (m[x / owned.channels()] == 255)
                    dst[x] = cv::saturate_cast<uint16_t>(src[x] * factor);
            }
        }
        return wrap(result);
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception: %s", e.what());
    }
    return nullptr;
}

MatWrapperRef pib_mask_raised_by(MatWrapperRef image, MatWrapperRef mask, int borderAmount) {
    if (!image || !mask) return nullptr;
    try {
        cv::Mat owned = image->mat;
        cv::Mat ownedMask = mask->mat;

        const int h = owned.rows;
        cv::Mat keepMask = (ownedMask == 0);
        cv::Mat dilatedMask = cv::Mat::zeros(keepMask.size(), keepMask.type());
        int shift = std::min(borderAmount, keepMask.rows);
        keepMask.rowRange(shift, keepMask.rows).copyTo(dilatedMask.rowRange(0, keepMask.rows - shift));
        keepMask.rowRange(keepMask.rows - shift, keepMask.rows).copyTo(dilatedMask.rowRange(keepMask.rows - shift, keepMask.rows));

        cv::Mat masked = owned.clone();
        cv::Scalar whiteScalar;
        switch (owned.depth()) {
            case CV_8U:  whiteScalar = cv::Scalar(255); break;
            case CV_16U: whiteScalar = cv::Scalar(65535); break;
            case CV_32S: whiteScalar = cv::Scalar(std::numeric_limits<int>::max()); break;
            default: return nullptr;
        }
        if (owned.channels() > 1) whiteScalar = cv::Scalar::all(whiteScalar[0]);
        masked.setTo(whiteScalar, dilatedMask == 0);

        if (borderAmount > 0) {
            int bottomRows = std::min(borderAmount, h);
            owned.rowRange(h - bottomRows, h).copyTo(masked.rowRange(h - bottomRows, h));
        }
        return wrap(masked);
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception: %s", e.what());
    }
    return nullptr;
}

MatWrapperRef pib_warp_image(MatWrapperRef image, MatWrapperRef homography) {
    if (!image || !homography) return nullptr;
    try {
        cv::Mat warped;
        cv::warpPerspective(image->mat, warped, homography->mat, image->mat.size(),
                            cv::INTER_LINEAR, cv::BORDER_CONSTANT, cv::Scalar(0,0,0,0));
        return wrap(warped);
    } catch (const cv::Exception &e) {
        Log_e("warpImage: cv exception: %s", e.what());
    }
    return nullptr;
}

MatWrapperRef pib_abs_diff_grayscale(MatWrapperRef image1, MatWrapperRef image2) {
    if (!image1 || !image2) return nullptr;
    try {
        cv::Mat gray1, gray2;
        cv::Mat src1 = ensure8U(image1->mat);
        cv::Mat src2 = ensure8U(image2->mat);
        auto toGray = [](const cv::Mat& src, cv::Mat& out) -> bool {
            if (src.channels() == 1) { out = src; return true; }
            if (src.channels() == 4) { cv::cvtColor(src, out, cv::COLOR_BGRA2GRAY); return true; }
            if (src.channels() == 3) { cv::cvtColor(src, out, cv::COLOR_BGR2GRAY); return true; }
            return false;
        };
        if (!toGray(src1, gray1) || !toGray(src2, gray2)) return nullptr;
        cv::Mat diff;
        cv::absdiff(gray1, gray2, diff);
        return wrap(diff);
    } catch (const cv::Exception &e) {
        Log_e("absDiffGrayscale: cv exception: %s", e.what());
    }
    return nullptr;
}

MatWrapperRef pib_mean_of_images(MatWrapperRef *images, int count) {
    if (!images || count <= 0) return nullptr;
    try {
        const cv::Mat& first = images[0]->mat;
        cv::Mat accum = cv::Mat::zeros(first.size(), CV_32F);
        for (int i = 0; i < count; i++) {
            cv::Mat f;
            images[i]->mat.convertTo(f, CV_32F);
            accum += f;
        }
        accum /= (float)count;
        cv::Mat result;
        accum.convertTo(result, CV_8U);
        return wrap(result);
    } catch (const cv::Exception &e) {
        Log_e("meanOfImages: cv exception: %s", e.what());
    }
    return nullptr;
}

MatWrapperRef pib_warp_horizon_mask(MatWrapperRef mask, MatWrapperRef homography) {
    if (!mask || !homography) return nullptr;
    try {
        cv::Mat warped;
        cv::warpPerspective(mask->mat, warped, homography->mat, mask->mat.size(),
                            cv::INTER_NEAREST, cv::BORDER_CONSTANT,
                            cv::Scalar(255, 255, 255, 255));
        return wrap(warped);
    } catch (const cv::Exception &e) {
        Log_e("warpHorizonMask: cv exception: %s", e.what());
    }
    return nullptr;
}

bool pib_sky_shift(MatWrapperRef a, MatWrapperRef b,
                   int x, int y, int w, int h,
                   double *dx, double *dy, double *response) {
    if (!a || !b || !dx || !dy || w < 64 || h < 64) return false;
    try {
        const cv::Mat &ma = a->mat, &mb = b->mat;
        if (ma.size() != mb.size()) return false;
        if (x < 0 || y < 0 || x + w > ma.cols || y + h > ma.rows) return false;
        const cv::Rect crop(x, y, w, h);

        // Grayscale float crops.  The high-pass below is what makes this work at
        // dusk: subtracting a heavily blurred copy removes the sky gradient and the
        // clouds, whose motion is not the sky's, and leaves the stars — measured on
        // a dusk sequence this way, the correlation locks onto the sidereal drift
        // even when the frame is dominated by sunlit cloud.  The blur must run at
        // full resolution: an earlier version blurred a 1/8-scale copy and resized
        // it back, and the resampling staircase it subtracted in was static content
        // — measured pulling the correlation toward zero shift and, on one dusk
        // gap, reading a 1.5-step interval as 1.9.
        auto prep = [&](const cv::Mat &src) {
            cv::Mat gray = src(crop);
            if (gray.channels() > 1) cv::cvtColor(gray, gray, cv::COLOR_BGR2GRAY);
            cv::Mat f;
            gray.convertTo(f, CV_32F);
            cv::Mat blurred;
            cv::GaussianBlur(f, blurred, cv::Size(0, 0), 81.0);
            return cv::Mat(f - blurred);
        };
        cv::Mat fa = prep(ma), fb = prep(mb);

        cv::Mat window;
        cv::createHanningWindow(window, fa.size(), CV_32F);
        double resp = 0;
        // phaseCorrelate(fa, fb) reports where fb's content sits relative to fa's —
        // measured: dots moved by (+3, +5) between the two read back as (+3, +5) —
        // which is exactly the "b sits this far from a" the caller wants.
        cv::Point2d shift = cv::phaseCorrelate(fa, fb, window, &resp);
        *dx = shift.x;
        *dy = shift.y;
        if (response) *response = resp;
        return true;
    } catch (const cv::Exception &e) {
        Log_e("pib_sky_shift: cv exception: %s", e.what());
    }
    return false;
}

MatWrapperRef pib_binary_horizon_mask(int width, int height, const int *horizonY) {
    try {
        cv::Mat mask(height, width, CV_8UC1, cv::Scalar(255));
        for (int x = 0; x < width; x++) {
            int y = horizonY[x];
            if (y < 0) continue; // -1 means all sky
            if (y > height) y = height;
            for (int row = y; row < height; row++)
                mask.at<uchar>(row, x) = 0;
        }
        return wrap(mask);
    } KHT_CATCH_LOG("pib_binary_horizon_mask")
    return nullptr;
}

MatWrapperRef pib_dp_horizon_mask(MatWrapperRef img,
                                  double cannyMin, double cannyMax,
                                  bool useL2Gradient,
                                  double smoothnessLambda,
                                  double sobelWeight, double cannyWeight,
                                  double searchTopFraction,
                                  double searchBottomFraction) {
    if (!img) return nullptr;
    try {
        cv::Mat input = img->mat;
        cv::Mat gray;
        if (input.channels() == 4) cv::cvtColor(input, gray, cv::COLOR_BGRA2GRAY);
        else if (input.channels() == 3) cv::cvtColor(input, gray, cv::COLOR_BGR2GRAY);
        else gray = input.clone();
        gray = ensure8U(gray);

        int rows = gray.rows, cols = gray.cols;
        if (rows < 2 || cols < 2) return nullptr;

        int searchTop = std::max(0, (int)(rows * searchTopFraction));
        int searchBottom = std::min(rows - 1, (int)(rows * searchBottomFraction));
        int bandHeight = searchBottom - searchTop + 1;
        if (bandHeight < 2) return nullptr;

        // Sobel vertical gradient
        cv::Mat sobelY, absSobelY, sobelNorm;
        cv::Sobel(gray, sobelY, CV_32F, 0, 1, 3);
        cv::convertScaleAbs(sobelY, absSobelY);
        absSobelY.convertTo(sobelNorm, CV_32F, 1.0 / 255.0);

        // Canny edges
        cv::Mat edges, cannyNorm;
        cv::Canny(gray, edges, cannyMin, cannyMax, 3, useL2Gradient);
        edges.convertTo(cannyNorm, CV_32F, 1.0 / 255.0);

        // Cost image
        double baseCost = 1.0;
        cv::Mat costImage(rows, cols, CV_32F);
        for (int y = 0; y < rows; y++) {
            float *costRow = costImage.ptr<float>(y);
            const float *sobelRow = sobelNorm.ptr<float>(y);
            const float *cannyRow = cannyNorm.ptr<float>(y);
            for (int x = 0; x < cols; x++) {
                double cost = baseCost - sobelWeight * sobelRow[x] - cannyWeight * cannyRow[x];
                costRow[x] = (float)std::max(0.01, cost);
            }
        }
        for (int y = 0; y < rows; y++) {
            if (y < searchTop || y > searchBottom) {
                float *costRow = costImage.ptr<float>(y);
                for (int x = 0; x < cols; x++) costRow[x] = 100.0f;
            }
        }

        // DP
        std::vector<float> dpPrev(bandHeight, 0), dpCurr(bandHeight, 0);
        std::vector<std::vector<int>> backtrack(cols, std::vector<int>(bandHeight, 0));
        for (int by = 0; by < bandHeight; by++) {
            dpPrev[by] = costImage.at<float>(searchTop + by, 0);
            backtrack[0][by] = by;
        }

        std::vector<float> bestFromAbove(bandHeight), bestFromBelow(bandHeight);
        std::vector<int> bestIdxFromAbove(bandHeight), bestIdxFromBelow(bandHeight);
        float lambda = (float)smoothnessLambda;

        for (int x = 1; x < cols; x++) {
            bestFromAbove[0] = dpPrev[0]; bestIdxFromAbove[0] = 0;
            for (int by = 1; by < bandHeight; by++) {
                float candidate = dpPrev[by];
                float propagated = bestFromAbove[by-1] + lambda;
                if (candidate <= propagated) { bestFromAbove[by] = candidate; bestIdxFromAbove[by] = by; }
                else { bestFromAbove[by] = propagated; bestIdxFromAbove[by] = bestIdxFromAbove[by-1]; }
            }
            bestFromBelow[bandHeight-1] = dpPrev[bandHeight-1]; bestIdxFromBelow[bandHeight-1] = bandHeight-1;
            for (int by = bandHeight - 2; by >= 0; by--) {
                float candidate = dpPrev[by];
                float propagated = bestFromBelow[by+1] + lambda;
                if (candidate <= propagated) { bestFromBelow[by] = candidate; bestIdxFromBelow[by] = by; }
                else { bestFromBelow[by] = propagated; bestIdxFromBelow[by] = bestIdxFromBelow[by+1]; }
            }
            for (int by = 0; by < bandHeight; by++) {
                float localCost = costImage.at<float>(searchTop + by, x);
                if (bestFromAbove[by] <= bestFromBelow[by]) {
                    dpCurr[by] = localCost + bestFromAbove[by]; backtrack[x][by] = bestIdxFromAbove[by];
                } else {
                    dpCurr[by] = localCost + bestFromBelow[by]; backtrack[x][by] = bestIdxFromBelow[by];
                }
            }
            std::swap(dpPrev, dpCurr);
        }

        // Backtrace
        std::vector<int> horizonPath(cols);
        int bestEndY = 0; float bestEndCost = dpPrev[0];
        for (int by = 1; by < bandHeight; by++)
            if (dpPrev[by] < bestEndCost) { bestEndCost = dpPrev[by]; bestEndY = by; }
        horizonPath[cols-1] = searchTop + bestEndY;
        int currentBy = bestEndY;
        for (int x = cols - 2; x >= 0; x--) {
            currentBy = backtrack[x+1][currentBy];
            horizonPath[x] = searchTop + currentBy;
        }

        // Generate mask
        cv::Mat mask = cv::Mat::zeros(rows, cols, CV_8UC1);
        for (int x = 0; x < cols; x++)
            for (int y = 0; y < horizonPath[x]; y++)
                mask.at<uchar>(y, x) = 255;

        return wrap(mask);
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception in dpHorizonMask: %s", e.what());
    }
    return nullptr;
}

void pib_grabcut_horizon(MatWrapperRef img,
                         const int *initHorizonY,
                         int width,
                         int iterations,
                         int maxWorkingWidth,
                         int *outHorizonY) {
    if (!img || !initHorizonY || !outHorizonY) return;
    for (int i = 0; i < width; i++) outHorizonY[i] = -1;

    try {
        cv::Mat input = img->mat;
        int rows = input.rows, cols = input.cols;
        if (rows < 2 || cols < 2) return;

        // Downscale if needed
        double scale = 1.0;
        cv::Mat working;
        if (cols > maxWorkingWidth) {
            scale = (double)maxWorkingWidth / cols;
            int newW = maxWorkingWidth;
            int newH = std::max(2, (int)(rows * scale));
            cv::resize(input, working, cv::Size(newW, newH), 0, 0, cv::INTER_AREA);
        } else {
            working = input;
        }
        int wRows = working.rows, wCols = working.cols;

        // Convert to 8-bit BGR (GrabCut requires CV_8UC3)
        cv::Mat bgr8;
        if (working.channels() == 4) {
            cv::cvtColor(working, bgr8, cv::COLOR_BGRA2BGR);
        } else if (working.channels() == 1) {
            cv::cvtColor(working, bgr8, cv::COLOR_GRAY2BGR);
        } else {
            bgr8 = working;
        }
        if (bgr8.depth() != CV_8U) {
            cv::Mat tmp;
            bgr8.convertTo(tmp, CV_8U, 255.0 / (bgr8.depth() == CV_16U ? 65535.0 : 1.0));
            bgr8 = tmp;
        }

        // Build initial mask from horizon estimate.
        // Above horizon = probable foreground (sky), below = probable background (ground).
        // GrabCut convention: GC_PR_FGD = probable foreground, GC_PR_BGD = probable background
        // We mark definite sky/ground at the edges for stability.
        cv::Mat gcMask(wRows, wCols, CV_8UC1, cv::Scalar(cv::GC_PR_BGD));

        int validCount = 0;
        long sumY = 0;
        for (int x = 0; x < cols; x++) {
            if (initHorizonY[x] >= 0) { sumY += initHorizonY[x]; validCount++; }
        }
        if (validCount == 0) return;
        int avgHorizonY = (int)((double)sumY / validCount * scale);

        // Seed margin: top 10% of above-horizon = definite sky, bottom 10% below = definite ground
        int definiteMargin = std::max(5, wRows / 20);

        for (int x = 0; x < wCols; x++) {
            int srcX = (int)(x / scale);
            srcX = std::min(std::max(srcX, 0), cols - 1);
            int hy = initHorizonY[srcX];
            int wHy = (hy >= 0) ? (int)(hy * scale) : avgHorizonY;
            wHy = std::min(std::max(wHy, 0), wRows - 1);

            for (int y = 0; y < wRows; y++) {
                if (y < wHy) {
                    gcMask.at<uchar>(y, x) = (y < definiteMargin) ?
                        (uchar)cv::GC_FGD : (uchar)cv::GC_PR_FGD;
                } else {
                    gcMask.at<uchar>(y, x) = (y > wRows - definiteMargin) ?
                        (uchar)cv::GC_BGD : (uchar)cv::GC_PR_BGD;
                }
            }
        }

        cv::Mat bgdModel, fgdModel;
        cv::Rect dummyRect;  // not used with GC_INIT_WITH_MASK
        cv::grabCut(bgr8, gcMask, dummyRect, bgdModel, fgdModel,
                    iterations, cv::GC_INIT_WITH_MASK);

        // Extract per-column horizon from the GrabCut result.
        // Scan downward: first row that is background = horizon.
        for (int x = 0; x < wCols; x++) {
            for (int y = 0; y < wRows; y++) {
                uchar v = gcMask.at<uchar>(y, x);
                if (v == cv::GC_BGD || v == cv::GC_PR_BGD) {
                    // Map back to original coords
                    int origX = (int)(x / scale);
                    origX = std::min(std::max(origX, 0), cols - 1);
                    int origY = (int)(y / scale);
                    origY = std::min(std::max(origY, 0), rows - 1);
                    if (outHorizonY[origX] < 0 || origY < outHorizonY[origX]) {
                        outHorizonY[origX] = origY;
                    }
                    break;
                }
            }
        }

        // Median filter the result
        int medW = std::max(3, wCols / 50);
        std::vector<int> smoothed(cols);
        for (int x = 0; x < cols; x++) smoothed[x] = outHorizonY[x];
        for (int x = 0; x < cols; x++) {
            if (outHorizonY[x] < 0) continue;
            int lo = std::max(0, x - medW);
            int hi = std::min(cols - 1, x + medW);
            std::vector<int> window;
            for (int j = lo; j <= hi; j++) {
                if (outHorizonY[j] >= 0) window.push_back(outHorizonY[j]);
            }
            if (!window.empty()) {
                std::sort(window.begin(), window.end());
                smoothed[x] = window[window.size() / 2];
            }
        }
        for (int x = 0; x < cols; x++) outHorizonY[x] = smoothed[x];

    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception in grabCutHorizon: %s", e.what());
    } catch (...) {
        Log_e("Unknown exception in grabCutHorizon");
    }
}
