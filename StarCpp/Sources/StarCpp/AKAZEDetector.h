// AKAZEDetector.h — declarations for the from-scratch AKAZE port. See
// AKAZEDetector.cpp's file header for why this exists at all. Lives beside
// SIFTDetector.h (private, C++-only — MatWrapperImpl.hpp's convention), not in
// StarCpp's public `include/` directory, for the same reason: this file is
// full C++ (cv::Mat, std::vector), and Swift's ClangImporter would choke on it
// if it were part of the umbrella header's public surface.
#pragma once

#include <opencv2/core.hpp>
#include <vector>

namespace star_akaze {

// Both mirror cv::AKAZE::create()->detect()/compute()'s combined effect as
// this codebase's own ia_find_features earth branch uses them: detect capped
// at `maxKeypoints` by response (cv::KeyPointsFilter::retainBest, exactly as
// ImageAligner.cpp already does between its own detect()/compute() calls),
// mask-filtered, then described — from a single nonlinear scale-space build
// rather than the two separate ones detect()+compute() forces as independent
// Feature2D calls (see the file header for why that is safe to collapse).
// `threshold` is the detector response cutoff (Config's earth threshold,
// 1e-4 as of this writing — see ImageAligner.cpp's comment on that constant).
// Returns false on any failure; the caller then falls back to real
// cv::AKAZE::create() wholesale, exactly as the SIFT branch falls back to
// real cv::SIFT.
bool akazeDetectAndComputeReference(const cv::Mat &img8u, const cv::Mat &mask, int maxKeypoints,
                                    float threshold, std::vector<cv::KeyPoint> &keypoints,
                                    cv::Mat &descriptors);

bool akazeDetectAndComputeGPU(const cv::Mat &img8u, const cv::Mat &mask, int maxKeypoints,
                              float threshold, std::vector<cv::KeyPoint> &keypoints,
                              cv::Mat &descriptors);

} // namespace star_akaze
