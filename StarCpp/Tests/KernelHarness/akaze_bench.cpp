// Differential harness: AKAZEDetector.cpp's keypoint-map passes (findScaleSpaceExtrema's two level
// filters and doSubpixelRefinement) against the dense-scan versions they replaced, over random
// multi-octave level sets.  Exit 1 on any difference in the kept maps or the keypoints.
#include "../../Sources/StarCpp/AKAZEDetector.cpp"
// The passes as they were before `forEachNonzero`: four dense scans over every pixel of every
// level, kept here as the reference.  They use EvolutionLevel and kDerivativeFactor from the file
// above.
namespace oldakaze {
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

}
#include <chrono>
#include <cstdio>
#include <random>

static std::mt19937_64 rng(4242);

static std::vector<EvolutionLevel> makeLevels(int baseW, int baseH, double density) {
    std::vector<EvolutionLevel> ev;
    for (int o = 0; o < 4; ++o) {
        const int ratio = 1 << o;
        for (int s = 0; s < 4; ++s) {
            EvolutionLevel e;
            e.octave = o; e.sublevel = s; e.octave_ratio = (float)ratio;
            e.esigma = 1.6f * std::pow(2.f, o + s / 4.f);
            e.sigma_size = 1 + (int)(rng() % 5);
            e.border = e.sigma_size + 4;
            const int w = std::max(8, baseW / ratio), h = std::max(8, baseH / ratio);
            e.Ldet = cv::Mat(h, w, CV_32F);
            std::uniform_real_distribution<float> u(0.f, 1.f);
            for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
                float v = u(rng);
                e.Ldet.at<float>(y, x) = v > (float)(1.0 - density) ? v : 0.f;
            }
            e.size = e.Ldet.size();
            ev.push_back(std::move(e));
        }
    }
    return ev;
}

int main(int argc, char **argv) {
    const int trials = argc > 1 ? atoi(argv[1]) : 60;
    long long kpts = 0; int bad = 0;
    for (int t = 0; t < trials; ++t) {
        const int w = 20 + (int)(rng() % 400), h = 20 + (int)(rng() % 300);
        const double density = t % 3 == 0 ? 0.002 : (t % 3 == 1 ? 0.05 : 0.5);
        auto evA = makeLevels(w, h, density);
        auto evB = evA;   // shares Ldet buffers; the passes never write Ldet
        std::vector<cv::Mat> mapsOld, mapsNew;
        const float thr = 0.5f;
        oldakaze::findScaleSpaceExtrema(evA, thr, mapsOld);
        findScaleSpaceExtrema(evB, thr, mapsNew);
        bool same = mapsOld.size() == mapsNew.size();
        for (size_t i = 0; same && i < mapsOld.size(); ++i)
            same = mapsOld[i].size() == mapsNew[i].size() && cv::countNonZero(mapsOld[i] != mapsNew[i]) == 0;
        std::vector<cv::KeyPoint> outOld, outNew;
        oldakaze::doSubpixelRefinement(evA, mapsOld, outOld);
        doSubpixelRefinement(evB, mapsNew, outNew);
        same = same && outOld.size() == outNew.size();
        for (size_t i = 0; same && i < outOld.size(); ++i) {
            const auto &a = outOld[i], &b = outNew[i];
            same = std::memcmp(&a.pt, &b.pt, sizeof a.pt) == 0 && a.size == b.size && a.response == b.response &&
                   a.octave == b.octave && a.class_id == b.class_id && a.angle == b.angle;
        }
        kpts += (long long)outOld.size();
        if (!same) { ++bad; std::printf("DIFF trial %d (%dx%d density %g)\n", t, w, h, density); }
    }
    // timing on a big level set
    auto big = makeLevels(6000, 4000, 0.0005);
    std::vector<cv::Mat> m1, m2;
    double a = 1e9, b = 1e9;
    for (int r = 0; r < 3; ++r) {
        auto t0 = std::chrono::steady_clock::now(); oldakaze::findScaleSpaceExtrema(big, 0.5f, m1);
        std::vector<cv::KeyPoint> o; oldakaze::doSubpixelRefinement(big, m1, o);
        a = std::min(a, std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
        t0 = std::chrono::steady_clock::now(); findScaleSpaceExtrema(big, 0.5f, m2);
        std::vector<cv::KeyPoint> o2; doSubpixelRefinement(big, m2, o2);
        b = std::min(b, std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
    }
    std::printf("%d trials, %lld keypoints compared, %d differ; 24MP-scale levels: old %.3fs new %.3fs (%.2fx)\n",
                trials, kpts, bad, a, b, a / b);
    return bad ? 1 : 0;
}
