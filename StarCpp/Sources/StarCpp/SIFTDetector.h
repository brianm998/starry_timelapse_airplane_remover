// SIFTDetector.h — internal C++ interface to the from-scratch SIFT port.
//
// Not part of the public C API (no MatWrapperRef/extern "C" boundary): this is
// included only by ImageAligner.cpp, which already works directly in
// cv::Mat/cv::KeyPoint. The public-facing test entry points
// (ia_debug_sift_reference/ia_debug_sift_gpu, declared in ImageAligner.h) are
// thin wrappers around these two functions.
//
// See SIFTDetector.cpp for why this exists at all: OpenCV's real SIFT
// internals are not exposed by any public header, so accelerating the
// Gaussian pyramid (the ~100% of SIFT's cost OpenCV's own profiling puts
// there) means porting the whole algorithm, not hooking into part of it.
#pragma once

#include <opencv2/core.hpp>
#include <vector>

namespace star_sift {

// Faithful CPU port of cv::SIFT::create(nfeatures)->detectAndCompute(img, mask,
// keypoints, descriptors), matching its defaults exactly (nOctaveLayers=3,
// contrastThreshold=0.04, edgeThreshold=10, sigma=1.6,
// enable_precise_upscale=false — the last is the actual default the public
// cv::SIFT::create() API has, not the SIFT_Impl constructor's, which differs).
// Builds the Gaussian pyramid with real cv::resize/cv::GaussianBlur calls, so
// this is expected to track real cv::SIFT closely — see
// SIFTDetectorTests.swift for how closely, measured. Always available; never
// fails for lack of a GPU.
bool siftDetectAndComputeReference(const cv::Mat &img8u, const cv::Mat &mask,
                                   int nfeatures, std::vector<cv::KeyPoint> &keypoints,
                                   cv::Mat &descriptors);

// Same algorithm and same contract, except the Gaussian pyramid is built by
// the registered GPUSiftPyramidFunc (see GPUOps_C.h) instead of real
// cv::resize/cv::GaussianBlur. Returns false — leaving keypoints/descriptors
// untouched — when no GPU pyramid handler is registered or it fails; the
// caller (ia_find_features) then falls back to real cv::SIFT entirely, not to
// siftDetectAndComputeReference.
bool siftDetectAndComputeGPU(const cv::Mat &img8u, const cv::Mat &mask,
                             int nfeatures, std::vector<cv::KeyPoint> &keypoints,
                             cv::Mat &descriptors);

} // namespace star_sift
