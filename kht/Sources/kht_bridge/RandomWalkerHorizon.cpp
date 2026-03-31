// RandomWalkerHorizon.cpp — Edge-aware Random Walker horizon detection
//
// Implements a Random Walker segmentation with a **data term** (color model)
// optimised for horizon detection in astronomical timelapse images.
//
// The standard Random Walker (Grady 2006) uses only pairwise edge weights,
// producing a probability field whose 0.5 contour sits at the geodesic
// midpoint between seed sets.  For horizons this is insufficient — the
// boundary just averages the band rather than snapping to the ridgeline.
//
// The extended formulation adds a per-pixel data/prior term:
//
//   prob(r,c) = [ Σ w_ij·prob(j) + λ·dataTerm(r,c) ] / [ Σ w_ij + λ ]
//
// where dataTerm ∈ [0,1] is the probability of "sky" based on the pixel's
// CIE L*a*b* colour distance to sky vs ground centroids (SIOX-like).
// This combines:
//   • Random Walker's edge awareness (strong gradients resist crossing)
//   • SIOX's colour modelling (knows what sky/ground look like)
//
// Additional horizon-specific enhancements:
//   • LAB colour-space edge weights (more distinctive than grayscale)
//   • Anisotropic weighting (vertical edges boosted for horizontal horizons)
//   • Gentle star suppression via small median blur (preserves horizon edge)
//   • Sobel edge snapping with wider search window
//   • Multi-scale solve for performance on large images

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

// Convert to LAB float32 (3-channel, L in [0,100], a/b in ~[-128,127])
static cv::Mat toLAB32F(const cv::Mat& input) {
    cv::Mat bgr8;

    // First ensure 8-bit BGR
    if (input.channels() == 4) {
        cv::Mat temp;
        cv::cvtColor(input, temp, cv::COLOR_BGRA2BGR);
        if (temp.depth() != CV_8U) {
            double minVal, maxVal;
            cv::minMaxLoc(temp.reshape(1), &minVal, &maxVal);
            if (maxVal > 255.0)
                temp.convertTo(bgr8, CV_8UC3, 255.0 / maxVal);
            else
                temp.convertTo(bgr8, CV_8UC3);
        } else {
            bgr8 = temp;
        }
    } else if (input.channels() == 3) {
        if (input.depth() != CV_8U) {
            double minVal, maxVal;
            cv::minMaxLoc(input.reshape(1), &minVal, &maxVal);
            if (maxVal > 255.0)
                input.convertTo(bgr8, CV_8UC3, 255.0 / maxVal);
            else
                input.convertTo(bgr8, CV_8UC3);
        } else {
            bgr8 = input;
        }
    } else {
        // Grayscale → fake BGR
        cv::Mat gray = input;
        if (gray.depth() != CV_8U) {
            double minVal, maxVal;
            cv::minMaxLoc(gray, &minVal, &maxVal);
            if (maxVal > 255.0)
                gray.convertTo(gray, CV_8U, 255.0 / maxVal);
            else
                gray.convertTo(gray, CV_8U);
        }
        cv::cvtColor(gray, bgr8, cv::COLOR_GRAY2BGR);
    }

    cv::Mat lab;
    cv::cvtColor(bgr8, lab, cv::COLOR_BGR2Lab);

    cv::Mat labF;
    lab.convertTo(labF, CV_32FC3);  // L in [0,255], a/b in [0,255] (OpenCV convention)
    return labF;
}

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

