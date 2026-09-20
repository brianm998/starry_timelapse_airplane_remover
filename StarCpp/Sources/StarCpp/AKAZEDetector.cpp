// AKAZEDetector.cpp — a from-scratch reimplementation of OpenCV's AKAZE
// keypoint detector (Alcantarilla et al.'s accelerated nonlinear diffusion
// features), used only for the GPU-accelerated earth/ground keypoint path
// (Config.useGPUForAKAZE, off by default). The companion to SIFTDetector.cpp
// for Tier 2's other detector — see that file's header for the shape of the
// argument; the short version repeated here because AKAZE's specifics differ:
//
// OpenCV's AKAZE internals — the nonlinear diffusion pyramid, Hessian-response
// extrema search, orientation and MLDB descriptor — are private implementation
// details of AKAZE_Impl/AKAZEFeatures and are not declared in any public
// header, so (exactly as with SIFT) there is no seam to hand a GPU-built
// pyramid into "OpenCV's real AKAZE" for the rest of the pipeline. This ports
// the whole algorithm, not just the pyramid, as a faithful but unhurried
// scalar port, since only the pyramid construction is the hot path
// (GPU_ACCELERATION_PROPOSAL.md/GPU_IMPLEMENTATION_GUIDE.md: the FED explicit-
// diffusion stencil and its per-level Gaussian blur + Scharr derivatives).
//
// Faithful, not verbatim: written from an independent reading of OpenCV
// 4.12.0's real source (modules/features2d/src/{akaze.cpp,
// kaze/AKAZEFeatures.{cpp,h}, kaze/AKAZEConfig.h, kaze/fed.cpp}, BSD-3-Clause,
// https://github.com/opencv/opencv) to match its math and constants exactly,
// not copied from it. Two pieces of OpenCV's own public API are called
// directly rather than re-implemented, the same ones ImageAligner.cpp's own
// AKAZE branch already relies on:
//   - cv::KeyPointsFilter::{retainBest, runByPixelsMask} (opencv2/features2d.hpp)
//   - cv::hal::fastAtan2 (opencv2/core/hal/hal.hpp)
//
// NOT proven bit-identical to cv::AKAZE, and not attempting to be — see
// Config.useGPUForAKAZE's doc comment. Validated behaviorally against real
// cv::AKAZE; see AKAZEDetectorTests.swift for the measured agreement.
//
// Two backends share one algorithm here, differing only in how the nonlinear
// scale-space pyramid's per-level Lt/Lsmooth images are built:
//   - akazeDetectAndComputeReference: builds the pyramid with real
//     cv::GaussianBlur/cv::Scharr/cv::resize calls (CPU, always available).
//     This is what proves the ported algorithm itself — extrema, subpixel
//     refinement, orientation, MLDB descriptor — matches real AKAZE,
//     independent of any GPU question.
//   - akazeDetectAndComputeGPU: builds the same pyramid via the registered
//     Metal handler (GPUOps.swift) instead. Comparing this against the
//     reference backend isolates what the GPU pyramid itself changes.
//
// Both share every stage after the pyramid: Compute_Determinant_Hessian_Response
// through Compute_Descriptors below take a built pyramid and do not care how
// its images were produced.
#include "AKAZEDetector.h"
#include "GPUOps_C.h"
#include "MatWrapper.h"
#include "MatWrapperImpl.hpp"

#include <opencv2/core.hpp>
#include <opencv2/core/hal/hal.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/features2d.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

extern "C" GPUAkazePyramidFunc gpu_ops_get_akaze_pyramid_handler(void);

