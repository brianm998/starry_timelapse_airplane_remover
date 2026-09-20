// SIFTDetector.cpp — a from-scratch reimplementation of OpenCV's SIFT keypoint
// detector (D. Lowe's algorithm), used only for the GPU-accelerated sky/star
// keypoint path (Config.useGPUForSIFT, off by default).
//
// Why this exists at all: OpenCV's SIFT internals — pyramid construction,
// extremum refinement, orientation histograms, descriptor computation — are
// private implementation details of SIFT_Impl and are not declared in any
// public header, so there is no seam to hand a GPU-built pyramid into
// "OpenCV's real SIFT" for the rest of the pipeline. GPU_ACCELERATION_PROPOSAL.md
// measured OpenCV's own profiling putting ~100% of SIFT's cost inside
// buildGaussianPyramid, so this ports the *rest* of the algorithm too —
// extrema detection, sub-pixel refinement, orientation, descriptors — as a
// faithful but unhurried scalar port, since none of it is the hot path.
//
// Faithful, not verbatim: written from an independent reading of OpenCV
// 4.12.0's real source (modules/features2d/src/sift.{dispatch.cpp,simd.hpp},
// BSD-3-Clause, https://github.com/opencv/opencv) to match its math and
// constants exactly, not copied from it — this codebase's style throughout
// (see warpInto's comment on OpenCV's imgwarp.cpp, for one) is to understand
// and cite behaviour rather than paste source. Three pieces of OpenCV's own
// public API are called directly rather than re-implemented, both because
// doing so is correct and because it is exactly how this file's own AKAZE
// branch (ia_find_features) already uses two of them:
//   - cv::KeyPointsFilter::{removeDuplicatedSorted, retainBest, runByPixelsMask}
//     (opencv2/features2d.hpp — CV_EXPORTS, genuinely public)
//   - cv::hal::{fastAtan2, magnitude32f, exp32f} (opencv2/core/hal/hal.hpp —
//     CV_EXPORTS, the same vectorized math primitives real SIFT itself calls)
//
// NOT proven bit-identical to cv::SIFT, and not attempting to be: this is a
// materially larger behavioral-drift risk than Tier 1's warp/median-merge
// kernels (which call real OpenCV boundary logic and only replace
// arithmetic), which is why it ships behind its own flag — see
// Config.useGPUForSIFT's doc comment. Validated behaviorally against real
// cv::SIFT; see SIFTDetectorTests.swift for the measured agreement.
//
// Two backends share one algorithm here:
//   - siftDetectAndComputeReference: builds the Gaussian pyramid with real
//     cv::resize/cv::GaussianBlur calls (CPU, always available). This is what
//     proves the ported algorithm itself — extrema/refinement/orientation/
//     descriptor — matches real SIFT, independent of any GPU question.
//   - siftDetectAndComputeGPU: builds the same pyramid via the registered
//     Metal handler (GPUOps.swift) instead. Comparing this against the
//     reference backend isolates what the GPU pyramid itself changes.
#include "SIFTDetector.h"
#include "GPUOps_C.h"
#include "MatWrapper.h"
#include "MatWrapperImpl.hpp"

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/features2d.hpp>
#include <opencv2/core/hal/hal.hpp>

#include <cmath>
#include <cfloat>
#include <climits>
#include <algorithm>
#include <vector>

extern "C" GPUSiftPyramidFunc gpu_ops_get_sift_pyramid_handler(void);

