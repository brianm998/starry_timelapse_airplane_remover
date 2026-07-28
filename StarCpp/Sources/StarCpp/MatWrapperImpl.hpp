// MatWrapperImpl.hpp — Internal C++ implementation behind opaque MatWrapperRef
#pragma once

#include <opencv2/core.hpp>
#include <atomic>

struct MatWrapperImpl {
    cv::Mat mat;

    // Tag selecting the constructor that shares the source buffer instead of copying it.
    struct Adopt {};

    // Deep-copying constructor. Keep using this wherever the wrapper must be
    // independent of the source:
    //   mat_wrapper_clone     (MatWrapper.cpp:77) — the public detach primitive.
    //                         Horizon.swift:396 and FrameHorizonProcessor.swift:705
    //                         build a NON-OWNING wrapper over Swift array storage
    //                         inside withUnsafeMutableBytes and depend on this copy
    //                         landing before that array dies.
    //   buffer_holder_to_mat  (BufferHolder.cpp:72) — cv::Mat over BufferHolderImpl's
    //                         own malloc'd buffer.
    //   mat_wrapper_create    (MatWrapper.cpp:92) — cv::Mat over caller-supplied data.
    //   shift passthrough     (PixelatedImageBridge.cpp:253) — copy of a live wrapper.
    explicit MatWrapperImpl(const cv::Mat& m) : mat(m.clone()) { account(); }

    // Adopting constructor: shares the source's pixel buffer through OpenCV's
    // refcount rather than copying it. Intended for a freshly produced result that
    // the caller is about to drop — the refcount keeps the buffer alive.
    //
    // canAdopt() encodes "the caller is the sole owner of an ordinary, packed,
    // OpenCV-owned buffer and is about to drop it". Every clause fails toward
    // cloning, so tagging a call site wrongly can cost a copy but cannot dangle,
    // corrupt, or alias.
    MatWrapperImpl(Adopt, const cv::Mat& m) : mat(canAdopt(m) ? m : m.clone()) { account(); }

    // Zero-copy: wrap external data
    MatWrapperImpl(int height, int width, int cvType, void* data, size_t step)
        : mat(height, width, cvType, data, step) { account(); }

    ~MatWrapperImpl() {
        totalBytes_.fetch_sub(accountedBytes_, std::memory_order_relaxed);
        totalInstances_.fetch_sub(1, std::memory_order_relaxed);
    }

    // Non-copyable, movable
    MatWrapperImpl(const MatWrapperImpl&) = delete;
    MatWrapperImpl& operator=(const MatWrapperImpl&) = delete;

    static std::atomic<uint64_t> totalBytes_;
    static std::atomic<uint64_t> totalInstances_;

private:
    // Each clause blocks one silent failure mode; all four were checked against the
    // OpenCV 4.12 bundled in this tree.
    //
    //   m.u              the source owns its buffer. A cv::Mat over external memory
    //                    has u == nullptr, so sharing it would dangle.
    //   isContinuous()   no stride gap. mat_wrapper_data_length reports
    //                    total()*elemSize() and Swift's MatWrapper.buffer(of:)
    //                    (PixelatedImage.swift:1252) reads that many PACKED elements
    //                    from mat.data. Nothing in the tree ever calls isContinuous(),
    //                    so a shared ROI view would read the wrong pixels.
    //   !SUBMATRIX_FLAG  a full-width ROI is continuous but still a view: it aliases
    //                    its parent and pins the whole parent buffer alive (150x
    //                    retention measured for an 8-row bottom_crop).
    //   refcount == 1    nobody else holds this buffer, so adopting cannot alias a
    //                    live wrapper. This distinguishes a fresh local
    //                    (`return output;` — NRVO, refcount 1) from a conditional
    //                    passthrough (ensure8U's `if (input.depth() == CV_8U) return
    //                    input;` — materialises a copy, refcount 2).
    //
    // One case no predicate can catch: a live wrapper's own mat is also refcount 1,
    // indistinguishable from a fresh local. Hence the call-site invariant — never
    // pass a live wrapper's mat to wrap(); use the deep constructor for that.
    static bool canAdopt(const cv::Mat& m) {
        return m.u
            && m.isContinuous()
            && !(m.flags & cv::Mat::SUBMATRIX_FLAG)
            && m.u->refcount == 1;
    }

    // Remembered so the destructor subtracts exactly what the constructor added.
    uint64_t accountedBytes_ = 0;

    void account() {
        accountedBytes_ = (uint64_t)mat.step[0] * mat.rows;
        totalBytes_.fetch_add(accountedBytes_, std::memory_order_relaxed);
        totalInstances_.fetch_add(1, std::memory_order_relaxed);
    }
};