namespace {

// ---- AKAZE's fixed configuration, matching cv::AKAZE::create()'s defaults ----
// (this codebase never calls setDescriptorType/setNOctaves/etc., so these are
// the only values that ever apply — see ImageAligner.cpp's AlignmentTypeEarth
// branch, which only ever calls setThreshold).
constexpr int kOmax = 4;                    // AKAZEOptions::omax
constexpr int kNSublevels = 4;               // AKAZEOptions::nsublevels
constexpr float kSoffset = 1.6f;             // AKAZEOptions::soffset
constexpr float kDerivativeFactor = 1.5f;    // AKAZEOptions::derivative_factor
constexpr float kKContrastPercentile = 0.7f; // AKAZEOptions::kcontrast_percentile
constexpr int kKContrastNBins = 300;         // AKAZEOptions::kcontrast_nbins
constexpr int kDescriptorPatternSize = 10;   // AKAZEOptions::descriptor_pattern_size
constexpr int kDescriptorChannels = 3;       // AKAZEOptions::descriptor_channels (MLDB, full)
constexpr int kMLDBBits = (6 + 36 + 120) * kDescriptorChannels;  // 486

MatWrapperRef wrapReadOnly(const cv::Mat &mat) {
    return new MatWrapperImpl((int)mat.rows, (int)mat.cols, mat.type(),
                              const_cast<uchar*>(mat.data), mat.step[0]);
}

// ---- One pyramid level's static description + the built images ----
struct EvolutionLevel {
    cv::Mat Lt, Lsmooth, Lx, Ly, Ldet;
    cv::Size size;
    float esigma = 0.f;
    int octave = 0;
    int sublevel = 0;
    int sigma_size = 0;
    float octave_ratio = 1.f;
    int border = 0;
};

// ---- FED (Fast Explicit Diffusion) step-schedule math, ported from fed.cpp ----
// This is the "dynamic-programming subtlety" GPUOps_C.h's doc comment refers
// to: a cosine/prime-permutation schedule that has nothing to do with image
// size, computed once here and shared by both backends so it is never
// duplicated (and never allowed to drift) in Swift.
bool fedIsPrime(int number) {
    if (number <= 1) return false;
    if (number == 2 || number == 3 || number == 5 || number == 7) return true;
    if (number % 2 == 0 || number % 3 == 0 || number % 5 == 0 || number % 7 == 0) return false;
    int upperLimit = (int)std::sqrt(1.0 + number);
    for (int divisor = 11; divisor <= upperLimit; divisor += 2) {
        if (number % divisor == 0) return false;
    }
    return true;
}

int fedTauInternal(int n, float scale, float tauMax, std::vector<float> &tau) {
    if (n <= 0) return 0;
    tau.assign(n, 0.f);
    std::vector<float> tauh(n, 0.f);

    float c = 1.0f / (4.0f * n + 2.0f);
    float d = scale * tauMax / 2.0f;
    for (int k = 0; k < n; ++k) {
        float h = std::cos((float)CV_PI * (2.0f * k + 1.0f) * c);
        tauh[k] = d / (h * h);
    }

    int kappa = n / 2;
    int prime = n + 1;
    while (!fedIsPrime(prime)) prime++;

    for (int k = 0, l = 0; l < n; ++k, ++l) {
        int index = 0;
        while ((index = ((k + 1) * kappa) % prime - 1) >= n) k++;
        tau[l] = tauh[index];
    }
    return n;
}

int fedTauByCycleTime(float t, float tauMax, std::vector<float> &tau) {
    int n = cvCeil(std::sqrt(3.0f * t / tauMax + 0.25f) - 0.5f - 1.0e-8f);
    float scale = 3.0f * t / (tauMax * (float)(n * (n + 1)));
    return fedTauInternal(n, scale, tauMax, tau);
}

int fedTauByProcessTime(float T, int M, float tauMax, std::vector<float> &tau) {
    return fedTauByCycleTime(T / (float)M, tauMax, tau);
}

// ---- Pyramid sizing/timing schedule, ported from Allocate_Memory_Evolution ----
// Pure sizing math, independent of pixel data — computed once, shared by both
// backends.
void allocateMemoryEvolution(int imgWidth, int imgHeight, std::vector<EvolutionLevel> &evolution,
                             std::vector<std::vector<float>> &tsteps) {
    const float smax = 10.0f * std::sqrt(2.0f);  // DESCRIPTOR_MLDB's max descriptor area factor
    int omax = kOmax;

    for (int i = 0, power = 1; i <= omax - 1; i++, power *= 2) {
        float rfactor = 1.0f / power;
        int levelHeight = (int)(imgHeight * rfactor);
        int levelWidth = (int)(imgWidth * rfactor);

        if ((levelWidth < 80 || levelHeight < 40) && i != 0) {
            omax = i;
            break;
        }

        for (int j = 0; j < kNSublevels; j++) {
            EvolutionLevel level;
            level.size = cv::Size(levelWidth, levelHeight);
            level.esigma = kSoffset * std::pow(2.f, (float)j / (float)kNSublevels + i);
            level.sigma_size = cvRound(level.esigma * kDerivativeFactor / power);
            level.octave = i;
            level.sublevel = j;
            level.octave_ratio = (float)power;
            level.border = cvRound(smax * level.sigma_size) + 1;
            evolution.push_back(level);
        }
    }

    tsteps.clear();
    for (size_t i = 1; i < evolution.size(); i++) {
        float etimePrev = 0.5f * evolution[i - 1].esigma * evolution[i - 1].esigma;
        float etimeCurr = 0.5f * evolution[i].esigma * evolution[i].esigma;
        std::vector<float> tau;
        fedTauByProcessTime(etimeCurr - etimePrev, 1, 0.25f, tau);
        tsteps.push_back(tau);
    }
}

// ---- Custom-size derivative kernels, ported from compute_derivative_kernels ----
// Real Scharr (3x3) for scale==1; AKAZE's own extended-Scharr-style kernel for
// larger sigma_size, exactly as the multiscale derivative computation needs.
void computeDerivativeKernels(cv::OutputArray kx, cv::OutputArray ky, int dx, int dy, int scale) {
    if (scale == 1) {
        cv::getDerivKernels(kx, ky, dx, dy, 0, true, CV_32F);
        return;
    }
    int ksize = 3 + 2 * (scale - 1);
    kx.create(ksize, 1, CV_32F, -1, true);
    ky.create(ksize, 1, CV_32F, -1, true);
    cv::Mat kxm = kx.getMat(), kym = ky.getMat();
    std::vector<float> kerI;

    float w = 10.0f / 3.0f;
    float norm = 1.0f / (2.0f * scale * (w + 2.0f));

    for (int k = 0; k < 2; k++) {
        cv::Mat &kernel = k == 0 ? kxm : kym;
        int order = k == 0 ? dx : dy;
        kerI.assign(ksize, 0.0f);
        if (order == 0) {
            kerI[0] = norm; kerI[ksize / 2] = w * norm; kerI[ksize - 1] = norm;
        } else if (order == 1) {
            kerI[0] = -1; kerI[ksize / 2] = 0; kerI[ksize - 1] = 1;
        }
        cv::Mat temp(kernel.rows, kernel.cols, CV_32F, kerI.data());
        temp.copyTo(kernel);
    }
}

// ---- Contrast factor, ported from AKAZEFeatures.cpp's compute_kcontrast ----
// (the histogram-percentile version AKAZE itself uses — distinct from, and not
// to be confused with, nldiffusion_functions.cpp's older compute_k_percentile).
float computeKContrast(const cv::Mat &Lx, const cv::Mat &Ly, float perc, int nbins) {
    cv::Mat modgs(Lx.rows - 2, Lx.cols - 2, CV_32F);
    const int total = modgs.cols * modgs.rows;
    float *modg = modgs.ptr<float>();
    float hmax = 0.0f;

    for (int i = 1; i < Lx.rows - 1; i++) {
        const float *lx = Lx.ptr<float>(i) + 1;
        const float *ly = Ly.ptr<float>(i) + 1;
        const int cols = Lx.cols - 2;
        for (int j = 0; j < cols; j++) {
            float dist = std::sqrt(lx[j] * lx[j] + ly[j] * ly[j]);
            *modg++ = dist;
            hmax = std::max(hmax, dist);
        }
    }
    modg = modgs.ptr<float>();
    if (hmax == 0.0f) return 0.03f;

    modgs *= (nbins - 1) / hmax;

    std::vector<int> hist(nbins, 0);
    for (int i = 0; i < total; i++) hist[(int)modg[i]]++;

    const int nthreshold = (int)((total - hist[0]) * perc);
    int nelements = 0;
    for (int k = 1; k < nbins; k++) {
        if (nelements >= nthreshold) return hmax * k / nbins;
        nelements += hist[k];
    }
    return 0.03f;
}

// ---- Perona-Malik G2 diffusivity, ported from nldiffusion_functions.cpp's pm_g2 ----
// (the only diffusivity function this port needs — cv::AKAZE::create()'s
// default, and this codebase never calls setDiffusivity).
void pmG2(const cv::Mat &Lx, const cv::Mat &Ly, cv::Mat &dst, float k) {
    dst.create(Lx.size(), Lx.type());
    const float k2inv = 1.0f / (k * k);
    for (int y = 0; y < Lx.rows; y++) {
        const float *lx = Lx.ptr<float>(y);
        const float *ly = Ly.ptr<float>(y);
        float *d = dst.ptr<float>(y);
        for (int x = 0; x < Lx.cols; x++) {
            d[x] = 1.0f / (1.0f + (lx[x] * lx[x] + ly[x] * ly[x]) * k2inv);
        }
    }
}

// ---- FED explicit-diffusion stencil step, ported from AKAZEFeatures.cpp's ----
// ---- nld_step_scalar_one_lane / non_linear_diffusion_step ----
// A five-point (a/b/c/-1/+1) forward-Euler stencil with Neumann (no-flux)
// boundaries: a border pixel simply omits the term reaching outside the
// image, rather than reading a clamped/replicated neighbour — that omission,
// not a boundary-pixel readback, is what "the boundary" means for this PDE.
// The real source's own comment calls its four literal corner pixels a
// special case "to prevent uninitialized values" rather than a considered
// boundary rule, and freezes them at exactly 0 (no partial stencil) instead
// of the 2-term sum a corner would otherwise get — replicated here rather
// than "improved," since these four pixels always sit deep inside the
// border `Find_Scale_Space_Extrema` excludes and matching real AKAZE's
// output matters more than a locally more-consistent formula.
void nldStepScalar(cv::Mat &Lt, const cv::Mat &Lf, cv::Mat &Lstep, float stepSize) {
    Lstep.create(Lt.size(), Lt.type());
    const int rows = Lt.rows, cols = Lt.cols;

    for (int y = 0; y < rows; y++) {
        const float *ltC = Lt.ptr<float>(y);
        const float *lfC = Lf.ptr<float>(y);
        const float *ltA = y > 0 ? Lt.ptr<float>(y - 1) : nullptr;
        const float *lfA = y > 0 ? Lf.ptr<float>(y - 1) : nullptr;
        const float *ltB = y < rows - 1 ? Lt.ptr<float>(y + 1) : nullptr;
        const float *lfB = y < rows - 1 ? Lf.ptr<float>(y + 1) : nullptr;
        float *dst = Lstep.ptr<float>(y);

        const bool topOrBottomRow = (y == 0 || y == rows - 1);
        for (int x = 0; x < cols; x++) {
            if (topOrBottomRow && (x == 0 || x == cols - 1)) {
                dst[x] = 0.0f;  // literal corner: frozen, matching real AKAZE
                continue;
            }
            float acc = 0.f;
            if (x < cols - 1) acc += (lfC[x] + lfC[x + 1]) * (ltC[x + 1] - ltC[x]);
            if (x > 0)        acc += (lfC[x] + lfC[x - 1]) * (ltC[x - 1] - ltC[x]);
            if (ltB)          acc += (lfC[x] + lfB[x])     * (ltB[x]     - ltC[x]);
            if (ltA)          acc += (lfC[x] + lfA[x])     * (ltA[x]     - ltC[x]);
            dst[x] = acc * stepSize;
        }
    }
}

// ---- Pyramid construction: the reference path, real cv::GaussianBlur/Scharr/resize ----
// Mirrors create_nonlinear_scale_space exactly. `img` is the CV_32F, [0,1]
// grayscale input (AKAZE's prepareInputImage output).
bool buildPyramidReference(const cv::Mat &img, std::vector<EvolutionLevel> &evolution,
                           const std::vector<std::vector<float>> &tsteps) {
    int ksize = (int)cvCeil(2.0f * (1.0f + (kSoffset - 0.8f) / 0.3f)) | 1;
    cv::GaussianBlur(img, evolution[0].Lsmooth, cv::Size(ksize, ksize), kSoffset, kSoffset,
                     cv::BORDER_REPLICATE);
    evolution[0].Lsmooth.copyTo(evolution[0].Lt);

    if (evolution.size() == 1) return true;

    cv::Mat baseSmooth, Lx0, Ly0;
    cv::GaussianBlur(img, baseSmooth, cv::Size(5, 5), 1.0f, 1.0f, cv::BORDER_REPLICATE);
    cv::Scharr(baseSmooth, Lx0, CV_32F, 1, 0, 1, 0, cv::BORDER_DEFAULT);
    cv::Scharr(baseSmooth, Ly0, CV_32F, 0, 1, 1, 0, cv::BORDER_DEFAULT);
    float kcontrast = computeKContrast(Lx0, Ly0, kKContrastPercentile, kKContrastNBins);

    cv::Mat Lx, Ly, Lflow, Lstep;
    for (size_t i = 1; i < evolution.size(); i++) {
        EvolutionLevel &e = evolution[i];
        if (e.octave > evolution[i - 1].octave) {
            cv::resize(evolution[i - 1].Lt, e.Lt, e.size, 0, 0, cv::INTER_AREA);
            kcontrast *= 0.75f;
        } else {
            evolution[i - 1].Lt.copyTo(e.Lt);
        }

        cv::GaussianBlur(e.Lt, e.Lsmooth, cv::Size(5, 5), 1.0f, 1.0f, cv::BORDER_REPLICATE);
        cv::Scharr(e.Lsmooth, Lx, CV_32F, 1, 0, 1.0, 0, cv::BORDER_DEFAULT);
        cv::Scharr(e.Lsmooth, Ly, CV_32F, 0, 1, 1.0, 0, cv::BORDER_DEFAULT);
        pmG2(Lx, Ly, Lflow, kcontrast);

        const std::vector<float> &steps = tsteps[i - 1];
        for (float tau : steps) {
            nldStepScalar(e.Lt, Lflow, Lstep, tau * 0.5f);
            e.Lt += Lstep;
        }
    }
    return true;
}

// ---- Pyramid construction: the GPU path ----
bool buildPyramidGPU(const cv::Mat &img, std::vector<EvolutionLevel> &evolution,
                     const std::vector<std::vector<float>> &tsteps) {
    GPUAkazePyramidFunc handler = gpu_ops_get_akaze_pyramid_handler();
    if (!handler) return false;
    if (evolution.size() == 1) return buildPyramidReference(img, evolution, tsteps);

    cv::Mat baseSmooth, Lx0, Ly0;
    cv::GaussianBlur(img, baseSmooth, cv::Size(5, 5), 1.0f, 1.0f, cv::BORDER_REPLICATE);
    cv::Scharr(baseSmooth, Lx0, CV_32F, 1, 0, 1, 0, cv::BORDER_DEFAULT);
    cv::Scharr(baseSmooth, Ly0, CV_32F, 0, 1, 1, 0, cv::BORDER_DEFAULT);
    const float kcontrastBase = computeKContrast(Lx0, Ly0, kKContrastPercentile, kKContrastNBins);

    const int levelCount = (int)evolution.size();
    std::vector<GPUAkazeLevelInfo> levels(levelCount);
    std::vector<int> stepCounts(levelCount, 0);
    std::vector<float> flatSteps;
    for (int i = 0; i < levelCount; i++) {
        levels[i].width = evolution[i].size.width;
        levels[i].height = evolution[i].size.height;
        levels[i].newOctave = (i > 0 && evolution[i].octave > evolution[i - 1].octave) ? 1 : 0;
        if (i > 0) {
            stepCounts[i] = (int)tsteps[i - 1].size();
            for (float tau : tsteps[i - 1]) flatSteps.push_back(tau * 0.5f);
        }
    }

    std::vector<MatWrapperRef> outLt(levelCount, nullptr), outLsmooth(levelCount, nullptr);
    MatWrapperRef imgRef = wrapReadOnly(img);
    bool ok = handler(imgRef, kSoffset, levels.data(), levelCount, stepCounts.data(),
                      flatSteps.data(), (int)flatSteps.size(), kcontrastBase,
                      outLt.data(), outLsmooth.data());
    mat_wrapper_release(imgRef);

    if (!ok) {
        for (auto ref : outLt) if (ref) mat_wrapper_release(ref);
        for (auto ref : outLsmooth) if (ref) mat_wrapper_release(ref);
        return false;
    }
    for (int i = 0; i < levelCount; i++) {
        if (!outLt[i] || !outLsmooth[i]) {
            for (auto ref : outLt) if (ref) mat_wrapper_release(ref);
            for (auto ref : outLsmooth) if (ref) mat_wrapper_release(ref);
            return false;
        }
        evolution[i].Lt = outLt[i]->mat;
        evolution[i].Lsmooth = outLsmooth[i]->mat;
        mat_wrapper_release(outLt[i]);
        mat_wrapper_release(outLsmooth[i]);
    }
    return true;
}

// ---- Multiscale derivatives + Hessian-determinant response, ported from ----
// ---- DeterminantHessianResponse ----
void computeDeterminantHessianResponse(std::vector<EvolutionLevel> &evolution) {
    for (auto &e : evolution) {
        cv::Mat DxKx, DxKy, DyKx, DyKy, Lxx, Lxy, Lyy;
        computeDerivativeKernels(DxKx, DxKy, 1, 0, e.sigma_size);
        computeDerivativeKernels(DyKx, DyKy, 0, 1, e.sigma_size);

        cv::sepFilter2D(e.Lsmooth, e.Lx, CV_32F, DxKx, DxKy);
        cv::sepFilter2D(e.Lx, Lxx, CV_32F, DxKx, DxKy);
        cv::sepFilter2D(e.Lx, Lxy, CV_32F, DyKx, DyKy);
        cv::sepFilter2D(e.Lsmooth, e.Ly, CV_32F, DyKx, DyKy);
        cv::sepFilter2D(e.Ly, Lyy, CV_32F, DyKx, DyKy);
        e.Lsmooth.release();

        const float sigmaSizeQuat = (float)((double)e.sigma_size * e.sigma_size *
                                            e.sigma_size * e.sigma_size);
        e.Ldet.create(Lxx.size(), CV_32F);
        const float *lxx = Lxx.ptr<float>(), *lxy = Lxy.ptr<float>(), *lyy = Lyy.ptr<float>();
        float *ldet = e.Ldet.ptr<float>();
        const int total = Lxx.cols * Lxx.rows;
        for (int j = 0; j < total; j++) {
            ldet[j] = (lxx[j] * lyy[j] - lxy[j] * lxy[j]) * sigmaSizeQuat;
        }
    }
}

// ---- Extrema search, ported from find_neighbor_point / FindKeypointsSameScale ----
// ---- / Find_Scale_Space_Extrema ----
bool findNeighborPoint(int x, int y, const cv::Mat &mask, int searchRadius, int &idx) {
    for (int i = y - searchRadius; i < y + searchRadius; ++i) {
        if (i < 0 || i >= mask.rows) continue;
        const uchar *curr = mask.ptr<uchar>(i);
        for (int j = x - searchRadius; j < x + searchRadius; ++j) {
            if (j < 0 || j >= mask.cols) continue;
            if (curr[j] == 0) continue;
            int dx = j - x, dy = i - y;
            if (dx * dx + dy * dy <= searchRadius * searchRadius) {
                idx = i * mask.cols + j;
                return true;
            }
        }
    }
    return false;
}

void findScaleSpaceExtrema(std::vector<EvolutionLevel> &evolution, float dthreshold,
                           std::vector<cv::Mat> &keypointsByLayer) {
    keypointsByLayer.resize(evolution.size());

    for (size_t i = 0; i < evolution.size(); i++) {
        const EvolutionLevel &e = evolution[i];
        cv::Mat &kpts = keypointsByLayer[i];
        kpts = cv::Mat::zeros(e.Ldet.size(), CV_8UC1);
        if (e.border + 1 >= e.Ldet.rows) continue;

        const int searchRadius = e.sigma_size;
        for (int y = e.border; y < e.Ldet.rows - e.border; y++) {
            const float *prev = e.Ldet.ptr<float>(y - 1);
            const float *curr = e.Ldet.ptr<float>(y);
            const float *next = e.Ldet.ptr<float>(y + 1);
            for (int x = e.border; x < e.Ldet.cols - e.border; x++) {
                const float value = curr[x];
                if (value <= dthreshold) continue;
                if (value <= curr[x - 1] || value <= curr[x + 1]) continue;
                if (value <= prev[x - 1] || value <= prev[x] || value <= prev[x + 1]) continue;
                if (value <= next[x - 1] || value <= next[x] || value <= next[x + 1]) continue;

                int idx = 0;
                if (findNeighborPoint(x, y, kpts, searchRadius, idx)) {
                    if (value > e.Ldet.at<float>(idx / kpts.cols, idx % kpts.cols)) {
                        kpts.at<uchar>(idx / kpts.cols, idx % kpts.cols) = 0;
                    } else {
                        continue;
                    }
                }
                kpts.at<uchar>(y, x) = 1;
            }
        }
    }

    // Filter with the lower (finer, smaller-index) scale level.
    for (size_t i = 1; i < keypointsByLayer.size(); i++) {
        const cv::Mat &kptsHere = keypointsByLayer[i];
        cv::Mat &kptsPrev = keypointsByLayer[i - 1];
        const int diffRatio = (int)(evolution[i].octave_ratio / evolution[i - 1].octave_ratio);
        const int searchRadius = evolution[i].sigma_size * diffRatio;

        for (int y = 0; y < kptsHere.rows; y++) {
            for (int x = 0; x < kptsHere.cols; x++) {
                if (kptsHere.at<uchar>(y, x) == 0) continue;
                int idx = 0;
                const int px = x * diffRatio, py = y * diffRatio;
                if (findNeighborPoint(px, py, kptsPrev, searchRadius, idx)) {
                    const int py2 = idx / kptsPrev.cols, px2 = idx % kptsPrev.cols;
                    if (evolution[i].Ldet.at<float>(y, x) > evolution[i - 1].Ldet.at<float>(py2, px2)) {
                        kptsPrev.at<uchar>(py2, px2) = 0;
                    }
                }
            }
        }
    }

    // Filter with the upper (coarser) scale level, the other direction.
    for (int i = (int)keypointsByLayer.size() - 2; i >= 0; i--) {
        const cv::Mat &kptsHere = keypointsByLayer[i];
        cv::Mat &kptsNext = keypointsByLayer[i + 1];
        const int diffRatio = (int)(evolution[i + 1].octave_ratio / evolution[i].octave_ratio);
        const int searchRadius = evolution[i + 1].sigma_size;

        for (int y = 0; y < kptsHere.rows; y++) {
            for (int x = 0; x < kptsHere.cols; x++) {
                if (kptsHere.at<uchar>(y, x) == 0) continue;
                int idx = 0;
                const int px = x / diffRatio, py = y / diffRatio;
                if (findNeighborPoint(px, py, kptsNext, searchRadius, idx)) {
                    const int py2 = idx / kptsNext.cols, px2 = idx % kptsNext.cols;
                    if (evolution[i].Ldet.at<float>(y, x) > evolution[i + 1].Ldet.at<float>(py2, px2)) {
                        kptsNext.at<uchar>(py2, px2) = 0;
                    }
                }
            }
        }
    }
}

// ---- Sub-pixel refinement, ported from Do_Subpixel_Refinement ----
void doSubpixelRefinement(std::vector<EvolutionLevel> &evolution,
                          std::vector<cv::Mat> &keypointsByLayer,
                          std::vector<cv::KeyPoint> &output) {
    for (size_t i = 0; i < keypointsByLayer.size(); i++) {
        const EvolutionLevel &e = evolution[i];
        const float *ldet = e.Ldet.ptr<float>();
        const float ratio = e.octave_ratio;
        const int cols = e.Ldet.cols;
        const cv::Mat &kpts = keypointsByLayer[i];

        for (int y = 0; y < kpts.rows; y++) {
            for (int x = 0; x < kpts.cols; x++) {
                if (kpts.at<uchar>(y, x) == 0) continue;

                cv::KeyPoint kp;
                kp.pt.x = x * ratio;
                kp.pt.y = y * ratio;
                kp.size = e.esigma * kDerivativeFactor;
                kp.response = ldet[y * cols + x];
                kp.octave = e.octave;
                kp.class_id = (int)i;

                float Dx = 0.5f * (ldet[y * cols + x + 1] - ldet[y * cols + x - 1]);
                float Dy = 0.5f * (ldet[(y + 1) * cols + x] - ldet[(y - 1) * cols + x]);
                float Dxx = ldet[y * cols + x + 1] + ldet[y * cols + x - 1] - 2.0f * ldet[y * cols + x];
                float Dyy = ldet[(y + 1) * cols + x] + ldet[(y - 1) * cols + x] - 2.0f * ldet[y * cols + x];
                float Dxy = 0.25f * (ldet[(y + 1) * cols + x + 1] + ldet[(y - 1) * cols + x - 1] -
                                    ldet[(y - 1) * cols + x + 1] - ldet[(y + 1) * cols + x - 1]);

                cv::Matx22f A(Dxx, Dxy, Dxy, Dyy);
                cv::Vec2f b(-Dx, -Dy);
                cv::Vec2f dst(0.f, 0.f);
                cv::solve(A, b, dst, cv::DECOMP_LU);

                float dx = dst(0), dy = dst(1);
                if (std::abs(dx) > 1.0f || std::abs(dy) > 1.0f) continue;

                kp.pt.x += dx * ratio + 0.5f * (ratio - 1.f);
                kp.pt.y += dy * ratio + 0.5f * (ratio - 1.f);
                kp.angle = 0.0f;
                kp.size *= 2.0f;
                output.push_back(kp);
            }
        }
    }
}

// ---- Orientation, ported from Sample_Derivative_Response_Radius6 / ----
// ---- quantized_counting_sort / Compute_Main_Orientation ----
void sampleDerivativeResponseRadius6(const cv::Mat &Lx, const cv::Mat &Ly, int x0, int y0,
                                     int scale, float *resX, float *resY) {
    static const float gauss25[7][7] = {
        {0.02546481f, 0.02350698f, 0.01849125f, 0.01239505f, 0.00708017f, 0.00344629f, 0.00142946f},
        {0.02350698f, 0.02169968f, 0.01706957f, 0.01144208f, 0.00653582f, 0.00318132f, 0.00131956f},
        {0.01849125f, 0.01706957f, 0.01342740f, 0.00900066f, 0.00514126f, 0.00250252f, 0.00103800f},
        {0.01239505f, 0.01144208f, 0.00900066f, 0.00603332f, 0.00344629f, 0.00167749f, 0.00069579f},
        {0.00708017f, 0.00653582f, 0.00514126f, 0.00344629f, 0.00196855f, 0.00095820f, 0.00039744f},
        {0.00344629f, 0.00318132f, 0.00250252f, 0.00167749f, 0.00095820f, 0.00046640f, 0.00019346f},
        {0.00142946f, 0.00131956f, 0.00103800f, 0.00069579f, 0.00039744f, 0.00019346f, 0.00008024f}
    };
    int k = 0;
    for (int i = -6; i <= 6; ++i) {
        for (int j = -6; j <= 6; ++j) {
            if (i * i + j * j >= 36) continue;
            int y = y0 + i * scale, x = x0 + j * scale;
            float w = gauss25[std::abs(i)][std::abs(j)];
            resX[k] = w * Lx.at<float>(y, x);
            resY[k] = w * Ly.at<float>(y, x);
            k++;
        }
    }
}

void quantizedCountingSort(const float a[], int n, float quantum, int nkeys,
                           int idx[], int cum[]) {
    std::memset(cum, 0, sizeof(cum[0]) * (nkeys + 1));
    for (int i = 0; i < n; i++) {
        int b = (int)(a[i] / quantum);
        if (b < 0 || b >= nkeys) b = 0;
        cum[b]++;
    }
    for (int i = 1; i <= nkeys; i++) cum[i] += cum[i - 1];
    for (int i = 0; i < n; i++) {
        int b = (int)(a[i] / quantum);
        if (b < 0 || b >= nkeys) b = 0;
        idx[--cum[b]] = i;
    }
}

void computeMainOrientation(cv::KeyPoint &kpt, const std::vector<EvolutionLevel> &evolution) {
    const EvolutionLevel &e = evolution[kpt.class_id];
    int scale = cvRound(0.5f * kpt.size / e.octave_ratio);
    int x0 = cvRound(kpt.pt.x / e.octave_ratio);
    int y0 = cvRound(kpt.pt.y / e.octave_ratio);

    const int angSize = 109;
    float resX[angSize], resY[angSize];
    sampleDerivativeResponseRadius6(e.Lx, e.Ly, x0, y0, scale, resX, resY);

    float ang[angSize];
    cv::hal::fastAtan2(resY, resX, ang, angSize, false);

    const int slices = 42;
    const float angStep = (float)(2.0 * CV_PI / slices);
    int slice[slices + 1];
    int sortedIdx[angSize];
    quantizedCountingSort(ang, angSize, angStep, slices, sortedIdx, slice);

    const int win = 7;
    float maxX = 0.f, maxY = 0.f;
    for (int i = slice[0]; i < slice[win]; i++) {
        maxX += resX[sortedIdx[i]];
        maxY += resY[sortedIdx[i]];
    }
    float maxNorm = maxX * maxX + maxY * maxY;

    for (int sn = 1; sn <= slices - win; sn++) {
        if (slice[sn] == slice[sn - 1] && slice[sn + win] == slice[sn + win - 1]) continue;
        float sumX = 0.f, sumY = 0.f;
        for (int i = slice[sn]; i < slice[sn + win]; i++) {
            sumX += resX[sortedIdx[i]];
            sumY += resY[sortedIdx[i]];
        }
        float norm = sumX * sumX + sumY * sumY;
        if (norm > maxNorm) { maxNorm = norm; maxX = sumX; maxY = sumY; }
    }

    for (int sn = slices - win + 1; sn < slices; sn++) {
        int remain = sn + win - slices;
        if (slice[sn] == slice[sn - 1] && slice[remain] == slice[remain - 1]) continue;
        float sumX = 0.f, sumY = 0.f;
        for (int i = slice[sn]; i < slice[slices]; i++) {
            sumX += resX[sortedIdx[i]];
            sumY += resY[sortedIdx[i]];
        }
        for (int i = slice[0]; i < slice[remain]; i++) {
            sumX += resX[sortedIdx[i]];
            sumY += resY[sortedIdx[i]];
        }
        float norm = sumX * sumX + sumY * sumY;
        if (norm > maxNorm) { maxNorm = norm; maxX = sumX; maxY = sumY; }
    }

    kpt.angle = cv::fastAtan2(maxY, maxX);
}

// ---- MLDB (full, 486-bit) descriptor, ported from MLDB_Fill_Values / ----
// ---- MLDB_Binary_Comparisons / Get_MLDB_Full_Descriptor ----
void mldbFillValues(const std::vector<EvolutionLevel> &evolution, float *values, int sampleStep,
                    int level, float xf, float yf, float co, float si, float scale) {
    const cv::Mat &Lx = evolution[level].Lx;
    const cv::Mat &Ly = evolution[level].Ly;
    const cv::Mat &Lt = evolution[level].Lt;

    int valpos = 0;
    for (int i = -kDescriptorPatternSize; i < kDescriptorPatternSize; i += sampleStep) {
        for (int j = -kDescriptorPatternSize; j < kDescriptorPatternSize; j += sampleStep) {
            float di = 0.f, dx = 0.f, dy = 0.f;
            int nsamples = 0;
            for (int k = i; k < i + sampleStep; k++) {
                for (int l = j; l < j + sampleStep; l++) {
                    float sampleY = yf + (l * co * scale + k * si * scale);
                    float sampleX = xf + (-l * si * scale + k * co * scale);
                    int y1 = cvRound(sampleY), x1 = cvRound(sampleX);
                    if (y1 < 0 || y1 >= Lt.rows || x1 < 0 || x1 >= Lt.cols) continue;

                    di += Lt.at<float>(y1, x1);
                    float rx = Lx.at<float>(y1, x1);
                    float ry = Ly.at<float>(y1, x1);
                    float rry = rx * co + ry * si;
                    float rrx = -rx * si + ry * co;
                    dx += rrx;
                    dy += rry;
                    nsamples++;
                }
            }
            if (nsamples > 0) {
                const float inv = 1.0f / nsamples;
                di *= inv; dx *= inv; dy *= inv;
            }
            values[valpos] = di;
            values[valpos + 1] = dx;
            values[valpos + 2] = dy;
            valpos += kDescriptorChannels;
        }
    }
}

void mldbBinaryComparisons(float *values, unsigned char *desc, int count, int &dpos) {
    // CV_TOGGLE_FLT (opencv2/core/private.hpp): flips every bit but the sign
    // when the float's bit pattern reads negative as an int, so plain integer
    // comparison below matches float ordering — not the more familiar
    // "flip sign bit if positive, flip all bits if negative" radix-sort trick.
    int *ivalues = (int *)values;
    for (int i = 0; i < count * kDescriptorChannels; i++) {
        ivalues[i] = ivalues[i] ^ (ivalues[i] < 0 ? 0x7fffffff : 0);
    }
    for (int pos = 0; pos < kDescriptorChannels; pos++) {
        for (int i = 0; i < count; i++) {
            int ival = ivalues[kDescriptorChannels * i + pos];
            for (int j = i + 1; j < count; j++) {
                if (ival > ivalues[kDescriptorChannels * j + pos]) {
                    desc[dpos >> 3] |= (1 << (dpos & 7));
                }
                dpos++;
            }
        }
    }
}

void getMLDBFullDescriptor(const std::vector<EvolutionLevel> &evolution, const cv::KeyPoint &kpt,
                           unsigned char *desc, int descSize) {
    float values[16 * 3];
    const int patternSize = kDescriptorPatternSize;
    const int sampleStep[3] = {patternSize, cv::divUp(patternSize * 2, 3), cv::divUp(patternSize, 2)};

    float ratio = (float)(1 << kpt.octave);
    float scale = (float)cvRound(0.5f * kpt.size / ratio);
    float xf = kpt.pt.x / ratio;
    float yf = kpt.pt.y / ratio;
    float angle = kpt.angle * (float)(CV_PI / 180.0);
    float co = std::cos(angle), si = std::sin(angle);

    std::memset(desc, 0, descSize);
    int dpos = 0;
    for (int lvl = 0; lvl < 3; lvl++) {
        int valCount = (lvl + 2) * (lvl + 2);
        mldbFillValues(evolution, values, sampleStep[lvl], kpt.class_id, xf, yf, co, si, scale);
        mldbBinaryComparisons(values, desc, valCount, dpos);
    }
}

void computeDescriptors(const std::vector<EvolutionLevel> &evolution,
                        const std::vector<cv::KeyPoint> &keypoints, cv::Mat &descriptors) {
    const int descBits = kMLDBBits;
    const int descSize = cv::divUp(descBits, 8);
    descriptors.create((int)keypoints.size(), descSize, CV_8UC1);
    for (size_t i = 0; i < keypoints.size(); i++) {
        getMLDBFullDescriptor(evolution, keypoints[i], descriptors.ptr<unsigned char>((int)i), descSize);
    }
}

// The shared orchestration both backends use — mirrors AKAZE_Impl::detectAndCompute
// followed by this codebase's own retainBest cap (ImageAligner.cpp), collapsed
// into a single pyramid build (see the file header for why that is safe).
bool detectAndComputeImpl(const cv::Mat &img8u, const cv::Mat &mask, int maxKeypoints,
                          float threshold, bool useGPU, std::vector<cv::KeyPoint> &keypoints,
                          cv::Mat &descriptors) {
    cv::Mat grayFloat;
    img8u.convertTo(grayFloat, CV_32F, 1.0 / 255.0, 0.0);

    std::vector<EvolutionLevel> evolution;
    std::vector<std::vector<float>> tsteps;
    allocateMemoryEvolution(grayFloat.cols, grayFloat.rows, evolution, tsteps);
    if (evolution.empty()) return false;

    bool built = useGPU ? buildPyramidGPU(grayFloat, evolution, tsteps)
                        : buildPyramidReference(grayFloat, evolution, tsteps);
    if (!built) return false;

    computeDeterminantHessianResponse(evolution);

    std::vector<cv::Mat> keypointsByLayer;
    findScaleSpaceExtrema(evolution, threshold, keypointsByLayer);

    keypoints.clear();
    doSubpixelRefinement(evolution, keypointsByLayer, keypoints);

    for (auto &kp : keypoints) computeMainOrientation(kp, evolution);

    if (!mask.empty()) cv::KeyPointsFilter::runByPixelsMask(keypoints, mask);
    if (maxKeypoints > 0) cv::KeyPointsFilter::retainBest(keypoints, maxKeypoints);

    keypoints.shrink_to_fit();
    computeDescriptors(evolution, keypoints, descriptors);
    return true;
}

} // namespace

namespace star_akaze {

bool akazeDetectAndComputeReference(const cv::Mat &img8u, const cv::Mat &mask, int maxKeypoints,
                                    float threshold, std::vector<cv::KeyPoint> &keypoints,
                                    cv::Mat &descriptors) {
    return detectAndComputeImpl(img8u, mask, maxKeypoints, threshold, /*useGPU=*/false,
                                keypoints, descriptors);
}

bool akazeDetectAndComputeGPU(const cv::Mat &img8u, const cv::Mat &mask, int maxKeypoints,
                              float threshold, std::vector<cv::KeyPoint> &keypoints,
                              cv::Mat &descriptors) {
    return detectAndComputeImpl(img8u, mask, maxKeypoints, threshold, /*useGPU=*/true,
                                keypoints, descriptors);
}

} // namespace star_akaze
