# GPU Work — Implementation Guide

A handoff document. `GPU_ACCELERATION_PROPOSAL.md` says *what* to build and shows the
measurements that justify it; this says *how*, and lists the things that cost me time so
they do not cost you any.

Read `GPU_ACCELERATION_PROPOSAL.md` first. Everything here assumes its §3 (where the time
goes), §4 (the GPU measurements) and §5 (the tiers).

---

## 0. Before you write anything

### Environment

- **A fresh worktree needs three gitignored artifacts symlinked in** or nothing builds:
  `opencv/lib`, `StarDecisionTrees/{include,lib}`, and `gui/videos` (the last only for the
  gui). Point them at the main checkout:
  ```bash
  ln -s /Users/brian/git/nighttime_timelapse_airplane_remover/gui/videos gui/videos
  ```
  Each missing one fails differently and none of the messages say "missing symlink".
- **Build the cli with `swift build -c release --package-path cli`, never with
  `cli/star.xcodeproj`** — that project hits an `ld` assertion under the current
  Xcode/SDK, at HEAD, unrelated to your changes.
- **The gui builds with `xcodebuild -scheme star`, never `-target Star`.**
- **The offline Metal toolchain is not installed on this machine.** `xcrun metal` fails
  with `missing Metal Toolchain`. Either install it —
  `xcodebuild -downloadComponent MetalToolchain` — or compile kernels at runtime with
  `device.makeLibrary(source:options:)`, which is what the benchmarks in this session did.
  **Shipping wants a precompiled `.metallib`**, so installing it becomes a build
  prerequisite alongside opencv and StarDecisionTrees. Decide this early; it changes the
  build scripts.

### Measure in core-seconds, not wall clock

This is the single most important habit for this codebase.

A real run holds `numberOfFramesToProcessConcurrently` (= `PhysicalCores.count`, 18 here)
frames in flight, so the machine is saturated and a stage's true price is the CPU it
consumes. `warpPerspective` measures 117 ms wall on an idle machine and costs **3076
core-ms**. An isolated benchmark that only *redistributes* CPU will look like a win and
deliver nothing; one that *removes* CPU shows up end to end.

End-to-end wall clock has a ~90 s noise floor on this machine and cannot resolve anything
smaller. Two identical 20-frame runs came in at 321 s and 413 s. Check `peak compressor`
before trusting any run; above ~10 GB that run is an artifact.

### Do not use OpenCV's OpenCL T-API

The vendored OpenCV reports `HAVE_OPENCL` and sees the Vega as a device, so it looks
available. It is not usable: `cv::UMat` uploads measured **41 MB/s** (644 MB took 15.6 s)
and the SIFT-shaped pyramid through the T-API was *slower* than the CPU. Metal moved the
same 644 MB in 58.8 ms. `opencv/build.sh` also passes `-DWITH_OPENCL=OFF -DWITH_CUDA=OFF`
for the Linux/Windows builds, so it is not there either. Write Metal.

---

## 1. The shape to build

Put a narrow C interface in `StarCpp/Sources/StarCpp/include/` alongside `ImageAligner.h`,
with **a CPU implementation that always exists** and a Metal backend chosen at runtime.
Roughly six entry points:

```
gpu_warp(src, H, dst)                  // replaces warpInto
gpu_warp_coverage(probe, H, dst)       // replaces warpCoverage
gpu_sigma_clip_median(srcs, n, k, misses, dst)   // replaces medianMergeTyped
gpu_gaussian_pyramid(base, sigmas, octaves)      // Tier 2
gpu_dog_extrema(pyramid)                         // Tier 2
gpu_available()                                  // runtime probe
```

`Config` gets a tri-state `useGPU` next to the existing knobs, following
`writeOutputFiles`'s pattern (nil / true / false, with a `--no-` form on the cli).

**Keep the CPU path forever, not just during the port.** It is the reference every GPU
result is diffed against, and it is the fallback on a machine with no usable device.

A new `Config` stored property costs more than it looks: see §6.

---

## 2. Tier 1 — warp, coverage, sigma-clip median

The three functions live together in `StarCpp/Sources/StarCpp/ImageAligner.cpp`:

| what | where | measured cost |
|---|---|---|
| `warpInto` | ~line 1614 | 3076 core-ms per neighbour at 42MP |
| `warpCoverage` | just below it | ~1/6 of that (8U 1-channel) |
| `medianMergeTyped` | ~line 236 | 9100 core-ms, 9 sources at 42MP |
| `ia_align_and_median_merge` | ~line 1674 | the caller that fuses them |

