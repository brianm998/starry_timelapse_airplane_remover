// Differential and timing harness: ExactWarp.hpp's remap and cloud-stage map generator against
// cv::remap (INTER_LINEAR, BORDER_TRANSPARENT) and the map lambda they replace.
//
//   remap_bench sweep [trials]   (1) float maps of every awkward kind through exactwarp::remap
//                                    against cv::remap on the 16-bit frame and on the 8-bit probe;
//                                (2) random displacement fields: the chunk generator's floats
//                                    bit for bit against the stage's lambda, and the whole
//                                    remapField against lambda + cv::remap + probe remap.
//                                Scalar and AVX2 rows.  Exit 1 on any difference.
//   remap_bench time             single-thread ns per pixel-channel, old stage code vs new, on a
//                                6000x1000x3 region of a 6000x4000 frame
#include "ExactWarp.hpp"
#include <opencv2/imgproc.hpp>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <limits>
#include <random>
#include <string>

using Clock = std::chrono::steady_clock;
static std::mt19937_64 rng(4242);
static double urand(double a, double b) { return a + (b - a) * (double)(rng() >> 11) / (double)(1ULL << 53); }

static void fill(cv::Mat &m, int mode) {
    for (int y = 0; y < m.rows; ++y) {
        uint16_t *p = m.ptr<uint16_t>(y);
        for (int x = 0; x < m.cols * m.channels(); ++x) {
            switch (mode) {
            case 0: p[x] = (uint16_t)(rng() & 0xffff); break;
            case 1: p[x] = (uint16_t)(1000 + (rng() % 30)); break;
            case 2: p[x] = (uint16_t)((rng() & 1) ? 65535 : 0); break;
            default: p[x] = (uint16_t)((x * 37 + y * 11) & 0xffff);
            }
        }
    }
}

static uint32_t bitsOf(float f) { uint32_t u; std::memcpy(&u, &f, 4); return u; }

// ---- (1) float maps ------------------------------------------------------------------------

static float awkward(int kind, int w, int h, bool isX, int x, int y, double a, double b) {
    const double base = isX ? x : y, lim = isX ? w : h;
    switch (kind) {
    case 0: return (float)base;                                             // identity
    case 1: return (float)(base + (int)a);                                  // integer shift
    case 2: return (float)(base + a);                                       // fractional shift
    case 3: return (float)(base + urand(-1.5, 1.5));                        // jitter
    case 4: return (float)(base + 0.015625 * (int)(a * 20));                // exact 64ths: ties in x32
    case 5: return (float)(isX ? 0.9 * x - 0.1 * y + a : 0.1 * x + 0.9 * y + b);   // rotation-ish
    case 6: { const double c[] = {-1e6, 1e6, 1e9, -1e9, 32767.5, -32768.5, 32766.99, -0.5, lim - 0.5, lim - 1, lim, -1, -0.03125, lim - 0.96875};
              return (float)c[rng() % (sizeof c / sizeof c[0])]; }          // extremes and edges
    case 7: { const float c[] = {std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity(),
                                 -std::numeric_limits<float>::infinity(), 3.4e38f, -3.4e38f};
              return (rng() & 7) ? (float)(base + a) : c[rng() % 5]; }      // NaN, inf, huge
    case 8: return (float)urand(-1.2, lim + 0.2);                           // hugging the frame
    default: return (float)urand(-5, lim + 5);
    }
}

struct Tally { long long pixels = 0, differ = 0, covDiffer = 0; };

