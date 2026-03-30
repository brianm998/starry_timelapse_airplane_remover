// RandomWalkerHorizon.cpp — Edge-aware Random Walker horizon detection
//
// Implements a Random Walker segmentation algorithm optimised for horizon
// detection in astronomical timelapse images.  The algorithm:
//
//   1. Converts the image to grayscale, crops to the ROI around the user's
//      painted band, and downsamples to a working resolution.
//   2. Computes edge weights: w(i,j) = exp(-beta * |g_i - g_j|^2), where
//      strong gradients (horizon edges) produce near-zero weights (barriers).
//   3. Seeds: above the band = sky (prob=1), below = ground (prob=0).
//   4. Solves for the unknown region via Gauss-Seidel iteration on the
//      graph Laplacian — no explicit matrix assembly required.
//   5. Extracts per-column horizon Y by scanning upward from ground until
//      prob >= 0.5 (the sky/ground boundary).
//   6. Snaps to the nearest strong vertical edge, then median-filters.
//   7. Upsamples back to the original image resolution.
//
// Stars are suppressed by a Gaussian pre-blur: a 1-3 px star is smeared
// across ~5-7 px, drastically reducing its gradient magnitude, while the
// spatially extended horizon edge retains ~90% of its strength.

#include "PixelatedImageBridge.h"
#include "MatWrapper.h"
#include "MatWrapperImpl.hpp"
#include "logging_impl.hpp"

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>

#include <vector>
#include <algorithm>
#include <cmath>
#include <cstring>

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static cv::Mat toGray32F(const cv::Mat& input) {
    cv::Mat gray;
    if (input.channels() == 4)
        cv::cvtColor(input, gray, cv::COLOR_BGRA2GRAY);
    else if (input.channels() == 3)
        cv::cvtColor(input, gray, cv::COLOR_BGR2GRAY);
    else
        gray = input;

    cv::Mat f;
    if (gray.depth() == CV_8U)
        gray.convertTo(f, CV_32F, 1.0 / 255.0);
    else if (gray.depth() == CV_16U)
        gray.convertTo(f, CV_32F, 1.0 / 65535.0);
    else if (gray.depth() == CV_32F)
        f = gray;
    else
        gray.convertTo(f, CV_32F);
    return f;
}

// Compute edge weights between horizontally and vertically adjacent pixels.
// wRight(r,c) = weight between (r,c) and (r,c+1).
// wDown(r,c)  = weight between (r,c) and (r+1,c).
static void computeEdgeWeights(const cv::Mat& gray, double beta,
                               cv::Mat& wRight, cv::Mat& wDown) {
    int rows = gray.rows, cols = gray.cols;
    wRight = cv::Mat::zeros(rows, cols, CV_32F);
    wDown  = cv::Mat::zeros(rows, cols, CV_32F);

    for (int r = 0; r < rows; r++) {
        const float* g = gray.ptr<float>(r);
        float* wr = wRight.ptr<float>(r);
        float* wd = wDown.ptr<float>(r);
        const float* gNext = (r + 1 < rows) ? gray.ptr<float>(r + 1) : nullptr;

        for (int c = 0; c < cols; c++) {
            if (c + 1 < cols) {
                float d = g[c] - g[c + 1];
                wr[c] = std::exp(-(float)beta * d * d);
            }
            if (gNext) {
                float d = g[c] - gNext[c];
                wd[c] = std::exp(-(float)beta * d * d);
            }
        }
    }
}

// In-place Gauss-Seidel iteration.
// Updates only pixels where seedMask == 0.
// Returns max absolute change (convergence metric).
static float gaussSeidelIteration(cv::Mat& prob, const cv::Mat& seedMask,
                                  const cv::Mat& wRight, const cv::Mat& wDown) {
    int rows = prob.rows, cols = prob.cols;
    float maxDelta = 0.0f;

    for (int r = 0; r < rows; r++) {
        float* p = prob.ptr<float>(r);
        const uchar* s = seedMask.ptr<uchar>(r);
        const float* wr = wRight.ptr<float>(r);
        const float* wd = wDown.ptr<float>(r);

        // Pointers to adjacent rows
        const float* pUp   = (r > 0)         ? prob.ptr<float>(r - 1)  : nullptr;
        const float* pDown = (r + 1 < rows)  ? prob.ptr<float>(r + 1)  : nullptr;
        const float* wdUp  = (r > 0)         ? wDown.ptr<float>(r - 1) : nullptr;

        for (int c = 0; c < cols; c++) {
            if (s[c] != 0) continue;  // seeded — locked

            float sumW = 0.0f;
            float sumWP = 0.0f;

            // Left neighbor
            if (c > 0) {
                float w = wRight.ptr<float>(r)[c - 1];
                sumW += w;
                sumWP += w * p[c - 1];
            }
            // Right neighbor
            if (c + 1 < cols) {
                float w = wr[c];
                sumW += w;
                sumWP += w * p[c + 1];
            }
            // Up neighbor
            if (pUp) {
                float w = wdUp[c];
                sumW += w;
                sumWP += w * pUp[c];
            }
            // Down neighbor
            if (pDown) {
                float w = wd[c];
                sumW += w;
                sumWP += w * pDown[c];
            }

            if (sumW > 1e-12f) {
                float newVal = sumWP / sumW;
                float delta = std::abs(newVal - p[c]);
                if (delta > maxDelta) maxDelta = delta;
                p[c] = newVal;
            }
        }
    }
    return maxDelta;
}

