// OCVFeatureSetImpl.hpp — Internal C++ implementation behind opaque OCVFeatureSetRef
#pragma once

#include <opencv2/core.hpp>
#include <opencv2/features2d.hpp>
#include <vector>

struct OCVFeatureSetImpl {
    std::vector<cv::KeyPoint> keypoints;
    cv::Mat descriptors;

    OCVFeatureSetImpl() = default;

    OCVFeatureSetImpl(const std::vector<cv::KeyPoint>& kp, const cv::Mat& desc)
        : keypoints(kp), descriptors(desc) {}
};