// Compute edge weights using LAB colour distance.
// Anisotropic: vertical edges (wDown) use a boosted beta to make
// horizontal boundaries (horizons) harder to cross.
static void computeEdgeWeightsLAB(const cv::Mat& lab, double beta,
                                  double verticalBoost,
                                  cv::Mat& wRight, cv::Mat& wDown) {
    int rows = lab.rows, cols = lab.cols;
    wRight = cv::Mat::zeros(rows, cols, CV_32F);
    wDown  = cv::Mat::zeros(rows, cols, CV_32F);

    float betaH = (float)beta;
    float betaV = (float)(beta * verticalBoost);

    for (int r = 0; r < rows; r++) {
        const cv::Vec3f* row = lab.ptr<cv::Vec3f>(r);
        float* wr = wRight.ptr<float>(r);
        float* wd = wDown.ptr<float>(r);
        const cv::Vec3f* rowNext = (r + 1 < rows) ? lab.ptr<cv::Vec3f>(r + 1) : nullptr;

        for (int c = 0; c < cols; c++) {
            if (c + 1 < cols) {
                cv::Vec3f d = row[c] - row[c + 1];
                float dist2 = d[0]*d[0] + d[1]*d[1] + d[2]*d[2];
                // Normalise: L in [0,255], a/b in [0,255] in OpenCV LAB
                // Max dist² ≈ 3 * 255² ≈ 195075.  Scale to [0,~1] range.
                wr[c] = std::exp(-betaH * dist2 / 65025.0f);
            }
            if (rowNext) {
                cv::Vec3f d = row[c] - rowNext[c];
                float dist2 = d[0]*d[0] + d[1]*d[1] + d[2]*d[2];
                // Boosted beta for vertical edges → horizontal boundaries
                // are harder to cross.
                wd[c] = std::exp(-betaV * dist2 / 65025.0f);
            }
        }
    }
}

// Compute per-pixel data term: probability of being sky based on LAB
// colour distance to sky vs ground centroids.
// Returns a CV_32F image in [0,1] where 1.0 = sky, 0.0 = ground.
static cv::Mat computeDataTerm(const cv::Mat& lab,
                               const cv::Vec3f& skyCentroid,
                               const cv::Vec3f& gndCentroid) {
    int rows = lab.rows, cols = lab.cols;
    cv::Mat data(rows, cols, CV_32F);

    for (int r = 0; r < rows; r++) {
        const cv::Vec3f* labRow = lab.ptr<cv::Vec3f>(r);
        float* dataRow = data.ptr<float>(r);
        for (int c = 0; c < cols; c++) {
            cv::Vec3f dSky = labRow[c] - skyCentroid;
            cv::Vec3f dGnd = labRow[c] - gndCentroid;
            float distSky = std::sqrt(dSky[0]*dSky[0] + dSky[1]*dSky[1] + dSky[2]*dSky[2]);
            float distGnd = std::sqrt(dGnd[0]*dGnd[0] + dGnd[1]*dGnd[1] + dGnd[2]*dGnd[2]);
            float total = distSky + distGnd;
            // P(sky) = distGnd / (distSky + distGnd)
            dataRow[c] = (total > 1e-6f) ? (distGnd / total) : 0.5f;
        }
    }
    return data;
}

// Gauss-Seidel iteration WITH data term.
// For each unknown pixel:
//   prob = (Σ w·prob_neighbor + lambda·dataTerm) / (Σ w + lambda)
static float gaussSeidelWithData(cv::Mat& prob, const cv::Mat& seedMask,
                                 const cv::Mat& wRight, const cv::Mat& wDown,
                                 const cv::Mat& dataTerm, float lambda) {
    int rows = prob.rows, cols = prob.cols;
    float maxDelta = 0.0f;

    for (int r = 0; r < rows; r++) {
        float* p = prob.ptr<float>(r);
        const uchar* s = seedMask.ptr<uchar>(r);
        const float* wr = wRight.ptr<float>(r);
        const float* wd = wDown.ptr<float>(r);
        const float* dt = dataTerm.ptr<float>(r);

        const float* pUp   = (r > 0)        ? prob.ptr<float>(r - 1)  : nullptr;
        const float* pDown = (r + 1 < rows) ? prob.ptr<float>(r + 1)  : nullptr;
        const float* wdUp  = (r > 0)        ? wDown.ptr<float>(r - 1) : nullptr;

        for (int c = 0; c < cols; c++) {
            if (s[c] != 0) continue;

            float sumW = 0.0f;
            float sumWP = 0.0f;

            // Left
            if (c > 0) {
                float w = wRight.ptr<float>(r)[c - 1];
                sumW += w;  sumWP += w * p[c - 1];
            }
            // Right
            if (c + 1 < cols) {
                float w = wr[c];
                sumW += w;  sumWP += w * p[c + 1];
            }
            // Up
            if (pUp) {
                float w = wdUp[c];
                sumW += w;  sumWP += w * pUp[c];
            }
            // Down
            if (pDown) {
                float w = wd[c];
                sumW += w;  sumWP += w * pDown[c];
            }

            // Data term
            float denom = sumW + lambda;
            float newVal = (denom > 1e-12f)
                ? (sumWP + lambda * dt[c]) / denom
                : dt[c];

            float delta = std::abs(newVal - p[c]);
            if (delta > maxDelta) maxDelta = delta;
            p[c] = newVal;
        }
    }
    return maxDelta;
}