// Scale an array of ints from full-res column indices to working-res.
// -1 values are preserved.
static std::vector<int> scaleColumnArray(const int* src, int srcWidth,
                                          int dstWidth, double scaleX,
                                          double scaleY, int roiTop) {
    std::vector<int> dst(dstWidth, -1);
    for (int wc = 0; wc < dstWidth; wc++) {
        int fc = std::min((int)(wc / scaleX + 0.5), srcWidth - 1);
        int val = src[fc];
        if (val >= 0) {
            dst[wc] = std::max(0, (int)((val - roiTop) * scaleY + 0.5));
        }
    }
    return dst;
}

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

void pib_random_walker_horizon(MatWrapperRef img,
                               const int *bandTopY,
                               const int *bandBottomY,
                               const int *skyFloorY,
                               const int *groundCeilY,
                               int width,
                               double beta,
                               int maxWorkingWidth,
                               int *outHorizonY) {
    // Default output: all -1 (no result)
    std::memset(outHorizonY, -1, width * sizeof(int));

    if (!img || !bandTopY || !bandBottomY || !skyFloorY || !groundCeilY || width <= 0) {
        Log_e("pib_random_walker_horizon: invalid arguments");
        return;
    }

    try {
        const cv::Mat& input = img->mat;
        int imgH = input.rows;
        int imgW = input.cols;

        if (imgW != width) {
            Log_e("pib_random_walker_horizon: width mismatch (%d vs %d)", width, imgW);
            return;
        }

        // ── 1. Determine ROI ─────────────────────────────────────────────

        // Find the global extent of the painted band.
        int globalTop = imgH, globalBot = 0;
        int colLeft = imgW, colRight = -1;
        for (int c = 0; c < width; c++) {
            if (bandTopY[c] < 0 || bandBottomY[c] < 0) continue;
            int skyF = skyFloorY[c] >= 0 ? skyFloorY[c] : bandTopY[c];
            int gndC = groundCeilY[c] >= 0 ? groundCeilY[c] : bandBottomY[c];
            if (skyF < globalTop) globalTop = skyF;
            if (gndC > globalBot) globalBot = gndC;
            if (c < colLeft) colLeft = c;
            if (c > colRight) colRight = c;
        }

        if (colLeft > colRight || globalTop >= globalBot) {
            Log_w("pib_random_walker_horizon: no valid painted columns");
            return;
        }

        // Add margin above sky seeds and below ground seeds.
        int bandHeight = globalBot - globalTop;
        int margin = std::max(20, bandHeight / 5);
        int roiTop = std::max(0, globalTop - margin);
        int roiBot = std::min(imgH - 1, globalBot + margin);
        int roiH   = roiBot - roiTop + 1;

        Log_i("pib_random_walker_horizon: ROI [%d..%d] (%d rows), "
              "columns [%d..%d], beta=%.1f",
              roiTop, roiBot, roiH, colLeft, colRight, beta);

        // ── 2. Convert to grayscale, crop ROI ────────────────────────────

        cv::Mat grayFull = toGray32F(input);
        cv::Mat grayROI = grayFull(cv::Range(roiTop, roiBot + 1), cv::Range::all()).clone();

        // ── 3. Downsample to working resolution ──────────────────────────

        double scaleX = 1.0, scaleY = 1.0;
        int workW = imgW, workH = roiH;

        if (imgW > maxWorkingWidth) {
            scaleX = (double)maxWorkingWidth / imgW;
            scaleY = scaleX;  // uniform scale
            workW = maxWorkingWidth;
            workH = std::max(2, (int)(roiH * scaleY + 0.5));
            cv::resize(grayROI, grayROI, cv::Size(workW, workH), 0, 0, cv::INTER_AREA);
        }

        Log_d("pib_random_walker_horizon: working size %dx%d (scale %.3f)",
              workW, workH, scaleX);

        // ── 4. Gaussian blur to suppress stars ───────────────────────────

        cv::GaussianBlur(grayROI, grayROI, cv::Size(5, 5), 1.2);

        // ── 5. Compute edge weights ──────────────────────────────────────

        cv::Mat wRight, wDown;
        computeEdgeWeights(grayROI, beta, wRight, wDown);

        // ── 6. Scale per-column arrays to working resolution ─────────────

        auto wSkyFloor   = scaleColumnArray(skyFloorY,   width, workW, scaleX, scaleY, roiTop);
        auto wGndCeiling = scaleColumnArray(groundCeilY, width, workW, scaleX, scaleY, roiTop);
        auto wBandTop    = scaleColumnArray(bandTopY,    width, workW, scaleX, scaleY, roiTop);
        auto wBandBot    = scaleColumnArray(bandBottomY, width, workW, scaleX, scaleY, roiTop);

        // ── 7. Build seed mask and initial probabilities ─────────────────

        cv::Mat prob(workH, workW, CV_32F, cv::Scalar(0.5f));
        cv::Mat seedMask(workH, workW, CV_8UC1, cv::Scalar(0));

        for (int c = 0; c < workW; c++) {
            if (wBandTop[c] < 0 || wBandBot[c] < 0) {
                // Unpainted column: mark entire column as seeded (won't participate)
                for (int r = 0; r < workH; r++) {
                    seedMask.at<uchar>(r, c) = 1;
                    prob.at<float>(r, c) = 0.5f;
                }
                continue;
            }

            int skyF = std::max(0, wSkyFloor[c]);
            int gndC = std::min(workH - 1, wGndCeiling[c]);

            // Sky seeds: from top of ROI to sky floor
            for (int r = 0; r <= skyF && r < workH; r++) {
                prob.at<float>(r, c) = 1.0f;
                seedMask.at<uchar>(r, c) = 1;
            }

            // Ground seeds: from ground ceiling to bottom of ROI
            for (int r = gndC; r < workH; r++) {
                prob.at<float>(r, c) = 0.0f;
                seedMask.at<uchar>(r, c) = 1;
            }
        }

        // ── 8. Multi-scale Gauss-Seidel solve ────────────────────────────

        // Coarse solve (half resolution)
        if (workW > 64 && workH > 16) {
            int coarseW = workW / 2;
            int coarseH = workH / 2;

            cv::Mat coarseProb, coarseSeed, coarseWR, coarseWD;
            cv::resize(prob,     coarseProb, cv::Size(coarseW, coarseH), 0, 0, cv::INTER_NEAREST);
            cv::resize(seedMask, coarseSeed, cv::Size(coarseW, coarseH), 0, 0, cv::INTER_NEAREST);

            // Recompute edge weights at coarse resolution
            cv::Mat coarseGray;
            cv::resize(grayROI, coarseGray, cv::Size(coarseW, coarseH), 0, 0, cv::INTER_AREA);
            computeEdgeWeights(coarseGray, beta, coarseWR, coarseWD);

            // Iterate at coarse level
            for (int iter = 0; iter < 100; iter++) {
                float maxDelta = gaussSeidelIteration(coarseProb, coarseSeed, coarseWR, coarseWD);
                if (maxDelta < 1e-3f) {
                    Log_d("pib_random_walker_horizon: coarse converged at iter %d (delta %.6f)",
                          iter, maxDelta);
                    break;
                }
            }

            // Upsample coarse solution as initial guess for fine level.
            // Only overwrite non-seeded pixels.
            cv::Mat upsampled;
            cv::resize(coarseProb, upsampled, cv::Size(workW, workH), 0, 0, cv::INTER_LINEAR);
            for (int r = 0; r < workH; r++) {
                float* p = prob.ptr<float>(r);
                const float* u = upsampled.ptr<float>(r);
                const uchar* s = seedMask.ptr<uchar>(r);
                for (int c = 0; c < workW; c++) {
                    if (s[c] == 0) p[c] = u[c];
                }
            }
        }

        // Fine solve
        for (int iter = 0; iter < 200; iter++) {
            float maxDelta = gaussSeidelIteration(prob, seedMask, wRight, wDown);
            if (maxDelta < 1e-4f) {
                Log_d("pib_random_walker_horizon: fine converged at iter %d (delta %.6f)",
                      iter, maxDelta);
                break;
            }
        }

        // ── 9. Extract per-column horizon Y (scan UP from ground) ────────

        std::vector<int> workHorizon(workW, -1);
        for (int c = 0; c < workW; c++) {
            if (wBandBot[c] < 0) continue;

            int gndRow = std::min(workH - 1, wGndCeiling[c]);
            int skyRow = std::max(0, wSkyFloor[c]);

            // Scan upward from ground ceiling to sky floor.
            // Find the first row (going up) where prob >= 0.5.
            int horizonR = skyRow;  // default: top of unknown region
            for (int r = gndRow; r >= skyRow; r--) {
                if (prob.at<float>(r, c) >= 0.5f) {
                    horizonR = r;
                    break;
                }
            }
            workHorizon[c] = horizonR;
        }

        // ── 10. Edge snapping ────────────────────────────────────────────
        // Snap each column's horizon to the nearest strong vertical edge
        // within a small window.

        cv::Mat sobelY;
        cv::Sobel(grayROI, sobelY, CV_32F, 0, 1, 3);
        // Use absolute value of vertical gradient
        sobelY = cv::abs(sobelY);

        int snapRadius = std::max(3, (int)(5 * scaleY + 0.5));  // ~5 pixels at original res
        float snapThreshold = 0.03f;  // minimum gradient to snap to

        for (int c = 0; c < workW; c++) {
            int hr = workHorizon[c];
            if (hr < 0) continue;

            int bestR = hr;
            float bestGrad = 0.0f;
            int lo = std::max(0, hr - snapRadius);
            int hi = std::min(workH - 1, hr + snapRadius);
            for (int r = lo; r <= hi; r++) {
                float g = sobelY.at<float>(r, c);
                if (g > bestGrad) {
                    bestGrad = g;
                    bestR = r;
                }
            }
            if (bestGrad >= snapThreshold) {
                workHorizon[c] = bestR;
            }
        }

        // ── 11. Median filter at working resolution ──────────────────────

        int medW = std::max(5, workW / 100);  // ~1% of width, minimum 5
        std::vector<int> smoothed = workHorizon;
        for (int c = 0; c < workW; c++) {
            if (workHorizon[c] < 0) continue;
            int lo = std::max(0, c - medW);
            int hi = std::min(workW - 1, c + medW);
            std::vector<int> window;
            window.reserve(hi - lo + 1);
            for (int j = lo; j <= hi; j++) {
                if (workHorizon[j] >= 0) window.push_back(workHorizon[j]);
            }
            if (!window.empty()) {
                std::nth_element(window.begin(),
                                 window.begin() + window.size() / 2,
                                 window.end());
                smoothed[c] = window[window.size() / 2];
            }
        }

        // ── 12. Upsample horizon Y to full image resolution ─────────────

        for (int fc = 0; fc < width; fc++) {
            // Map full-res column to working column
            double wc_f = fc * scaleX;
            int wc0 = (int)wc_f;
            int wc1 = std::min(wc0 + 1, workW - 1);
            double t = wc_f - wc0;

            int y0 = smoothed[wc0];
            int y1 = smoothed[wc1];

            if (y0 < 0 && y1 < 0) {
                outHorizonY[fc] = -1;
            } else if (y0 < 0) {
                outHorizonY[fc] = roiTop + (int)(y1 / scaleY + 0.5);
            } else if (y1 < 0) {
                outHorizonY[fc] = roiTop + (int)(y0 / scaleY + 0.5);
            } else {
                double interp = (1.0 - t) * y0 + t * y1;
                outHorizonY[fc] = roiTop + (int)(interp / scaleY + 0.5);
            }
        }

        // Fill gaps via linear interpolation between painted columns
        int lastValid = -1;
        int lastY = -1;
        for (int c = 0; c < width; c++) {
            if (outHorizonY[c] >= 0) {
                if (lastValid >= 0 && lastValid < c - 1) {
                    // Interpolate the gap
                    int span = c - lastValid;
                    for (int g = lastValid + 1; g < c; g++) {
                        double t2 = (double)(g - lastValid) / span;
                        outHorizonY[g] = (int)(lastY * (1.0 - t2) +
                                               outHorizonY[c] * t2 + 0.5);
                    }
                }
                lastValid = c;
                lastY = outHorizonY[c];
            }
        }

        Log_i("pib_random_walker_horizon: done, columns [%d..%d]", colLeft, colRight);

    } KHT_CATCH_LOG("pib_random_walker_horizon")
}