namespace {

// ---- Constants, matching OpenCV's sift.simd.hpp exactly ----
constexpr int kDescrWidth = 4;          // SIFT_DESCR_WIDTH
constexpr int kDescrHistBins = 8;       // SIFT_DESCR_HIST_BINS
constexpr float kInitSigma = 0.5f;      // SIFT_INIT_SIGMA
constexpr int kImgBorder = 5;           // SIFT_IMG_BORDER
constexpr int kMaxInterpSteps = 5;      // SIFT_MAX_INTERP_STEPS
constexpr int kOriHistBins = 36;        // SIFT_ORI_HIST_BINS
constexpr float kOriSigFctr = 1.5f;     // SIFT_ORI_SIG_FCTR
constexpr float kOriRadius = 4.5f;      // SIFT_ORI_RADIUS (3 * kOriSigFctr)
constexpr float kOriPeakRatio = 0.8f;   // SIFT_ORI_PEAK_RATIO
constexpr float kDescrSclFctr = 3.f;    // SIFT_DESCR_SCL_FCTR
constexpr float kDescrMagThr = 0.2f;    // SIFT_DESCR_MAG_THR
constexpr float kIntDescrFctr = 512.f;  // SIFT_INT_DESCR_FCTR
// OpenCV's "sift_wt" is always `float` in this build (its DoG_TYPE_SHORT
// compile-time switch defaults to 0), so this port just uses float directly.

// cv::SIFT::create(nfeatures)'s defaults, as this codebase's own call
// (ImageAligner.cpp's AlignmentTypeSky branch) leaves them.
constexpr int kNOctaveLayers = 3;
constexpr double kContrastThreshold = 0.04;
constexpr double kEdgeThreshold = 10.0;
constexpr double kSigma = 1.6;
// firstOctave is always -1 here: this codebase never calls SIFT with
// useProvidedKeypoints, which is the only case real SIFT ever uses
// firstOctave=0 for.
constexpr int kFirstOctave = -1;
constexpr bool kDoubleImageSize = true;

// Wraps `mat`'s existing buffer with no copy and no ownership transfer, for
// handing a live cv::Mat this function already owns for the call's duration
// to a registered GPU handler — the same non-owning-view helper ImageAligner.cpp
// defines for its own GPU calls (duplicated here rather than shared across
// translation units, since it is five lines and each file that needs it
// already includes MatWrapperImpl.hpp).
MatWrapperRef wrapReadOnly(const cv::Mat &mat) {
    return new MatWrapperImpl((int)mat.rows, (int)mat.cols, mat.type(),
                              const_cast<uchar*>(mat.data), mat.step[0]);
}

// ---- Pyramid construction: the reference path, real cv::resize + cv::GaussianBlur ----

// Matches OpenCV's createInitialImage with enable_precise_upscale=false — the
// public cv::SIFT::create()'s actual default (the SIFT_Impl constructor's own
// default of true is not what the factory function passes) — and
// DoG_TYPE_SHORT=0: a plain 2x bilinear resize, not the
// warpAffine/BORDER_REFLECT "precise" path.
cv::Mat createInitialImageReference(const cv::Mat &grayFloat, bool doubleImageSize, double sigma) {
    if (doubleImageSize) {
        float sigDiff = std::sqrt(std::max(sigma * sigma - kInitSigma * kInitSigma * 4, 0.01));
        cv::Mat doubled;
        cv::resize(grayFloat, doubled, cv::Size(grayFloat.cols * 2, grayFloat.rows * 2),
                  0, 0, cv::INTER_LINEAR);
        cv::Mat result;
        cv::GaussianBlur(doubled, result, cv::Size(), sigDiff, sigDiff);
        return result;
    }
    float sigDiff = std::sqrt(std::max(sigma * sigma - kInitSigma * kInitSigma, 0.01));
    cv::Mat result;
    cv::GaussianBlur(grayFloat, result, cv::Size(), sigDiff, sigDiff);
    return result;
}

// Matches OpenCV's buildGaussianPyramid: the incremental per-layer sigma
// schedule (sigma_total^2 = sigma_i^2 + sigma_{i-1}^2, so each blur only adds
// the sigma the previous one is missing), nearest-neighbour halving at each
// octave boundary, and the per-layer blur cascade within an octave.
std::vector<cv::Mat> buildGaussianPyramidReference(const cv::Mat &base, int nOctaves,
                                                   int nOctaveLayers, double sigma) {
    std::vector<double> sig(nOctaveLayers + 3);
    std::vector<cv::Mat> pyr((size_t)nOctaves * (nOctaveLayers + 3));

    sig[0] = sigma;
    double k = std::pow(2., 1. / nOctaveLayers);
    for (int i = 1; i < nOctaveLayers + 3; i++) {
        double sigPrev = std::pow(k, (double)(i - 1)) * sigma;
        double sigTotal = sigPrev * k;
        sig[i] = std::sqrt(sigTotal * sigTotal - sigPrev * sigPrev);
    }

    for (int o = 0; o < nOctaves; o++) {
        for (int i = 0; i < nOctaveLayers + 3; i++) {
            cv::Mat &dst = pyr[(size_t)o * (nOctaveLayers + 3) + i];
            if (o == 0 && i == 0) {
                dst = base;
            } else if (i == 0) {
                const cv::Mat &src = pyr[(size_t)(o - 1) * (nOctaveLayers + 3) + nOctaveLayers];
                cv::resize(src, dst, cv::Size(src.cols / 2, src.rows / 2), 0, 0, cv::INTER_NEAREST);
            } else {
                const cv::Mat &src = pyr[(size_t)o * (nOctaveLayers + 3) + i - 1];
                cv::GaussianBlur(src, dst, cv::Size(), sig[i], sig[i]);
            }
        }
    }
    return pyr;
}

// Trivial and exact either way — real cv::subtract, matching OpenCV's own
// buildDoGPyramid, which is itself nothing but this.
std::vector<cv::Mat> buildDoGPyramid(const std::vector<cv::Mat> &gpyr, int nOctaveLayers) {
    int nOctaves = (int)gpyr.size() / (nOctaveLayers + 3);
    std::vector<cv::Mat> dogpyr((size_t)nOctaves * (nOctaveLayers + 2));
    for (int o = 0; o < nOctaves; o++) {
        for (int i = 0; i < nOctaveLayers + 2; i++) {
            const cv::Mat &src1 = gpyr[(size_t)o * (nOctaveLayers + 3) + i];
            const cv::Mat &src2 = gpyr[(size_t)o * (nOctaveLayers + 3) + i + 1];
            cv::subtract(src2, src1, dogpyr[(size_t)o * (nOctaveLayers + 2) + i],
                        cv::noArray(), CV_32F);
        }
    }
    return dogpyr;
}

// ---- Sub-pixel extremum refinement, ported from adjustLocalExtrema ----
//
// Interpolates a scale-space extremum's location and scale to sub-pixel
// accuracy via a quadratic (Taylor) fit, iterating up to kMaxInterpSteps times
// as the fit moves the candidate to a neighbouring pixel/layer. Rejects low
// contrast (Lowe's paper section 4) and edge-like responses (principal
// curvature ratio via the Hessian's trace/determinant).
bool adjustLocalExtrema(const std::vector<cv::Mat> &dogPyr, cv::KeyPoint &kpt, int octv,
                        int &layer, int &r, int &c, int nOctaveLayers,
                        float contrastThreshold, float edgeThreshold, float sigma) {
    const float imgScale = 1.f / 255.f;  // 1/(255*SIFT_FIXPT_SCALE), SIFT_FIXPT_SCALE==1
    const float derivScale = imgScale * 0.5f;
    const float secondDerivScale = imgScale;
    const float crossDerivScale = imgScale * 0.25f;

    float xi = 0, xr = 0, xc = 0, contr = 0;
    int i = 0;
    for (; i < kMaxInterpSteps; i++) {
        int idx = octv * (nOctaveLayers + 2) + layer;
        const cv::Mat &img = dogPyr[idx];
        const cv::Mat &prev = dogPyr[idx - 1];
        const cv::Mat &next = dogPyr[idx + 1];

        cv::Vec3f dD((img.at<float>(r, c + 1) - img.at<float>(r, c - 1)) * derivScale,
                     (img.at<float>(r + 1, c) - img.at<float>(r - 1, c)) * derivScale,
                     (next.at<float>(r, c) - prev.at<float>(r, c)) * derivScale);

        float v2 = img.at<float>(r, c) * 2;
        float dxx = (img.at<float>(r, c + 1) + img.at<float>(r, c - 1) - v2) * secondDerivScale;
        float dyy = (img.at<float>(r + 1, c) + img.at<float>(r - 1, c) - v2) * secondDerivScale;
        float dss = (next.at<float>(r, c) + prev.at<float>(r, c) - v2) * secondDerivScale;
        float dxy = (img.at<float>(r + 1, c + 1) - img.at<float>(r + 1, c - 1) -
                    img.at<float>(r - 1, c + 1) + img.at<float>(r - 1, c - 1)) * crossDerivScale;
        float dxs = (next.at<float>(r, c + 1) - next.at<float>(r, c - 1) -
                    prev.at<float>(r, c + 1) + prev.at<float>(r, c - 1)) * crossDerivScale;
        float dys = (next.at<float>(r + 1, c) - next.at<float>(r - 1, c) -
                    prev.at<float>(r + 1, c) + prev.at<float>(r - 1, c)) * crossDerivScale;

        cv::Matx33f H(dxx, dxy, dxs,
                     dxy, dyy, dys,
                     dxs, dys, dss);
        cv::Vec3f X = H.solve(dD, cv::DECOMP_LU);

        xi = -X[2];
        xr = -X[1];
        xc = -X[0];

        if (std::abs(xi) < 0.5f && std::abs(xr) < 0.5f && std::abs(xc) < 0.5f)
            break;

        if (std::abs(xi) > (float)(INT_MAX / 3) || std::abs(xr) > (float)(INT_MAX / 3) ||
            std::abs(xc) > (float)(INT_MAX / 3))
            return false;

        c += cvRound(xc);
        r += cvRound(xr);
        layer += cvRound(xi);

        if (layer < 1 || layer > nOctaveLayers ||
            c < kImgBorder || c >= img.cols - kImgBorder ||
            r < kImgBorder || r >= img.rows - kImgBorder)
            return false;
    }

    if (i >= kMaxInterpSteps) return false;

    {
        int idx = octv * (nOctaveLayers + 2) + layer;
        const cv::Mat &img = dogPyr[idx];
        const cv::Mat &prev = dogPyr[idx - 1];
        const cv::Mat &next = dogPyr[idx + 1];
        cv::Matx31f dD((img.at<float>(r, c + 1) - img.at<float>(r, c - 1)) * derivScale,
                       (img.at<float>(r + 1, c) - img.at<float>(r - 1, c)) * derivScale,
                       (next.at<float>(r, c) - prev.at<float>(r, c)) * derivScale);
        float t = dD.dot(cv::Matx31f(xc, xr, xi));

        contr = img.at<float>(r, c) * imgScale + t * 0.5f;
        if (std::abs(contr) * nOctaveLayers < contrastThreshold) return false;

        float v2 = img.at<float>(r, c) * 2.f;
        float dxx = (img.at<float>(r, c + 1) + img.at<float>(r, c - 1) - v2) * secondDerivScale;
        float dyy = (img.at<float>(r + 1, c) + img.at<float>(r - 1, c) - v2) * secondDerivScale;
        float dxy = (img.at<float>(r + 1, c + 1) - img.at<float>(r + 1, c - 1) -
                    img.at<float>(r - 1, c + 1) + img.at<float>(r - 1, c - 1)) * crossDerivScale;
        float tr = dxx + dyy;
        float det = dxx * dyy - dxy * dxy;

        if (det <= 0 || tr * tr * edgeThreshold >= (edgeThreshold + 1) * (edgeThreshold + 1) * det)
            return false;
    }

    kpt.pt.x = (c + xc) * (1 << octv);
    kpt.pt.y = (r + xr) * (1 << octv);
    kpt.octave = octv + (layer << 8) + (cvRound((xi + 0.5) * 255) << 16);
    kpt.size = sigma * powf(2.f, (layer + xi) / nOctaveLayers) * (1 << octv) * 2;
    kpt.response = std::abs(contr);
    return true;
}

// Computes a gradient orientation histogram at a specified pixel, smoothed by
// a 5-tap circular filter, ported from calcOrientationHist. Returns the peak
// bin's value; the caller looks for every bin within kOriPeakRatio of it, so
// one extremum can yield more than one keypoint (one per significant
// orientation).
float calcOrientationHist(const cv::Mat &img, cv::Point pt, int radius, float sigma,
                          float *hist, int n) {
    const int maxLen = (radius * 2 + 1) * (radius * 2 + 1);
    float expfScale = -1.f / (2.f * sigma * sigma);

    std::vector<float> X(maxLen), Y(maxLen), Mag(maxLen), Ori(maxLen), W(maxLen);
    std::vector<float> temphistBuf((size_t)n + 4, 0.f);
    float *temphist = temphistBuf.data() + 2;

    int k = 0;
    for (int i = -radius; i <= radius; i++) {
        int y = pt.y + i;
        if (y <= 0 || y >= img.rows - 1) continue;
        for (int j = -radius; j <= radius; j++) {
            int x = pt.x + j;
            if (x <= 0 || x >= img.cols - 1) continue;

            float dx = img.at<float>(y, x + 1) - img.at<float>(y, x - 1);
            float dy = img.at<float>(y - 1, x) - img.at<float>(y + 1, x);

            X[k] = dx; Y[k] = dy; W[k] = (i * i + j * j) * expfScale;
            k++;
        }
    }
    const int len = k;

    cv::hal::exp32f(W.data(), W.data(), len);
    cv::hal::fastAtan2(Y.data(), X.data(), Ori.data(), len, true);
    cv::hal::magnitude32f(X.data(), Y.data(), Mag.data(), len);

    for (int kk = 0; kk < len; kk++) {
        int bin = cvRound((n / 360.f) * Ori[kk]);
        if (bin >= n) bin -= n;
        if (bin < 0) bin += n;
        temphist[bin] += W[kk] * Mag[kk];
    }

    temphist[-1] = temphist[n - 1];
    temphist[-2] = temphist[n - 2];
    temphist[n] = temphist[0];
    temphist[n + 1] = temphist[1];

    for (int i = 0; i < n; i++) {
        hist[i] = (temphist[i - 2] + temphist[i + 2]) * (1.f / 16.f) +
                  (temphist[i - 1] + temphist[i + 1]) * (4.f / 16.f) +
                  temphist[i] * (6.f / 16.f);
    }

    float maxval = hist[0];
    for (int i = 1; i < n; i++) maxval = std::max(maxval, hist[i]);
    return maxval;
}

// Scans one DoG image (excluding a kImgBorder-wide margin) for 3x3x3
// scale-space extrema, refines each candidate via adjustLocalExtrema, and
// assigns one or more orientations via calcOrientationHist — ported from
// findScaleSpaceExtrema's scalar tail loop (this port has no SIMD path, since
// none of this is the hot path; see the file header).
void findScaleSpaceExtrema(int o, int i, int threshold, int idx, int step, int cols,
                           int nOctaveLayers, double contrastThreshold, double edgeThreshold,
                           double sigma, const std::vector<cv::Mat> &gaussPyr,
                           const std::vector<cv::Mat> &dogPyr,
                           std::vector<cv::KeyPoint> &kpts) {
    static const int n = kOriHistBins;
    float hist[kOriHistBins];

    const cv::Mat &img = dogPyr[idx];
    const cv::Mat &prev = dogPyr[idx - 1];
    const cv::Mat &next = dogPyr[idx + 1];
    const int rows = img.rows;

    for (int r = kImgBorder; r < rows - kImgBorder; r++) {
        const float *currptr = img.ptr<float>(r);
        const float *prevptr = prev.ptr<float>(r);
        const float *nextptr = next.ptr<float>(r);

        for (int c = kImgBorder; c < cols - kImgBorder; c++) {
            float val = currptr[c];
            if (std::abs(val) <= threshold) continue;

            float _00, _01, _02, _10, _12, _20, _21, _22;
            _00 = currptr[c-step-1]; _01 = currptr[c-step]; _02 = currptr[c-step+1];
            _10 = currptr[c     -1];                        _12 = currptr[c     +1];
            _20 = currptr[c+step-1]; _21 = currptr[c+step]; _22 = currptr[c+step+1];

            bool calculate = false;
            if (val > 0) {
                float vmax = std::max({_00,_01,_02,_10,_12,_20,_21,_22});
                if (val >= vmax) {
                    _00 = prevptr[c-step-1]; _01 = prevptr[c-step]; _02 = prevptr[c-step+1];
                    _10 = prevptr[c     -1];                        _12 = prevptr[c     +1];
                    _20 = prevptr[c+step-1]; _21 = prevptr[c+step]; _22 = prevptr[c+step+1];
                    vmax = std::max({_00,_01,_02,_10,_12,_20,_21,_22});
                    if (val >= vmax) {
                        _00 = nextptr[c-step-1]; _01 = nextptr[c-step]; _02 = nextptr[c-step+1];
                        _10 = nextptr[c     -1];                        _12 = nextptr[c     +1];
                        _20 = nextptr[c+step-1]; _21 = nextptr[c+step]; _22 = nextptr[c+step+1];
                        vmax = std::max({_00,_01,_02,_10,_12,_20,_21,_22});
                        if (val >= vmax) {
                            float _11p = prevptr[c], _11n = nextptr[c];
                            calculate = (val >= std::max(_11p, _11n));
                        }
                    }
                }
            } else {
                float vmin = std::min({_00,_01,_02,_10,_12,_20,_21,_22});
                if (val <= vmin) {
                    _00 = prevptr[c-step-1]; _01 = prevptr[c-step]; _02 = prevptr[c-step+1];
                    _10 = prevptr[c     -1];                        _12 = prevptr[c     +1];
                    _20 = prevptr[c+step-1]; _21 = prevptr[c+step]; _22 = prevptr[c+step+1];
                    vmin = std::min({_00,_01,_02,_10,_12,_20,_21,_22});
                    if (val <= vmin) {
                        _00 = nextptr[c-step-1]; _01 = nextptr[c-step]; _02 = nextptr[c-step+1];
                        _10 = nextptr[c     -1];                        _12 = nextptr[c     +1];
                        _20 = nextptr[c+step-1]; _21 = nextptr[c+step]; _22 = nextptr[c+step+1];
                        vmin = std::min({_00,_01,_02,_10,_12,_20,_21,_22});
                        if (val <= vmin) {
                            float _11p = prevptr[c], _11n = nextptr[c];
                            calculate = (val <= std::min(_11p, _11n));
                        }
                    }
                }
            }

            if (!calculate) continue;

            cv::KeyPoint kpt;
            int r1 = r, c1 = c, layer = i;
            if (!adjustLocalExtrema(dogPyr, kpt, o, layer, r1, c1, nOctaveLayers,
                                    (float)contrastThreshold, (float)edgeThreshold, (float)sigma))
                continue;

            float sclOctv = kpt.size * 0.5f / (1 << o);
            float omax = calcOrientationHist(gaussPyr[(size_t)o * (nOctaveLayers + 3) + layer],
                                             cv::Point(c1, r1),
                                             cvRound(kOriRadius * sclOctv),
                                             kOriSigFctr * sclOctv, hist, n);
            float magThr = omax * kOriPeakRatio;
            for (int j = 0; j < n; j++) {
                int l = j > 0 ? j - 1 : n - 1;
                int r2 = j < n - 1 ? j + 1 : 0;
                if (hist[j] > hist[l] && hist[j] > hist[r2] && hist[j] >= magThr) {
                    float bin = j + 0.5f * (hist[l] - hist[r2]) / (hist[l] - 2 * hist[j] + hist[r2]);
                    bin = bin < 0 ? n + bin : bin >= n ? bin - n : bin;
                    cv::KeyPoint newKpt = kpt;
                    newKpt.angle = 360.f - (float)((360.f / n) * bin);
                    if (std::abs(newKpt.angle - 360.f) < FLT_EPSILON) newKpt.angle = 0.f;
                    kpts.push_back(newKpt);
                }
            }
        }
    }
}

// Builds the 128-float descriptor for one keypoint: a rotation-normalised 4x4
// grid of 8-bin gradient orientation histograms, trilinearly interpolated,
// hysteresis-thresholded and rescaled — ported from calcSIFTDescriptor.
//
// The values land in `dst` (CV_32F) already rounded and clamped to [0,255]:
// that is not a bug carried over from an 8-bit past, it is what real SIFT's
// CV_32F descriptor path does too (`saturate_cast<uchar>` written into a
// float*), and matching it is what keeps a float descriptor byte-comparable
// to an 8-bit one downstream.
void calcSIFTDescriptor(const cv::Mat &img, cv::Point2f ptf, float ori, float scl,
                        int d, int n, cv::Mat &dst, int row) {
    cv::Point pt(cvRound(ptf.x), cvRound(ptf.y));
    float cosT = std::cos(ori * (float)(CV_PI / 180));
    float sinT = std::sin(ori * (float)(CV_PI / 180));
    float binsPerRad = n / 360.f;
    float expScale = -1.f / (d * d * 0.5f);
    float histWidth = kDescrSclFctr * scl;
    int radius = cvRound(histWidth * 1.4142135623730951f * (d + 1) * 0.5f);
    radius = std::min(radius, (int)std::sqrt((double)img.cols * img.cols +
                                             (double)img.rows * img.rows));
    cosT /= histWidth;
    sinT /= histWidth;

    const int rows = img.rows, cols = img.cols;
    const int lenMax = (radius * 2 + 1) * (radius * 2 + 1);
    const int lenHist = (d + 2) * (d + 2) * (n + 2);
    const int lenDdn = d * d * n;

    std::vector<float> X(lenMax), Y(lenMax), Mag(lenMax), Ori(lenMax), W(lenMax),
                       RBin(lenMax), CBin(lenMax);
    std::vector<float> hist((size_t)lenHist, 0.f);
    std::vector<float> rawDst((size_t)lenDdn, 0.f);

    int k = 0;
    for (int i = -radius; i <= radius; i++) {
        for (int j = -radius; j <= radius; j++) {
            // Rotate into the keypoint's own frame; subtract 0.5 so a sample
            // exactly at a bin centre gets full weight there after interpolation.
            float cRot = j * cosT - i * sinT;
            float rRot = j * sinT + i * cosT;
            float rbin = rRot + d / 2 - 0.5f;
            float cbin = cRot + d / 2 - 0.5f;
            int r = pt.y + i, c = pt.x + j;

            if (rbin > -1 && rbin < d && cbin > -1 && cbin < d &&
                r > 0 && r < rows - 1 && c > 0 && c < cols - 1) {
                float dx = img.at<float>(r, c + 1) - img.at<float>(r, c - 1);
                float dy = img.at<float>(r - 1, c) - img.at<float>(r + 1, c);
                X[k] = dx; Y[k] = dy; RBin[k] = rbin; CBin[k] = cbin;
                W[k] = (cRot * cRot + rRot * rRot) * expScale;
                k++;
            }
        }
    }

    const int lenLeft = k;
    cv::hal::fastAtan2(Y.data(), X.data(), Ori.data(), lenLeft, true);
    cv::hal::magnitude32f(X.data(), Y.data(), Mag.data(), lenLeft);
    cv::hal::exp32f(W.data(), W.data(), lenLeft);

    for (int kk = 0; kk < lenLeft; kk++) {
        float rbin = RBin[kk], cbin = CBin[kk];
        float obin = (Ori[kk] - ori) * binsPerRad;
        float mag = Mag[kk] * W[kk];

        int r0 = cvFloor(rbin);
        int c0 = cvFloor(cbin);
        int o0 = cvFloor(obin);
        rbin -= r0; cbin -= c0; obin -= o0;

        if (o0 < 0) o0 += n;
        if (o0 >= n) o0 -= n;

        // Histogram update by trilinear interpolation over (row, col, orientation).
        float v_r1 = mag * rbin, v_r0 = mag - v_r1;
        float v_rc11 = v_r1 * cbin, v_rc10 = v_r1 - v_rc11;
        float v_rc01 = v_r0 * cbin, v_rc00 = v_r0 - v_rc01;
        float v_rco111 = v_rc11 * obin, v_rco110 = v_rc11 - v_rco111;
        float v_rco101 = v_rc10 * obin, v_rco100 = v_rc10 - v_rco101;
        float v_rco011 = v_rc01 * obin, v_rco010 = v_rc01 - v_rco011;
        float v_rco001 = v_rc00 * obin, v_rco000 = v_rc00 - v_rco001;

        int idx = ((r0 + 1) * (d + 2) + c0 + 1) * (n + 2) + o0;
        hist[idx] += v_rco000;
        hist[idx + 1] += v_rco001;
        hist[idx + (n + 2)] += v_rco010;
        hist[idx + (n + 3)] += v_rco011;
        hist[idx + (d + 2) * (n + 2)] += v_rco100;
        hist[idx + (d + 2) * (n + 2) + 1] += v_rco101;
        hist[idx + (d + 3) * (n + 2)] += v_rco110;
        hist[idx + (d + 3) * (n + 2) + 1] += v_rco111;
    }

    // The orientation histograms are circular; fold bin n back into bin 0.
    for (int i = 0; i < d; i++) {
        for (int j = 0; j < d; j++) {
            int idx = ((i + 1) * (d + 2) + (j + 1)) * (n + 2);
            hist[idx] += hist[idx + n];
            hist[idx + 1] += hist[idx + n + 1];
            for (int kk = 0; kk < n; kk++)
                rawDst[(i * d + j) * n + kk] = hist[idx + kk];
        }
    }

    float nrm2 = 0;
    for (int kk = 0; kk < lenDdn; kk++) nrm2 += rawDst[kk] * rawDst[kk];
    const float thr = std::sqrt(nrm2) * kDescrMagThr;

    nrm2 = 0;
    for (int i = 0; i < lenDdn; i++) {
        float val = std::min(rawDst[i], thr);
        rawDst[i] = val;
        nrm2 += val * val;
    }
    nrm2 = kIntDescrFctr / std::max(std::sqrt(nrm2), FLT_EPSILON);

    float *out = dst.ptr<float>(row);
    for (int kk = 0; kk < lenDdn; kk++) {
        out[kk] = (float)std::clamp(cvRound(rawDst[kk] * nrm2), 0, 255);
    }
}

void calcDescriptors(const std::vector<cv::Mat> &gpyr, const std::vector<cv::KeyPoint> &keypoints,
                     cv::Mat &descriptors, int nOctaveLayers, int firstOctave) {
    static const int d = kDescrWidth, n = kDescrHistBins;
    for (size_t i = 0; i < keypoints.size(); i++) {
        const cv::KeyPoint &kpt = keypoints[i];
        int octave = kpt.octave & 255;
        int layer = (kpt.octave >> 8) & 255;
        octave = octave < 128 ? octave : (-128 | octave);
        float scale = octave >= 0 ? 1.f / (1 << octave) : (float)(1 << -octave);

        float size = kpt.size * scale;
        cv::Point2f ptf(kpt.pt.x * scale, kpt.pt.y * scale);
        const cv::Mat &img = gpyr[(size_t)(octave - firstOctave) * (nOctaveLayers + 3) + layer];

        float angle = 360.f - kpt.angle;
        if (std::abs(angle - 360.f) < FLT_EPSILON) angle = 0.f;
        calcSIFTDescriptor(img, ptf, angle, size * 0.5f, d, n, descriptors, (int)i);
    }
}

// The shared orchestration both backends use — mirrors SIFT_Impl::detectAndCompute
// with useProvidedKeypoints=false (this codebase never sets it) and
// firstOctave fixed at -1 (equivalently, doubleImageSize fixed true).
bool detectAndComputeImpl(const cv::Mat &img8u, const cv::Mat &mask, int nfeatures,
                          bool useGPU, std::vector<cv::KeyPoint> &keypoints,
                          cv::Mat &descriptors) {
    cv::Mat grayFloat;
    img8u.convertTo(grayFloat, CV_32F, 1.0, 0.0);  // SIFT_FIXPT_SCALE == 1: a plain cast

    const int baseCols = kDoubleImageSize ? grayFloat.cols * 2 : grayFloat.cols;
    const int baseRows = kDoubleImageSize ? grayFloat.rows * 2 : grayFloat.rows;
    const int nOctaves = cvRound(std::log((double)std::min(baseCols, baseRows)) / std::log(2.) - 2)
                        - kFirstOctave;
    if (nOctaves <= 0) return false;

    std::vector<cv::Mat> gpyr;

    if (useGPU) {
        GPUSiftPyramidFunc gpuPyramid = gpu_ops_get_sift_pyramid_handler();
        if (!gpuPyramid) return false;

        const size_t pyramidSize = (size_t)nOctaves * (kNOctaveLayers + 3);
        std::vector<MatWrapperRef> outPyramid(pyramidSize, nullptr);
        MatWrapperRef baseRef = wrapReadOnly(grayFloat);
        bool ok = gpuPyramid(baseRef, kDoubleImageSize, kSigma, nOctaves, kNOctaveLayers,
                            outPyramid.data());
        mat_wrapper_release(baseRef);

        if (!ok) {
            for (MatWrapperRef ref : outPyramid) if (ref) mat_wrapper_release(ref);
            return false;
        }
        gpyr.reserve(pyramidSize);
        for (MatWrapperRef ref : outPyramid) {
            if (!ref) { gpyr.clear(); return false; }  // a handler that lied about success
            gpyr.push_back(ref->mat);
            mat_wrapper_release(ref);
        }
    } else {
        cv::Mat base = createInitialImageReference(grayFloat, kDoubleImageSize, kSigma);
        gpyr = buildGaussianPyramidReference(base, nOctaves, kNOctaveLayers, kSigma);
    }

    std::vector<cv::Mat> dogpyr = buildDoGPyramid(gpyr, kNOctaveLayers);

    const int threshold = cvFloor(0.5 * kContrastThreshold / kNOctaveLayers * 255.0);
    keypoints.clear();
    for (int o = 0; o < nOctaves; o++) {
        for (int i = 1; i <= kNOctaveLayers; i++) {
            const int idx = o * (kNOctaveLayers + 2) + i;
            const cv::Mat &img = dogpyr[idx];
            const int step = (int)img.step1();
            findScaleSpaceExtrema(o, i, threshold, idx, step, img.cols, kNOctaveLayers,
                                  kContrastThreshold, kEdgeThreshold, kSigma, gpyr, dogpyr,
                                  keypoints);
        }
    }

    cv::KeyPointsFilter::removeDuplicatedSorted(keypoints);
    if (nfeatures > 0) cv::KeyPointsFilter::retainBest(keypoints, nfeatures);

    // firstOctave < 0: undo the doubling that let octave -1 exist at all.
    for (auto &kpt : keypoints) {
        float scale = 1.f / (float)(1 << -kFirstOctave);
        kpt.octave = (kpt.octave & ~255) | ((kpt.octave + kFirstOctave) & 255);
        kpt.pt *= scale;
        kpt.size *= scale;
    }

    if (!mask.empty()) cv::KeyPointsFilter::runByPixelsMask(keypoints, mask);

    keypoints.shrink_to_fit();

    const int dsize = kDescrWidth * kDescrWidth * kDescrHistBins;  // 128
    descriptors.create((int)keypoints.size(), dsize, CV_32F);
    calcDescriptors(gpyr, keypoints, descriptors, kNOctaveLayers, kFirstOctave);

    return true;
}

} // namespace

namespace star_sift {

bool siftDetectAndComputeReference(const cv::Mat &img8u, const cv::Mat &mask, int nfeatures,
                                   std::vector<cv::KeyPoint> &keypoints, cv::Mat &descriptors) {
    return detectAndComputeImpl(img8u, mask, nfeatures, /*useGPU=*/false, keypoints, descriptors);
}

bool siftDetectAndComputeGPU(const cv::Mat &img8u, const cv::Mat &mask, int nfeatures,
                             std::vector<cv::KeyPoint> &keypoints, cv::Mat &descriptors) {
    return detectAndComputeImpl(img8u, mask, nfeatures, /*useGPU=*/true, keypoints, descriptors);
}

} // namespace star_sift
