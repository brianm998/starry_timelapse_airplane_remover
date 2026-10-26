# Where more GPU support could go — survey, 2026-10-25

Companion to `GPU_ACCELERATION_PROPOSAL.md` (the 2026-09 measurements) and
`GPU_IMPLEMENTATION_GUIDE.md`. This is a survey, not a plan that has been
executed: nothing here has been built or measured unless it says so.

## 1. What exists today

| | macOS | Linux | Windows |
|---|---|---|---|
| Aligned merge (warps + coverage + sigma-clip median, one dispatch) | Metal, on by default | CPU | CPU |
| SIFT Gaussian pyramid (sky keypoints) | Metal, on by default | CPU (`cv::SIFT`) | CPU |
| AKAZE nonlinear pyramid (earth keypoints) | Metal, on by default | CPU (`cv::AKAZE`) | CPU |
| Video encode | VideoToolbox (shipped) | NVENC built but not shipped | NVENC/AMF built but not shipped |
| Video decode | opt-in via `STAR_FFMPEG_HWACCEL` | same | same |

The seam is `StarCpp/Sources/StarCpp/include/GPUOps_C.h`: five C function
pointers (`warp`, `medianMerge`, `alignedMerge`, `siftPyramid`, `akazePyramid`)
registered once at startup, every one of which may return `false` and hand the
work back to the CPU path that always exists. `GPUCapability.isAvailable()` is
the single place that says "macOS only". The Metal backend is 2,400 lines of
Swift in `StarCppBridge/GPUOps.swift` with the kernels as MSL source strings
compiled at runtime (no offline Metal toolchain on this Mac).

Two facts that shape everything below:

- **All five kernels are float32 or integer.** The merge dropped `double`
  Welford for an exact-integer/float formulation on purpose (Apple GPUs have no
  fp64) and no kernel uses 64-bit integers or atomics. That is exactly the
  subset WGSL and SPIR-V compute support everywhere, so the kernels port to a
  cross-platform API without redesign.
- **The GitHub macOS runners do get a Metal device.** The repo's own CI already
  runs the Metal paths there (the 2026-10-23 keypoint-memory crawl on the
  macos-15 runner was the Metal texture pools, see memory
  `blob-stage-ci-coverage`). So the macOS GPU code is covered by CI today.

## 2. macOS: what is still on the CPU and worth considering

Measured on the Vega (`gpu-slot-time-breakdown`, 2026-10-22, 19 x 12MP):
horizon 27 s, keypoints 65 s, validation 5 s, merges 32 s of a 136 s run. Inside
`withGPUSlot` the GPU is 0-2% busy; the rest is Metal alloc/free, de-tile
readback and memcpy staging. So on this machine the next wins are not new
kernels but less CPU-side Metal churn. On the incoming Apple Silicon Mac Studio
(`hasUnifiedMemory` true) the staging copies disappear, and the balance shifts
back toward "what else can run on the GPU". In rough order of expected payoff:

1. **Keep the SIFT pipeline resident after the pyramid.** `SIFTDetector.cpp`
   reads all `nOctaves*(nOctaveLayers+3)` float layers back (the triple-pass
   de-tile readback that is 13-20% of slot time), then does DoG subtraction and
   the extremum scan on the CPU in `cv::parallel_for_`. Its own comment says
   that tail "was no longer negligible once the pyramid was on the GPU". DoG +
   3x3x3 extremum test + a compacted candidate list is an easy kernel, and it
   would cut the readback to the candidate list plus the layers the orientation
   and descriptor steps still sample. Validation is the existing
   `ia_debug_sift_reference` vs `ia_debug_sift_gpu` comparison (positions within
   0.005 px, 1792 vs 1791 keypoints on the a9 frame).
2. **Same for AKAZE:** `computeDeterminantHessianResponse` (Scharr second
   derivatives per level, already has Scharr kernels on the GPU) and the
   extrema search, before the MLDB descriptor. Same shape as item 1, same
   validation (`ia_debug_akaze_*`).
3. **Readback as a single blit, not per layer.** Independent of 1 and 2 and
   smaller: the 48-texture pyramid comes back one texture at a time. A single
   `MTLBlitCommandEncoder` into one managed buffer removes most of the
   `getBytes` de-tile cost listed in the breakdown.
