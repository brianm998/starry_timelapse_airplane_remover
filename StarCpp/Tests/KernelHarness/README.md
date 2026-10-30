# Kernel differential harnesses

Standalone programs (not SwiftPM targets) that hold the hand-written CPU kernels to the code they
replace, byte for byte, over far more cases than a unit test can afford, and time them single
threaded on this machine's own CPU.

| program | kernel | reference | what a pass means |
|---|---|---|---|
| `median_bench` | `MedianMerge.hpp`, the exact-statistics kernels | the Welford kernel in the same header, picked with `gMedianKernelOverride` | same bytes over random shapes / depths / channel counts / 1–65 sources / thresholds / coverage planes / exact-tie data, and on real 16-bit frames |
| `warp_bench` | `ExactWarp.hpp` | `cv::warpPerspective` (INTER_LINEAR, BORDER_TRANSPARENT) and the 8-bit probe warp | same pixels *and* same coverage plane, scalar and AVX2 rows, identity … strong perspective, 1–1200 px, 1 and 3 channels |
| `remap_bench` | `ExactWarp.hpp`'s `remap` and the cloud stage's map generator (`fieldMapsAvx2`) | `cv::remap` with float maps (and on the 8-bit probe), and the stage's map lambda, verbatim | same pixels, same coverage plane, and the generated map floats bit for bit, scalar and AVX2 rows, maps of every awkward kind (ties in 32nds, NaN/inf, far outside, degenerate w) |
| `blur_bench` | `BoxBlur.hpp`, the cloud stage's AVX2 box blur | the stage's original `boxBlurOnce`, copied verbatim into the harness | same floats, bit for bit, over widths/heights from 1 (including narrower than the window), radii 1–48, both scales, luma/weight/signed/NaN/inf/huge/exact-tie values |
| `match_bench` | `PairMatch.hpp`, the pair-shared descriptor match | `cv::BFMatcher::knnMatch(query, train, 2)`, in both directions | same `DMatch` lists, distance bits included, for float L2 and packed-bit Hamming sets with many equal distances, all-equal rows and overflowing sums; through `knn2` and its cache |
| `akaze_bench` | `forEachNonzero` in `AKAZEDetector.cpp` | the dense scans it replaced, inlined in the harness | same kept maps and keypoints over random level sets |

```bash
./build.sh -O2                      # or -O3 / -Os; add -fsanitize=address,undefined for the sanitiser run
./median_bench sweep 3000           # exit 1 on any difference
./median_bench synthtime
./median_bench real a.tiff b.tiff … # >= 2 frames; a 64-row band of each
./warp_bench sweep 2000
./warp_bench time
./remap_bench sweep 900
./blur_bench sweep 2000
./match_bench sweep 400
./match_bench time
./remap_bench time                # a smooth cloud field; `time rough` for a noisy one
./akaze_bench 90
```

The same checks run in the suite as `MedianKernelEquivalenceTests`, `ExactWarpEquivalenceTests` and
`CloudAwareMergeTests.testTheExactRemapMakesTheSameMerge` and `PairMatchEquivalenceTests` (StarCppBridgeTests), through the `ia_debug_set_median_kernel` / `ia_debug_set_exact_warp` hooks;
these are for when a kernel is being changed and a few thousand cases are not enough, or when the
speed is the question. Mutation-test a change to a kernel here before trusting a clean sweep:
remove the near-tie fallback and `median_bench sweep` must fail.

Timing on this machine is noisy whenever the user's own job is running (load average 50–70 was
normal while these were written): compare ratios from one run, never absolute numbers between runs.