Metal measurements to aim at: warp **0.99 ms**, 9-source median **100 ms**, 17-source
median **567 ms**.

### This tier can be bit-identical. Make it so.

`warpInto` is `cv::warpPerspective(..., INTER_LINEAR, BORDER_TRANSPARENT)` over a
pre-zeroed destination. OpenCV's `remapBilinear` is **fixed-point integer arithmetic**
(5-bit fractional coefficients), not float, so a Metal kernel that reproduces that integer
arithmetic reproduces the output byte for byte. Do not write a float bilinear kernel and
hope; port the fixed-point one.

Two behaviours in `warpInto` that are load-bearing and documented at length in its comment
— read it before touching anything:
- `BORDER_TRANSPARENT`, not `BORDER_CONSTANT`. Constant leaves a dim one-pixel fringe at
  the frame edge (measured down to 70% brightness across three columns) which the merge
  cannot distinguish from data.
- Zero means "this neighbour has no sample here" to the merge downstream. Every
  destination pixel the warp does not reach must end up exactly zero.

`warpCoverage` must stay *exactly* consistent with `warpInto`'s untouched set — it derives
coverage by running the identical call over a solid probe rather than by reimplementing
the boundary rule. Your GPU version must preserve that property: derive coverage from the
same kernel, do not compute the quadrilateral analytically.

### The merge kernel's one real decision

`medianMergeTyped` uses `double` Welford for mean/variance. **Apple Silicon GPUs have no
fp64 at all**, so this cannot be ported as written. The right answer is not to emulate it
but to replace it with exact integer arithmetic: with n ≤ 17 and values ≤ 65535, the sum
fits in `uint32` and the sum of squares in `uint64`, both exact.

**This changes output.** The 2026-08-23 measurement of exactly this swap: 4 samples
changed in 126.5 M, 1 of 20 frames, max delta 26368 of 65535. It was rejected then because
it bought no measurable speed. At 91x it is a different trade — but it is a real output
change and needs signing off, not slipping in. Say so explicitly in the PR.

Read the long comment inside `medianMergeTyped` about `minIndex`/`CoverageMisses` before
you port it. Two separate bugs are encoded in that logic (a black border down one edge of
first/last frames, and cars printed into a static earth merge) and both are easy to
reintroduce.

### Proving bit-identity

Build a standalone binary that **`#include`s the real `.cpp`** so the kernel under test is
the shipped one, alongside the pre-change kernel textually renamed into its own namespace,
and diff their outputs:

```bash
clang++ -std=c++17 -O3 -DNDEBUG -arch x86_64 \
  -I opencv/include -I opencv/include/opencv2 \
  -I <abs-repo>/StarCpp/Sources/StarCpp -I <abs-repo>/StarCpp/Sources/StarCpp/include \
  verify.cpp starcpp_bridge_logging.cpp MatWrapper.cpp ImageCache_C.cpp OCVFeatureSet.cpp \
  -o verify opencv/lib/macos/libopencv2.a \
  -framework Accelerate -framework OpenCL -framework CoreFoundation \
  -framework CoreGraphics -framework Foundation -lz
```

Three traps in that line, all of which cost real time:
- **`-I opencv/include` plus a relative `#include "../../StarCpp/..."` resolves through
  the opencv symlink into the MAIN repo**, silently testing the unmodified file. Use an
  absolute path in the `#include`. This is not hypothetical; it has happened.
- `-framework OpenCL` is required or the link fails on ~200 `cl*` symbols, even though you
  are not using OpenCL.
- Build with **no `-march`**. The shipped build has none, so `-march=native` measures a
  machine your users do not have.

For output equivalence the full run is still the right instrument — a kernel benchmark
once missed a 4-sample difference that only appeared with the 9-source star merge running.

---

## 3. Tier 2 — the scale-space pyramids

~96 core-s/frame before Tier 0's changes, ~77 after. Two pieces:

- **SIFT's Gaussian pyramid** (sky). `ia_find_features`, the `AlignmentTypeSky` branch.
  At 42 MP `cv::SIFT` upsamples 2x first (`firstOctave = -1`), so the scale space base is
  15904x10608 CV_32F = 644 MB, 12 octaves x 6 layers = 55 blurs over 1125 MP. Build the
  pyramid and the DoG on the GPU, read back the extrema, and **keep OpenCV's orientation
  and descriptor code on the CPU** — those are O(keypoints), not O(pixels), and are not
  the cost. `MPSImageGaussianBlur` does 168 MP in 17 ms; the whole pyramid measured
  **183 ms against 29,672 core-ms**.