4. **The horizon stage (27 s of 136 s, all CPU).** Several full-frame OpenCV
   calls per frame in `ImageAligner.cpp` and `PixelatedImageBridge.cpp`:
   `distanceTransform` for the gradient masks (x4), `cvtColor` (x38),
   `connectedComponentsWithStats`, `Canny`, `Sobel`, `morphologyEx`, and the
   Random Walker's multi-scale Gauss-Seidel solve in `RandomWalkerHorizon.cpp`.
   Gauss-Seidel is a textbook GPU fit as red-black Jacobi, but the memory notes
   (`horizon-temporal-static-and-working-size`) say moving detection now runs
   at 1600 px wide, so measure the stage's per-op cost first; a 1600 px solve
   may not be worth a round trip. The small-kernel `dilate`/`GaussianBlur`
   round trips measured slower on the GPU (0.88x, 0.36x) and that still holds.
5. **Cloud-aware merge** (`cloudAwareMerge`, off by default, prototype in
   `CloudAwareMergeTests`): a tile motion field plus a second median merge. If
   it ships, its merge belongs in the same aligned-merge kernel family.

Not worth it, unchanged from the proposal: `FullFrameBlobber` (order-dependent
flood fill the decision trees were trained on), the DP horizon refiner, TIFF
decode, matching/RANSAC.

## 3. Windows and Linux: the API choice

The constraint is the stack: the compute side is pure C++ (`StarCpp`, no
ObjC++), called from Swift on all three platforms, with OpenCV vendored and
built with `-DWITH_OPENCL=OFF -DWITH_CUDA=OFF`. The daemon (`stard`) and the
cli are what run off macOS; the Kotlin client never touches pixels.

| Option | Reach | Fit with this stack | Verdict |
|---|---|---|---|
| **wgpu-native (WebGPU C API)** | Vulkan on Linux, D3D12 on Windows, Metal on macOS; prebuilt static/shared libs for linux-x86_64/aarch64, windows-x86_64-msvc, macos-x86_64/aarch64 (v29.0.1.1, 2026-06-23) | A plain C header the C++ bridge can call directly; kernels in WGSL, one source for every platform; no SDK install for users (the loader finds the driver at run time) | **Recommended** |
| Vulkan directly | Linux + Windows (MoltenVK on macOS) | C API, but shaders need SPIR-V (a glslc/`slangc` build step), and a lot more boilerplate (descriptor sets, memory types, sync) than the Metal code has now | Second choice; only if wgpu's abstraction costs performance it should not |
| OpenCV CUDA modules (`cudawarping`, `cudafilters`) | NVIDIA only | Rebuild of the vendored OpenCV per platform with the CUDA toolkit; AMD and Intel users get nothing | No |
| OpenCL T-API | all | Measured unusable on macOS (41 MB/s uploads), compiled out elsewhere | No |
| D3D12 directly | Windows only | Yet another kernel language (HLSL) | No |

Why wgpu-native fits unusually well here:

- The C++ bridge already treats the GPU as "a registered function pointer that
  may say no". A `GPUOps_wgpu.cpp` in `StarCpp` registering the same five
  handlers is the whole integration; `GPUCapability.isAvailable()` grows a
  wgpu adapter probe on non-Apple platforms. Config flags, governor accounting
  (`GPUOps.busySeconds`), the user preferences and the Kotlin GPU toggles need
  no change.
- The kernels are the portable subset already (float32, u32, no atomics, no
  fp64). The MSL strings translate to WGSL almost line for line; the only
  real difference is texture vs buffer addressing (the pyramids use textures
  with `reflect-101` done in-kernel, which WGSL handles the same way).
- Shaders compile at run time from WGSL source, which is how the Metal path
  already works, so no new build-time toolchain for either platform.
- Licence is Apache-2.0/MIT, prebuilt per platform, so the Package.swift
  linker settings gain one `-l` per platform the way OpenCV does now.

What would be different from the Metal path and needs deciding up front:

- **Discrete-GPU staging is the common case off macOS**, exactly the Vega
  situation the breakdown found costly. wgpu has mapped staging buffers; the
  pooling the Metal backend grew (`FloatTexturePool`, readback pool) has to be
  rebuilt on that API or the port will reproduce the "GPU idle, CPU copying"
  profile.
- **No unified-memory in-place merge.** The aligned merge's `bindInPlace`
  trick is Apple-only; on Windows/Linux every merge is `bindByCopy`.
- **`maxBufferBindingSize` defaults to 1 GB in WebGPU** and must be raised via
  requested limits; the 17-source earth merge is 4.1 GB at 42MP and already
  has to be chunked on the Vega.