// Scale column array from full-res to working-res coords (ROI-relative).
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

        // Margin: enough to sample sky/ground centroids from seed regions.
        int bandHeight = globalBot - globalTop;
        int margin = std::max(40, bandHeight / 2);
        int roiTop = std::max(0, globalTop - margin);
        int roiBot = std::min(imgH - 1, globalBot + margin);
        int roiH   = roiBot - roiTop + 1;

        Log_i("pib_random_walker_horizon: ROI [%d..%d] (%d rows), "
              "cols [%d..%d], beta=%.1f",
              roiTop, roiBot, roiH, colLeft, colRight, beta);

        // ── 2. Crop ROI, convert to LAB and grayscale ────────────────────

        cv::Mat roiColor = input(cv::Range(roiTop, roiBot + 1), cv::Range::all()).clone();
        cv::Mat labROI = toLAB32F(roiColor);
        cv::Mat grayROI = toGray32F(roiColor);

        // ── 3. Downsample to working resolution ──────────────────────────

        double scaleX = 1.0, scaleY = 1.0;
        int workW = imgW, workH = roiH;

        if (imgW > maxWorkingWidth) {
            scaleX = (double)maxWorkingWidth / imgW;
            scaleY = scaleX;
            workW = maxWorkingWidth;
            workH = std::max(2, (int)(roiH * scaleY + 0.5));
            cv::resize(labROI,  labROI,  cv::Size(workW, workH), 0, 0, cv::INTER_AREA);
            cv::resize(grayROI, grayROI, cv::Size(workW, workH), 0, 0, cv::INTER_AREA);
        }

        Log_d("pib_random_walker_horizon: working size %dx%d (scale %.3f)",
              workW, workH, scaleX);

        // ── 4. Gentle star suppression ───────────────────────────────────
        // Median 3×3 kills point-source stars without blurring horizon.

        cv::Mat grayBlurred;
        cv::medianBlur(grayROI, grayBlurred, 3);

        // Gentle bilateral on LAB: small spatial sigma (3px), moderate
        // colour sigma (15) to blur star colour noise while preserving
        // the horizon edge.
        cv::Mat lab8u;
        labROI.convertTo(lab8u, CV_8UC3);
        cv::Mat labSmooth;
        cv::bilateralFilter(lab8u, labSmooth, 3, 15, 10);
        labSmooth.convertTo(labROI, CV_32FC3);

        // ── 5. Compute LAB edge weights (anisotropic) ────────────────────
        // Mild vertical boost: horizontal boundaries are slightly harder
        // to cross, but not so much that peaks/valleys get smoothed.

        cv::Mat wRight, wDown;
        double verticalBoost = 1.5;
        computeEdgeWeightsLAB(labROI, beta, verticalBoost, wRight, wDown);

        // ── 6. Scale per-column arrays to working resolution ─────────────

        auto wSkyFloor   = scaleColumnArray(skyFloorY,   width, workW, scaleX, scaleY, roiTop);
        auto wGndCeiling = scaleColumnArray(groundCeilY, width, workW, scaleX, scaleY, roiTop);
        auto wBandTop    = scaleColumnArray(bandTopY,    width, workW, scaleX, scaleY, roiTop);
        auto wBandBot    = scaleColumnArray(bandBottomY, width, workW, scaleX, scaleY, roiTop);

        // ── 7. Compute sky/ground centroids from seed regions ────────────

        cv::Vec3d skySum(0,0,0), gndSum(0,0,0);
        int nSky = 0, nGnd = 0;

        // Sample sky/ground centroids from pixels NEAR the band boundary,
        // not from the full sky/ground region.  The sky just above the
        // horizon is what matters for classification — not the bright
        // blue sky 1000 pixels overhead.  Similarly, the ground just below
        // the horizon is what matters, not dark foreground far below.
        //
        // Sample band: a strip of `nearBand` rows immediately above the
        // sky floor (sky side) and immediately below the ground ceiling
        // (ground side).
        int nearBand = std::max(5, workH / 8);

        int colStep = std::max(1, workW / 300);
        for (int c = 0; c < workW; c += colStep) {
            if (wBandTop[c] < 0) continue;

            int skyF = std::max(0, std::min(workH - 1, wSkyFloor[c]));
            int gndC = std::max(0, std::min(workH - 1, wGndCeiling[c]));

            // Sky: sample nearBand rows ABOVE the sky floor
            // (the sky closest to the horizon)
            int skyStart = std::max(0, skyF - nearBand);
            for (int r = skyStart; r < skyF; r++) {
                cv::Vec3f v = labROI.at<cv::Vec3f>(r, c);
                skySum += cv::Vec3d(v[0], v[1], v[2]);
                nSky++;
            }

            // Ground: sample nearBand rows BELOW the ground ceiling
            // (the ground closest to the horizon)
            int gndEnd = std::min(workH, gndC + nearBand);
            for (int r = gndC; r < gndEnd; r++) {
                cv::Vec3f v = labROI.at<cv::Vec3f>(r, c);
                gndSum += cv::Vec3d(v[0], v[1], v[2]);
                nGnd++;
            }
        }

        cv::Vec3f skyCentroid(0,0,0), gndCentroid(0,0,0);
        if (nSky > 0) skyCentroid = cv::Vec3f((float)(skySum[0]/nSky),
                                               (float)(skySum[1]/nSky),
                                               (float)(skySum[2]/nSky));
        if (nGnd > 0) gndCentroid = cv::Vec3f((float)(gndSum[0]/nGnd),
                                               (float)(gndSum[1]/nGnd),
                                               (float)(gndSum[2]/nGnd));

        Log_d("pib_random_walker_horizon: sky centroid LAB=(%.1f, %.1f, %.1f) "
              "ground centroid LAB=(%.1f, %.1f, %.1f) "
              "(nSky=%d, nGnd=%d, nearBand=%d)",
              skyCentroid[0], skyCentroid[1], skyCentroid[2],
              gndCentroid[0], gndCentroid[1], gndCentroid[2],
              nSky, nGnd, nearBand);

        // ── 8. Compute data term ─────────────────────────────────────────

        cv::Mat dataTerm = computeDataTerm(labROI, skyCentroid, gndCentroid);

        // Data term strength (lambda).  Higher values make the colour model
        // dominate over diffusion; lower values rely more on edges.
        // With local centroids (near-horizon colours), a moderate lambda
        // balances colour model and edge awareness.
        float lambda = 0.3f;

        // ── 9. Build seed mask and initial probabilities ─────────────────

        cv::Mat prob(workH, workW, CV_32F);
        cv::Mat seedMask(workH, workW, CV_8UC1, cv::Scalar(0));

        // Initialise prob from data term (colour-model prior)
        dataTerm.copyTo(prob);

        // Track the leftmost and rightmost painted columns at working res.
        int wColLeft = workW, wColRight = -1;

        for (int c = 0; c < workW; c++) {
            if (wBandTop[c] < 0 || wBandBot[c] < 0) {
                // Unpainted columns: lock entire column as seeded.
                // Use data term values so they provide a neutral colour-
                // based prior without pulling the horizon in any direction.
                for (int r = 0; r < workH; r++) {
                    seedMask.at<uchar>(r, c) = 1;
                    // prob stays at data term value (already copied)
                }
                continue;
            }

            if (c < wColLeft)  wColLeft  = c;
            if (c > wColRight) wColRight = c;

            int skyF = std::max(0, wSkyFloor[c]);
            int gndC = std::min(workH - 1, wGndCeiling[c]);

            for (int r = 0; r <= skyF && r < workH; r++) {
                prob.at<float>(r, c) = 1.0f;
                seedMask.at<uchar>(r, c) = 1;
            }
            for (int r = gndC; r < workH; r++) {
                prob.at<float>(r, c) = 0.0f;
                seedMask.at<uchar>(r, c) = 1;
            }
        }

        // ── 10. Multi-scale Gauss-Seidel solve WITH data term ────────────

        // Coarse solve
        if (workW > 64 && workH > 16) {
            int coarseW = workW / 2;
            int coarseH = workH / 2;

            cv::Mat coarseProb, coarseSeed, coarseData;
            cv::resize(prob,     coarseProb, cv::Size(coarseW, coarseH), 0, 0, cv::INTER_NEAREST);
            cv::resize(seedMask, coarseSeed, cv::Size(coarseW, coarseH), 0, 0, cv::INTER_NEAREST);
            cv::resize(dataTerm, coarseData, cv::Size(coarseW, coarseH), 0, 0, cv::INTER_LINEAR);

            cv::Mat coarseLab;
            cv::resize(labROI, coarseLab, cv::Size(coarseW, coarseH), 0, 0, cv::INTER_AREA);
            cv::Mat coarseWR, coarseWD;
            computeEdgeWeightsLAB(coarseLab, beta, verticalBoost, coarseWR, coarseWD);

            for (int iter = 0; iter < 150; iter++) {
                float maxDelta = gaussSeidelWithData(coarseProb, coarseSeed,
                                                     coarseWR, coarseWD,
                                                     coarseData, lambda);
                if (maxDelta < 5e-4f) {
                    Log_d("pib_random_walker_horizon: coarse converged at iter %d", iter);
                    break;
                }
            }

            // Upsample coarse → fine initial guess (unknown pixels only)
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
        for (int iter = 0; iter < 300; iter++) {
            float maxDelta = gaussSeidelWithData(prob, seedMask,
                                                 wRight, wDown,
                                                 dataTerm, lambda);
            if (maxDelta < 1e-4f) {
                Log_d("pib_random_walker_horizon: fine converged at iter %d", iter);
                break;
            }
        }

        // ── 11. Extract per-column horizon Y (scan UP from ground) ───────

        std::vector<int> workHorizon(workW, -1);
        for (int c = 0; c < workW; c++) {
            if (wBandBot[c] < 0) continue;

            int gndRow = std::min(workH - 1, wGndCeiling[c]);
            int skyRow = std::max(0, wSkyFloor[c]);

            // Scan upward from ground: find where prob crosses 0.5
            int horizonR = skyRow;
            for (int r = gndRow; r >= skyRow; r--) {
                if (prob.at<float>(r, c) >= 0.5f) {
                    horizonR = r;
                    break;
                }
            }
            workHorizon[c] = horizonR;
        }

        // ── 12. Edge snapping ────────────────────────────────────────────
        // Snap to the nearest strong vertical edge within a tight window.
        // Too wide a window causes the snap to jump to wrong edges,
        // smoothing over peaks and valleys.

        cv::Mat sobelY;
        cv::Sobel(grayBlurred, sobelY, CV_32F, 0, 1, 3);
        sobelY = cv::abs(sobelY);

        // Tight snap: ±8 pixels at working resolution
        int snapRadius = std::max(3, (int)(8 * scaleY + 0.5));
        float snapThreshold = 0.015f;

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

        // ── 13. Median filter ────────────────────────────────────────────
        // Small window: just enough to remove isolated 1-2 column spikes
        // from star noise, without smoothing real peaks/valleys.

        int medW = std::max(3, workW / 250);
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

        // ── 13b. Edge stabilization ──────────────────────────────────────
        // The solver is unreliable at the edges of the painted band because
        // there's no lateral context on one side.  Compute a robust anchor
        // from a median of interior columns, then blend the edge toward it.

        if (wColLeft >= 0 && wColRight > wColLeft) {
            int paintedSpan = wColRight - wColLeft + 1;
            // Anchor zone: 5-10% in from each edge, take median of that zone
            int anchorStart = std::max(8, paintedSpan / 15);  // ~7% in
            int anchorWidth = std::max(5, paintedSpan / 20);  // ~5% wide strip

            // Left anchor: median of columns [wColLeft+anchorStart .. +anchorStart+anchorWidth]
            {
                std::vector<int> anchorVals;
                int aLeft = wColLeft + anchorStart;
                int aRight = std::min(wColRight, aLeft + anchorWidth);
                for (int c = aLeft; c <= aRight; c++) {
                    if (smoothed[c] >= 0) anchorVals.push_back(smoothed[c]);
                }
                if (!anchorVals.empty()) {
                    std::nth_element(anchorVals.begin(),
                                     anchorVals.begin() + anchorVals.size()/2,
                                     anchorVals.end());
                    int anchorY = anchorVals[anchorVals.size()/2];

                    // Blend from wColLeft (100% anchor) to aLeft (100% solver)
                    for (int c = wColLeft; c < aLeft; c++) {
                        if (smoothed[c] < 0) continue;
                        float t = (float)(c - wColLeft) / (float)(aLeft - wColLeft);
                        smoothed[c] = (int)(anchorY * (1.0f - t) + smoothed[c] * t + 0.5f);
                    }
                }
            }

            // Right anchor: median of columns [wColRight-anchorStart-anchorWidth .. -anchorStart]
            {
                std::vector<int> anchorVals;
                int aRight = wColRight - anchorStart;
                int aLeft = std::max(wColLeft, aRight - anchorWidth);
                for (int c = aLeft; c <= aRight; c++) {
                    if (smoothed[c] >= 0) anchorVals.push_back(smoothed[c]);
                }
                if (!anchorVals.empty()) {
                    std::nth_element(anchorVals.begin(),
                                     anchorVals.begin() + anchorVals.size()/2,
                                     anchorVals.end());
                    int anchorY = anchorVals[anchorVals.size()/2];

                    // Blend from aRight (100% solver) to wColRight (100% anchor)
                    for (int c = aRight + 1; c <= wColRight; c++) {
                        if (smoothed[c] < 0) continue;
                        float t = (float)(wColRight - c) / (float)(wColRight - aRight);
                        smoothed[c] = (int)(anchorY * (1.0f - t) + smoothed[c] * t + 0.5f);
                    }
                }
            }
        }

        // ── 14. Upsample horizon Y to full image resolution ─────────────

        for (int fc = 0; fc < width; fc++) {
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

        // Fill gaps via linear interpolation
        int lastValid = -1, lastY = -1;
        for (int c = 0; c < width; c++) {
            if (outHorizonY[c] >= 0) {
                if (lastValid >= 0 && lastValid < c - 1) {
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

        Log_i("pib_random_walker_horizon: done, cols [%d..%d]", colLeft, colRight);

    } KHT_CATCH_LOG("pib_random_walker_horizon")
}