static bool mapCase(int w, int h, int dw, int dh, int cn, int kind, int fmode, Tally &t) {
    cv::Mat src(h, w, CV_MAKETYPE(CV_16U, cn));
    fill(src, fmode);
    cv::Mat mapx(dh, dw, CV_32F), mapy(dh, dw, CV_32F);
    const double a = urand(-9, 9), b = urand(-9, 9);
    for (int y = 0; y < dh; ++y)
        for (int x = 0; x < dw; ++x) {
            mapx.at<float>(y, x) = awkward(kind, w, h, true, x, y, a, b);
            mapy.at<float>(y, x) = awkward(kind, w, h, false, x, y, a, b);
        }
    if (!exactwarp::remapApplies(src, mapx.size())) return true;

    cv::Mat ref = cv::Mat::zeros(mapx.size(), src.type());
    cv::remap(src, ref, mapx, mapy, cv::INTER_LINEAR, cv::BORDER_TRANSPARENT);
    cv::Mat probe(src.size(), CV_8UC1, cv::Scalar(255)), refCov = cv::Mat::zeros(mapx.size(), CV_8UC1);
    cv::remap(probe, refCov, mapx, mapy, cv::INTER_LINEAR, cv::BORDER_TRANSPARENT);

    long long d = 0, dc = 0;
    for (int scalar = 0; scalar < 2; ++scalar) {
        exactwarp::forceScalarFlag() = scalar == 1;
        cv::Mat out = cv::Mat::zeros(mapx.size(), src.type()), cov = cv::Mat::zeros(mapx.size(), CV_8UC1);
        exactwarp::remap(src, mapx, mapy, out, &cov);
        for (int y = 0; y < dh; ++y) {
            const uint16_t *p = ref.ptr<uint16_t>(y), *q = out.ptr<uint16_t>(y);
            for (int x = 0; x < dw * cn; ++x) d += p[x] != q[x];
            const uint8_t *cp = refCov.ptr<uint8_t>(y), *cq = cov.ptr<uint8_t>(y);
            for (int x = 0; x < dw; ++x) dc += cp[x] != cq[x];
        }
    }
    exactwarp::forceScalarFlag() = false;
    t.pixels += (long long)dw * dh * cn * 2; t.differ += d; t.covDiffer += dc;
    if (d || dc) std::printf("DIFF maps %dx%d -> %dx%d cn=%d kind=%d fill=%d: %lld pixel-channels, %lld coverage\n", w, h, dw, dh, cn, kind, fmode, d, dc);
    return d == 0 && dc == 0;
}

// ---- (2) the stage's map lambda, verbatim ---------------------------------------------------

constexpr int kFactor = 4, kStep = 48;   // the cloud stage's constants

struct Grid {
    int ny = 0, nx = 0;
    std::vector<float> v[2];
    size_t at(int i, int j) const { return (size_t)i * nx + j; }
};
struct FieldAxis { std::vector<int> idx; std::vector<float> t; };

static int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }
static double tileCentre(int i) { return (double)(kStep * kFactor) * i + (double)(kStep * kFactor); }
static FieldAxis makeAxis(int start, int count, int tiles) {      // as cloudaware::makeAxis
    FieldAxis a;
    a.idx.resize((size_t)count); a.t.resize((size_t)count);
    for (int k = 0; k < count; ++k) {
        if (tiles <= 1) { a.idx[(size_t)k] = 0; a.t[(size_t)k] = 0.f; continue; }
        const double f = ((double)(start + k) + 0.5 - tileCentre(0)) / (double)(kStep * kFactor);
        const int i = clampi((int)std::floor(f), 0, tiles - 2);
        a.idx[(size_t)k] = i;
        a.t[(size_t)k] = (float)std::min(std::max(f - (double)i, 0.0), 1.0);
    }
    return a;
}

// ImageAligner.cpp buildLayer's lambda, over a whole region, as it was before.
static void referenceMaps(const Grid &fld, const double *hi, const cv::Rect &region,
                          const FieldAxis &axisY, const FieldAxis &axisX, cv::Mat &mapx, cv::Mat &mapy)
{
    mapx.create(region.size(), CV_32F); mapy.create(region.size(), CV_32F);
    for (int y = 0; y < region.height; ++y) {
        const int iy = axisY.idx[(size_t)y], iy2 = std::min(iy + 1, fld.ny - 1);
        const float ty = axisY.t[(size_t)y];
        float *mx = mapx.ptr<float>(y), *my = mapy.ptr<float>(y);
        for (int x = 0; x < region.width; ++x) {
            const int jx = axisX.idx[(size_t)x], jx2 = std::min(jx + 1, fld.nx - 1);
            const float tx = axisX.t[(size_t)x];
            float d[2];
            for (int c = 0; c < 2; ++c) {
                const float a = fld.v[c][fld.at(iy, jx)] * (1.f - ty) + fld.v[c][fld.at(iy2, jx)] * ty;
                const float b = fld.v[c][fld.at(iy, jx2)] * (1.f - ty) + fld.v[c][fld.at(iy2, jx2)] * ty;
                d[c] = (a * (1.f - tx) + b * tx) * (float)kFactor;
            }
            const double qx = (double)(region.x + x) + (double)d[1];
            const double qy = (double)(region.y + y) + (double)d[0];
            const double wd = hi[6] * qx + hi[7] * qy + hi[8];
            if (std::fabs(wd) < 1e-12) { mx[x] = -1e6f; my[x] = -1e6f; continue; }
            mx[x] = (float)((hi[0] * qx + hi[1] * qy + hi[2]) / wd);
            my[x] = (float)((hi[3] * qx + hi[4] * qy + hi[5]) / wd);
        }
    }
}