- **Driver spread.** Metal on a Mac is one driver. On Windows/Linux the same
  WGSL runs on NVIDIA/AMD/Intel/Mesa, each with its own float rounding in the
  blur chain; the pyramid tier is validated on behaviour, not bytes, so that is
  survivable, but the warp's fixed-point bilinear path (bit-identical to OpenCV
  today) should keep its exactness test per adapter.

Whether to also move macOS onto wgpu's Metal backend: no, not now. The Metal
code is measured, pooled and bit-identical where it matters; wgpu adds a layer
between it and the device. Keep Metal as the macOS backend and let wgpu be the
"everywhere else" backend behind the same C seam, which the seam was designed
for ("Vulkan compute — the one-kernel-set-everywhere option" in the proposal).

### Video encode: the GPU work that is already done and not shipped

`ffmpeg/build.sh` + `ffmpeg-gpu.yml` build FFmpeg 9 with NVENC/AMF/Vulkan on
Windows and NVENC/Vulkan on Linux, smoke-tested, with the Render Video dialog
already filtering encoders by what the machine has and applying NVENC quality
defaults. The installers still ship `build_ci.sh`'s FFmpeg 7.1.1 with
VideoToolbox only. `ffmpeg/README.md` says the switch is: get `ffmpeg-gpu.yml`
green on all three, then point `cli.yml` and `kotlin-client.yml` at its
artifacts. That is the cheapest "more GPU support on Windows and Linux" in the
repo, and it needs no new code.

## 4. Testing without a Windows or Linux GPU

### GitHub-hosted GPU runners

GitHub's larger-runner catalogue has one GPU size: 4 vCPU, 1 x NVIDIA Tesla T4
(16 GB), 28 GB RAM, 176 GB SSD, Ubuntu or Windows, using partner images (NVIDIA
GPU-Optimized VMI, or the Windows Data Science VM). Larger runners are created
by **organization owners**, require a credit card on file and a non-zero
Actions spending limit, and are billed per minute even for public repos (the
docs do not list the GPU rate; a third-party price table shows about $0.05/min
Linux and $0.10/min Windows). `starry_timelapse_airplane_remover` is owned by
a **personal account on the Free plan**, so GPU runners are not available to it
as it stands. Getting them means moving the repo under an organization on the
Team plan (or higher) and paying per minute. A T4 is NVIDIA-only, so it would
cover the Vulkan/D3D12 driver path for one vendor; AMD and Intel stay untested.

### Software GPU on the standard runners (free, no plan change)

Both wgpu backends have a CPU implementation the loader can be pointed at:

- **Linux: lavapipe/llvmpipe** (`apt install mesa-vulkan-drivers libvulkan1`,
  then `VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json`). Used
  by Dawn's CTS runs, onnxruntime and llama.cpp for exactly this. Slow, not a
  conformant implementation, and llama.cpp hit a hang on one quantised kernel,
  so treat it as a correctness check for small frames, not timing.
- **Windows: WARP**, Microsoft's D3D12 software adapter, shipped with Windows,
  which Microsoft itself presents as the CI route for GPU-less servers. wgpu
  exposes it as the fallback adapter (`forceFallbackAdapter` in the adapter
  request). Known gaps: shader model 6.2 ceiling, reads reported off by a few
  units on some tests, no 64-bit atomics; nothing the current kernels need.

That gives a plan that needs no money: the existing `GPUOpsTests` already skip
when `GPUCapability.isAvailable()` is false, so the same tests run on
ubuntu-24.04 and windows-2022 with the fallback adapter forced, asserting the
warp's bit-identity and the pyramid's keypoint agreement on
`test_data/test_a7sii_10`-sized frames. Real-hardware timing would come from
the user's own machines, or a one-off T4 runner job if the repo moves to an org.

### macOS

Already covered: the macos-14/15 runners expose a Metal device to the VM and
the Metal paths run there in the Gherkin legs today.

## 5. Suggested order

1. Ship the GPU ffmpeg build (no new code; Windows/Linux users get NVENC/AMF).
2. Keep the SIFT and AKAZE pipelines resident through extrema detection on
   Metal, and batch the pyramid readback (§2 items 1-3). Measure on the Mac
   Studio when it arrives, since the Vega numbers will be stale.
3. Add a wgpu-native backend in `StarCpp` behind `GPUOps_C.h` for the aligned
   merge first (bit-identical warp gives a hard pass/fail), then the two
   pyramids; run its tests on lavapipe and WARP in `cli.yml`.
4. Horizon-stage ops only after measuring them at the 1600 px working size.
