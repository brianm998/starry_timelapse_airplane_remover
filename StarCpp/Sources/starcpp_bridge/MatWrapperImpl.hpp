// MatWrapperImpl.hpp — Internal C++ implementation behind opaque MatWrapperRef
#pragma once

#include <opencv2/core.hpp>
#include <atomic>

struct MatWrapperImpl {
    cv::Mat mat;

    explicit MatWrapperImpl(const cv::Mat& m) : mat(m.clone()) {
        uint64_t count = mat.step[0] * mat.rows;
        totalBytes_.fetch_add(count, std::memory_order_relaxed);
        totalInstances_.fetch_add(1, std::memory_order_relaxed);
    }

    // Zero-copy: wrap external data
    MatWrapperImpl(int height, int width, int cvType, void* data, size_t step)
        : mat(height, width, cvType, data, step)
    {
        uint64_t count = mat.step[0] * mat.rows;
        totalBytes_.fetch_add(count, std::memory_order_relaxed);
        totalInstances_.fetch_add(1, std::memory_order_relaxed);
    }

    ~MatWrapperImpl() {
        uint64_t count = mat.step[0] * mat.rows;
        totalBytes_.fetch_sub(count, std::memory_order_relaxed);
        totalInstances_.fetch_sub(1, std::memory_order_relaxed);
    }

    // Non-copyable, movable
    MatWrapperImpl(const MatWrapperImpl&) = delete;
    MatWrapperImpl& operator=(const MatWrapperImpl&) = delete;

    static std::atomic<uint64_t> totalBytes_;
    static std::atomic<uint64_t> totalInstances_;
};