- **AKAZE's nonlinear diffusion pyramid** (earth), the `AlignmentTypeEarth` branch. Same
  shape, more work: the FED solver is an explicit stencil, straightforwardly a compute
  kernel, but there is no MPS primitive — it has to be written.

### This tier cannot be bit-identical, so validate on behaviour

Keypoint positions will shift in the last decimal, homographies move, everything
downstream moves. Use the `homography.db` replay, which is already built and proven:

1. Run the cli with `--keep-temp-files` on a short sequence. **Earth homographies only
   exist for `--moving-camera` runs** (`config.tripodHeadWasMoving` gates them) — a static
   run writes no `earth` rows and no `<n>.earth.yaml`.
2. `star_temp_<name>/homography.db` is SQLite; the `data` column is JSON
   (`HomographyResultsCodable`). `star_temp_<name>/keypoints/<n>.{sky,earth}.yaml` holds
   keypoints and descriptors, loadable with `cv::FileStorage`.
3. Replay each stored matrix from the cached keypoints, calling the shipped estimator by
   `#include`ing `ImageAligner.cpp`. Reproduce the matching exactly: `NORM_L2` for sky
   (SIFT), **`NORM_HAMMING` for earth** (AKAZE MLDB), `knnMatch(.., 2)`, Lowe at 0.75,
   `cv::theRNG() = cv::RNG((uint64_t)base * 2654435761ULL ^ (uint64_t)neighbor)`.
4. **Phase correlation over the region the keypoints occupy is independent ground truth.**
   That is what turned the ground-fit investigation from an argument into a measurement.

A worked example of all four steps is in this session's scratchpad as `replay.cpp`; it
reproduced 72 of 76 stored matrices to <0.01 px, and the 4 it did not were exactly the ones
the db marked `UsedExistingHomography` — i.e. written by the smoothing stage, not the
aligner. **That correspondence is the check**: a stored matrix that does not reproduce was
written by something other than the aligner.

`HomographyReciprocity` and the recompute harness are the other two instruments.

---

## 4. Memory, concurrency and the GPU as a shared resource

- **The GPU is one resource shared by 18 concurrent frames.** Serialise work through a
  single queue with bounded in-flight buffers, or you will move the memory-pressure
  problem from RAM to VRAM and gain nothing.
- `MTLDevice.maxBufferLength` is **3584 MB** on this Vega. The 17-source static earth
  merge is 4.1 GB and must be chunked. The 9-source star merge (2.17 GB) fits.
- Max texture dimension is **16384**. SIFT's 2x-upsampled base at 42 MP is 15904x10608 —
  it *just* fits. A 61 MP body (19008x12672 doubled) does not. Tile, use buffers instead of
  textures, or skip the doubling.
- VRAM has to join the existing accounting. `MemoryMonitor`'s reservation ledger governs
  system RAM and already runs ~3x ahead of real footprint; VRAM is a second, smaller,
  separate pool and a merge that fits in 128 GB may not fit in 16 GB.
- **Route blocking native calls through `await NativeWork.run { ... }`** (`StarCore/NativeWork.swift`),
  not directly. The per-frame workers are actors; a direct OpenCV/Metal call from one
  blocks a cooperative-pool thread, and that pool is only core-count wide. Measured at 3x
  the limit in flight, async work kept 83% of its unloaded tick rate via `NativeWork`
  against 42% blocking cooperative threads.
- Offloading from an actor **adds a suspension point**. Actors are reentrant, so re-check
  anything that reads actor state, does the native call, then writes back.
  `HorizonAccumulator.finalize` needed an `isFinalizing` flag for exactly this — without it
  a mask arriving mid-finalize vanished silently.
- On Apple Silicon `hasUnifiedMemory` is true and the transfer term disappears; use
  `makeBuffer(bytesNoCopy:)` (0.3 ms to wrap 644 MB) rather than a blit. On this Vega,
  shared→private blit runs at 11.5 GB/s, so a 241 MB frame costs 22 ms.

---

## 5. What not to put on the GPU

Measured, not assumed:

- **`FullFrameBlobber`.** It sorts every above-threshold pixel by brightness and
  flood-fills from the brightest down, so the result depends on visit order. A parallel
  connected-components pass is a *different algorithm* with different output, and the
  decision trees are trained on the current one. It does have a real performance problem —
  it `await`s the `PixelStatusTracker` actor once per pixel inside a serial loop — but the
  fix is Swift data-structure work, not a GPU.
- **The DP horizon** (`PixelatedImageBridge.cpp` ~line 780). The column scan is inherently
  sequential.
- **TIFF decode.** 515 ms/frame warm, ~1.07 s cold off the external SSD; device-bound.
- **Matching and RANSAC.** ~0.2 core-s per pair at 2000x2000x128. Real, but a rounding
  error next to detection.
- **Small-kernel `dilate` and `GaussianBlur`.** Measured *slower* on the GPU (0.88x,
  0.36x) — launch overhead dominates. Only fuse them into a chain already resident on the
  GPU; never round-trip for one of them.

---

## 6. Codebase traps that will bite you

- **A new `Config` stored property lives in 7 places**: the hand-written decoder in
  `Config.swift`, the gui viewModel + FocusedField + settings view, the daemon `Mapping.swift`,
  both protos, the Kotlin dialog, and 22 i18n catalogues. The decoder is the one that
  silently breaks things: **encoding is synthesized, so every stored property is written,
  and any property not read back in the hand-written decoder round-trips to its default
  and then gets persisted over the real value.** That had happened to 16 of 93 properties.
  `ConfigRoundTripTests` enumerates them with `Mirror` and will fail you — run
  `swift test --package-path StarCore --filter ConfigRoundTrip` after adding one.
- **`opencv/include/opencv2/cvconfig.h` defines `HAVE_PTHREADS_PF` and not `HAVE_GCD`, and
  the archive exports both backends. GCD is the one selected at runtime.** Symbol
  archaeology gives the wrong answer; run a probe. Consequence: `cv::setNumThreads(N)` is a
  no-op for N>1 in this build — only N=1 works — so a hot loop inside `cv::parallel_for_`
  cannot have its worker count bounded from Star.
- **`cv::Mat` arithmetic chains allocate a full-frame temporary per operation**, and
  `convertTo(x, CV_32F)` on an already-CV_32F mat is a full copy that does nothing.
- `cv::imwrite` defaults to LZW with a horizontal predictor, so no file star writes can
  take a direct-read fast path — only input originals.
- Adding a file to `StarCore/Sources` can leave `swift test --package-path daemon` claiming
  the new symbol is not in scope; a plain `swift build --package-path daemon` first clears
  it. Stale SwiftPM cache, not a real error.
- Grepping `.subtract(` mostly finds `Set.subtract` on pixel sets, not the image op. Check
  call counts, not call sites.

---

## 7. Suggested order, and how to know you are winning

1. **Tier 1 skeleton**: the interface, the runtime probe, `Config.useGPU`, and the CPU
   fallback — with `gpu_warp` as the only implemented op. Prove bit-identity with §2's
   harness. This establishes the plumbing under a workload where correctness is checkable
   byte for byte.
2. **`gpu_warp_coverage`, then `gpu_sigma_clip_median`.** Keep all 9 sources resident on
   the GPU for a merge: one upload (~190 ms) and one download (22 ms) per merge rather than
   per op. Get the integer-arithmetic decision signed off.
3. **Measure a full run** and re-baseline before going further. Tier 0 already took a chunk
   of the keypoint cost; Tier 2 may be worth less than the proposal's numbers suggest.
4. **Tier 2**: SIFT pyramid, then AKAZE diffusion, validated with §3's replay.
5. Only then consider a second backend (CUDA for Linux/Windows + NVIDIA, or Vulkan for
   one kernel set everywhere), driven by where users actually are.

Numbers to beat, all at 42 MP on the iMac Pro, all core-ms:

| | CPU now | Metal measured |
|---|---|---|
| warp, one neighbour | 3,076 | 0.99 ms |
| sigma-clip median, 9 sources | 9,100 | 100 ms |
| SIFT-shaped pyramid | 29,672 | 183 ms |

The warp at 0.99 ms is 482 MB of traffic = 487 GB/s, i.e. already at this card's HBM2
bandwidth limit. There is no headroom left there; if you are slower than that, the kernel
is wrong, and if you think you are faster, you are mismeasuring.