static void randomHinv(double *hi, int kind, int w, int h) {
    const double id[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    std::memcpy(hi, id, sizeof id);
    switch (kind) {
    case 0: break;
    case 1: hi[2] = urand(-9, 9); hi[5] = urand(-9, 9); break;
    case 2:
        hi[0] = 1 + urand(-2e-4, 2e-4); hi[1] = urand(-3e-4, 3e-4); hi[2] = urand(-12, 12);
        hi[3] = urand(-3e-4, 3e-4); hi[4] = 1 + urand(-2e-4, 2e-4); hi[5] = urand(-12, 12);
        hi[6] = urand(-1e-8, 1e-8); hi[7] = urand(-1e-8, 1e-8); break;
    case 3:
        hi[0] = 1 + urand(-.2, .2); hi[1] = urand(-.1, .1); hi[2] = urand(-20, 20);
        hi[3] = urand(-.1, .1); hi[4] = 1 + urand(-.2, .2); hi[5] = urand(-20, 20);
        hi[6] = urand(-2e-3, 2e-3); hi[7] = urand(-2e-3, 2e-3); break;
    case 4: hi[2] = urand(-0.6, 0.6) * w; hi[5] = urand(-0.6, 0.6) * h; break;       // off the frame
    case 5: hi[6] = 0; hi[7] = 0; hi[8] = 0; break;                                   // w == 0 everywhere
    case 6: hi[6] = 1.0 / w; hi[7] = 0; hi[8] = -0.5; break;                          // w crosses zero in the region
    default: hi[8] = 2; hi[0] = 2; hi[4] = 2; break;
    }
}

static bool fieldCase(int fw, int fh, int cn, int fillMode, int hkind, int fkind, Tally &t, Tally &tmaps) {
    // a frame, a region inside it (or overhanging), a grid with the stage's spacing
    cv::Mat src(fh, fw, CV_MAKETYPE(CV_16U, cn));
    fill(src, fillMode);
    cv::Rect region(0, 0, fw, fh);
    if (rng() & 1) {
        region.x = (int)(rng() % (fw / 3 + 1)); region.y = (int)(rng() % (fh / 3 + 1));
        region.width = 1 + (int)(rng() % (unsigned)(fw - region.x)); region.height = 1 + (int)(rng() % (unsigned)(fh - region.y));
    }
    const int ny = std::max(1, fh / (kStep * kFactor)), nx = std::max(1, fw / (kStep * kFactor));
    Grid g; g.ny = ny; g.nx = nx;
    for (int c = 0; c < 2; ++c) {
        g.v[c].resize((size_t)ny * nx);
        for (auto &v : g.v[c]) {
            switch (fkind) {
            case 0: v = 0.f; break;
            case 1: v = (float)urand(-40, 40); break;
            case 2: v = 0.25f * (int)urand(-8, 8); break;                 // quarter pixels, ties
            default: v = (float)(int)urand(-30, 30);
            }
        }
    }
    const FieldAxis axisY = makeAxis(region.y, region.height, ny), axisX = makeAxis(region.x, region.width, nx);
    double hi[9]; randomHinv(hi, hkind, fw, fh);

    cv::Mat mapx, mapy;
    referenceMaps(g, hi, region, axisY, axisX, mapx, mapy);

    exactwarp::DisplacementField f;
    f.nx = nx; f.ny = ny; f.v[0] = g.v[0].data(); f.v[1] = g.v[1].data();
    f.colIdx = axisX.idx.data(); f.colT = axisX.t.data(); f.rowIdx = axisY.idx.data(); f.rowT = axisY.t.data();
    f.originX = region.x; f.originY = region.y; f.scale = (float)kFactor;
    std::memcpy(f.hi, hi, sizeof hi);

    long long mapsBad = 0;
    for (int scalar = 0; scalar < 2; ++scalar) {
        std::vector<float> a0((size_t)nx), a1((size_t)nx), mx((size_t)region.width), my((size_t)region.width);
        for (int y = 0; y < region.height; ++y) {
            exactwarp::fieldRowBlend(f, y, a0.data(), a1.data());
            // in chunks that do not start on a multiple of eight
            for (int x0 = 0; x0 < region.width;) {
                const int n = std::min(region.width - x0, 1 + (int)(rng() % 37));
                if (!scalar) exactwarp::fieldMapsAvx2(f, a0.data(), a1.data(), y, x0, n, mx.data(), my.data());
                else exactwarp::fieldMapsScalar(f, a0.data(), a1.data(), y, x0, n, mx.data(), my.data());
                for (int i = 0; i < n; ++i) {
                    mapsBad += bitsOf(mx[(size_t)i]) != bitsOf(mapx.at<float>(y, x0 + i));
                    mapsBad += bitsOf(my[(size_t)i]) != bitsOf(mapy.at<float>(y, x0 + i));
                }
                x0 += n;
            }
        }
    }
    tmaps.pixels += (long long)region.area() * 4; tmaps.differ += mapsBad;

    if (!exactwarp::remapApplies(src, region.size())) return mapsBad == 0;
    cv::Mat ref = cv::Mat::zeros(region.size(), src.type());
    cv::remap(src, ref, mapx, mapy, cv::INTER_LINEAR, cv::BORDER_TRANSPARENT);
    cv::Mat probe(src.size(), CV_8UC1, cv::Scalar(255)), refCov = cv::Mat::zeros(region.size(), CV_8UC1);
    cv::remap(probe, refCov, mapx, mapy, cv::INTER_LINEAR, cv::BORDER_TRANSPARENT);
    long long d = 0, dc = 0;
    for (int scalar = 0; scalar < 2; ++scalar) {
        exactwarp::forceScalarFlag() = scalar == 1;
        cv::Mat out = cv::Mat::zeros(region.size(), src.type()), cov = cv::Mat::zeros(region.size(), CV_8UC1);
        exactwarp::remapField(src, f, region.size(), out, &cov);
        for (int y = 0; y < region.height; ++y) {
            const uint16_t *p = ref.ptr<uint16_t>(y), *q = out.ptr<uint16_t>(y);
            for (int x = 0; x < region.width * cn; ++x) d += p[x] != q[x];
            const uint8_t *cp = refCov.ptr<uint8_t>(y), *cq = cov.ptr<uint8_t>(y);
            for (int x = 0; x < region.width; ++x) dc += cp[x] != cq[x];
        }
    }
    exactwarp::forceScalarFlag() = false;
    t.pixels += (long long)region.area() * cn * 2; t.differ += d; t.covDiffer += dc;
    if (mapsBad || d || dc)
        std::printf("DIFF field frame %dx%d region %dx%d+%d+%d cn=%d H=%d field=%d fill=%d: %lld map floats, %lld pixel-channels, %lld coverage\n",
                    fw, fh, region.width, region.height, region.x, region.y, cn, hkind, fkind, fillMode, mapsBad, d, dc);
    return mapsBad == 0 && d == 0 && dc == 0;
}

int main(int argc, char **argv) {
    std::string mode = argc > 1 ? argv[1] : "sweep";
    if (mode == "sweep") {
        const int trials = argc > 2 ? atoi(argv[2]) : 600;
        Tally a, b, maps; bool ok = true;
        const int sizes[][2] = {{1,1},{2,2},{3,7},{16,1},{1,40},{17,9},{63,15},{64,16},{65,17},{100,33},{130,70},{257,129},{513,31},{1200,40},{1030,20}};
        const int nsz = sizeof(sizes) / sizeof(sizes[0]);
        for (int tr = 0; tr < trials; ++tr) {
            const auto &s = sizes[rng() % nsz];
            const auto &d = sizes[rng() % nsz];                  // destination size independent of the source's
            ok &= mapCase(s[0], s[1], d[0], d[1], (rng() & 1) ? 1 : 3, (int)(rng() % 10), (int)(rng() % 4), a);
        }
        for (int tr = 0; tr < trials / 3; ++tr) {
            const int fw = 400 + (int)(rng() % 1900), fh = 200 + (int)(rng() % 900);
            ok &= fieldCase(fw, fh, (rng() & 1) ? 1 : 3, (int)(rng() % 4), (int)(rng() % 8), (int)(rng() % 4), b, maps);
        }
        std::printf("float maps: %lld pixel-channels, %lld differ, %lld coverage differ\n", a.pixels, a.differ, a.covDiffer);
        std::printf("fields:     %lld map floats, %lld differ; %lld pixel-channels, %lld differ, %lld coverage differ\n",
                    maps.pixels, maps.differ, b.pixels, b.differ, b.covDiffer);
        return ok ? 0 : 1;
    }
    if (mode == "time") {
        cv::setNumThreads(1);
        const int fw = 6000, fh = 4000, cn = 3;
        cv::Mat src(fh, fw, CV_16UC3); fill(src, 0);
        const cv::Rect region(0, 1000, 6000, 1000);
        const int ny = fh / (kStep * kFactor), nx = fw / (kStep * kFactor);
        Grid g; g.ny = ny; g.nx = nx;
        // a cloud field: a drift of ~12 low-res px (48 px) either way, varying a little from cell to cell,
        // as the 3x3 median over the grid leaves it; argv[2] = "rough" makes it +-25 at random instead
        const bool rough = argc > 2 && std::string(argv[2]) == "rough";
        for (int c = 0; c < 2; ++c) {
            g.v[c].resize((size_t)ny * nx);
            for (auto &v : g.v[c]) v = rough ? (float)urand(-25, 25) : (float)((c ? 12.0 : -9.0) + urand(-1.5, 1.5));
        }
        const FieldAxis axisY = makeAxis(region.y, region.height, ny), axisX = makeAxis(region.x, region.width, nx);
        double hi[9]; randomHinv(hi, 2, fw, fh);
        exactwarp::DisplacementField f;
        f.nx = nx; f.ny = ny; f.v[0] = g.v[0].data(); f.v[1] = g.v[1].data();
        f.colIdx = axisX.idx.data(); f.colT = axisX.t.data(); f.rowIdx = axisY.idx.data(); f.rowT = axisY.t.data();
        f.originX = region.x; f.originY = region.y; f.scale = (float)kFactor;
        std::memcpy(f.hi, hi, sizeof hi);
        const cv::Mat probe(fh, fw, CV_8UC1, cv::Scalar(255));
        cv::Mat layer(region.size(), src.type()), covered(region.size(), CV_8UC1), out(region.size(), src.type()), cov(region.size(), CV_8UC1);
        double tMaps = 1e9, tRemap = 1e9, tProbe = 1e9, tNew = 1e9, tNewScalar = 1e9;
        cv::Mat mapx, mapy;
        for (int r = 0; r < 4; ++r) {
            auto t = Clock::now();
            referenceMaps(g, hi, region, axisY, axisX, mapx, mapy);
            tMaps = std::min(tMaps, std::chrono::duration<double>(Clock::now() - t).count());
            layer.setTo(0); t = Clock::now();
            cv::remap(src, layer, mapx, mapy, cv::INTER_LINEAR, cv::BORDER_TRANSPARENT);
            tRemap = std::min(tRemap, std::chrono::duration<double>(Clock::now() - t).count());
            covered.setTo(0); t = Clock::now();
            cv::remap(probe, covered, mapx, mapy, cv::INTER_LINEAR, cv::BORDER_TRANSPARENT);
            tProbe = std::min(tProbe, std::chrono::duration<double>(Clock::now() - t).count());
            out.setTo(0); cov.setTo(0); t = Clock::now();
            exactwarp::remapField(src, f, region.size(), out, &cov);
            tNew = std::min(tNew, std::chrono::duration<double>(Clock::now() - t).count());
            exactwarp::forceScalarFlag() = true;
            out.setTo(0); cov.setTo(0); t = Clock::now();
            exactwarp::remapField(src, f, region.size(), out, &cov);
            tNewScalar = std::min(tNewScalar, std::chrono::duration<double>(Clock::now() - t).count());
            exactwarp::forceScalarFlag() = false;
        }
        const double px = (double)region.area(), pc = px * cn;
        std::printf("old: map lambda %.1f ns/px + cv::remap 16-bit %.1f ns/pc + 8-bit probe %.1f ns/px = %.1f ns/px\n",
                    tMaps / px * 1e9, tRemap / pc * 1e9, tProbe / px * 1e9, (tMaps + tRemap + tProbe) / px * 1e9);
        std::printf("new: AVX2 %.1f ns/px (%.2fx)   scalar rows %.1f ns/px (%.2fx)\n",
                    tNew / px * 1e9, (tMaps + tRemap + tProbe) / tNew, tNewScalar / px * 1e9, (tMaps + tRemap + tProbe) / tNewScalar);
        return 0;
    }
    return 2;
}
