# heap-hunt: the 0.12.6 nano-zone heap corruption (#108, #130)

macOS gui 0.12.6 aborted with `nanov2_guard_corruption_detected` during star-aligned horizon mask warps on a9-2
frame ~611. **#108 is not fixed: the writer has not been found.** Nothing in this directory is a fix.

`StarAlignedHorizonMaskTests.testConcurrentFullFrameMasksAlongsideOtherNativeWorkKeepTheHeapIntact` is the
stress test: 12 concurrent 6000x4000 masks with real a9-2 frame-611 homographies, plus downscales, distance
transforms and 16-bit warps on `NativeWork`. It asserts every concurrent mask byte-equals the lone computation.

## Scripts

Every build and test run goes through `starpipe heavy`. The scratch dir is `.heap-hunt-scratch/` (git-ignored,
override with `HEAP_HUNT_SCRATCH`). Both take an optional `Class/testName`.

- `asan-xctest.sh`: `swift build -c release --build-tests --sanitize=address -Xswiftc -enable-testing`, then runs
  the real `xctest` binary through a wrapper that exports `DYLD_INSERT_LIBRARIES` (the toolchain's ASan runtime,
  copied to the scratch dir and ad-hoc re-signed, because the copy in this Mac's Xcode is rejected with
  "Sanitizer load violates platform policy") and `MallocNanoZone=0`. The wrapper is `#!/bin/sh` and the target
  is the real binary from `xcrun -f xctest`: SIP strips `DYLD_*` through `xcrun` and `#!/bin/bash`.
  First build ~4.5 min, whole script ~12 min.
- `gmalloc-xctest.sh`: debug build, runs under `/usr/lib/libgmalloc.dylib` with `MALLOC_PROTECT_BEFORE=1`,
  `MALLOC_FILL_SPACE=1`, `MallocNanoZone=0`. libgmalloc at full size is impractically slow, so the test reads
  `STAR_HEAP_HUNT_SCALE` (default 1 in the test; the script defaults it to 8: 750x500 frames, 2 masks).

- `replay-cli-asan.sh <input-dir> <first> <last>`: copies a window of a real sequence to the scratch dir and runs the
  release cli over it under ASan (`--moving-camera --no-use-gpu`), so every line of StarCore and StarCpp on the real
  composite path is instrumented, not just the mask/warp workload. Tens of minutes for 29 frames of a9-2, plus a ~3 min
  build. Needs ~4 GB of scratch for the frames and ~20 GB for the cli's own temp/output siblings; delete
  `.heap-hunt-scratch/` after.
- `HeapHuntDistanceTransformTests` (opt-in: `STAR_HEAP_HUNT_DT=1`, otherwise skipped): `raiseMaskBy` (the IPP distance
  transform) at 6000x4000 and odd sizes. Run it with
  `STAR_HEAP_HUNT_DT=1 tools/heap-hunt/gmalloc-xctest.sh HeapHuntDistanceTransformTests/testGradientMasksAtFullAndOddSizes`
  (~6 min under libgmalloc: few allocations, so full size is affordable).

Normal debug run used for the third result below:

    cd StarCore && MallocNanoZone=0 MallocScribble=1 MallocGuardEdges=1 \
      ../pipeline/bin/starpipe heavy -- swift test --filter StarAlignedHorizonMaskTests/testConcurrentFullFrameMasksAlongsideOtherNativeWorkKeepTheHeapIntact

## Results (2026-11-04, x86_64 iMac Pro, `useGPUForMerge` not involved)

| Run | Result |
| --- | --- |
| debug, `MallocNanoZone=0 MallocScribble=1 MallocGuardEdges=1`, full size | passed (82 s) |
| `asan-xctest.sh`: release + ASan, `MallocNanoZone=0`, full size | passed (51 s), no ASan report |
| `gmalloc-xctest.sh`: debug + libgmalloc, scale 8 | passed (23 s), no report |

Earlier on #108 (from its notes): debug under libmalloc with `CheckHeapEach=500`, and release ASan, also passed.

Second pass (2026-11-05, current develop, i.e. including `ExactWarp`/`BoxBlur`/`MedianMerge`, CPU merge):

| Run | Result |
| --- | --- |
| `gmalloc-xctest.sh HeapHuntDistanceTransformTests/...` with `STAR_HEAP_HUNT_DT=1`: `raiseMaskBy` at 6000x4000, 6001x4001, 5999x3999, 4096x2731, 6000x1, 1x4000 and nine small odd sizes, wavy horizon and all-sky, debug + libgmalloc, full size | passed (349 s), no guard-page fault |
| `replay-cli-asan.sh /sp/tmp/LRT_03_16_2024-a9-2-aurora-topaz 591 619`: real a9-2 frames 591-619 through the whole cli (alignment, horizon, star-aligned masks, composite), release + ASan, `MallocNanoZone=0` | finished (exit 0, `done`, run marker cleared), no ASan report, no `FATAL`; 29 full-size masks over 8 homographies, 0 cache hits, the crash's exact pattern |

The replay's first attempt stopped on one `container-overflow` at `medianImageFromMats` (`ImageAligner.cpp:81`, called
from `ia_align_and_median_merge`, `mats.insert(...)` into reserved capacity). It is a false positive and the replay
script turns that check off. The read is `mats[i].rows` inside `for (i = 1; i < mats.size(); ++i)`, so it is in bounds;
ASan believed the vector had size 1 because the linker coalesced OpenCV's **uninstrumented** copy of
`std::vector<cv::Mat>::__insert_with_size<__wrap_iter<cv::Mat*>, ...>` (exported from `solvepnp.o` and `matchers.o`
in libopencv2.a) over Star's. Disassembling the copy in the instrumented binary shows calls to `operator new`,
`operator delete`, `memcpy`, `bzero` and `_Unwind_Resume` and none to `__sanitizer_annotate_contiguous_container` or
`__asan_report_*`, so it never unpoisoned the capacity. A minimal program built from the same toolchain with the same
reserve/push_back/insert does not report (the toolchain's own annotations work: a read past size fires), so this is
the mixed-instrumentation link, not libc++. The same applies to any other `std::vector<cv::Mat>` insert in Star.

No corruption was reported by any run, so no follow-up was filed for the first pass; see below for what is left.

## Ruled out

- Swift lifetime of the throwaway `hMat` in `warpedAsHorizonMask` (optimised ASan: no use-after-free).
- `MatWrapperImpl` adopt/alias; `BufferHolder.toMat` (clones); the three non-owning wrappers over Swift arrays
  (all clone inside the closure).
- `ExactWarp`, `BoxBlur`, `MedianMerge`: all landed after 0.12.6 (2026-10-27); the 2026-11-05 replay ran on a tree
  that has them and was clean.
- `pib_warp_horizon_mask` / `pib_warp_image` (`PixelatedImageBridge.cpp`): plain `cv::warpPerspective` into a local
  `cv::Mat`, no manual buffer writes.
- The mask/warp/downscale/distance-transform workload at 12-way concurrency, by the runs above. Caveat: ASan
  cannot instrument gas-assembled objects, and the full-workload libgmalloc run was at 1/8 scale.
- Every line of StarCore and StarCpp on the real composite path over 29 real a9-2 frames (the replay above): no
  ASan report. Caveat: OpenCV and IPP are uninstrumented, and 29 frames is far fewer than the 611 before the crash.

## Thread 42 identified

`.LLOOP_4Agas_1` in the crash report (`Star+34497979`, no caller frames, queue `star.native-work`) is the inner loop
of IPP ICV's distance transform. `nm -A libopencv2.a | grep .LLOOP_4Agas_1` finds it in exactly three objects,
`ipcvdisttransm7as_l9.o`, `_y8.o` and `_k0.o` (the AVX2, SSE4.2 and AVX-512 variants of `ippiDistanceTransform`). Star
reaches it only through `cv::distanceTransform(src, dist, DIST_L2, 3)`, which OpenCV routes to
`ippiDistanceTransform_3x3_8u32f_C1R`: `createGradientMaskIntoSky/IntoGround` (`raiseMaskBy`, so the feathered horizon
of every frame) and the sky erosions in the keypoint code (`ImageAligner.cpp` `awayFromMaskEdge`, `skyHorizonExtension`).
The empty backtrace is just IPP's frame-pointer-free asm: the thread was computing, not unwinding from a fault. It
sat beside the warps; nothing says it wrote anything. The guard-page run above found no overrun at full size. The
crashed binary (UUID `7e9a74ee-1d55-37d1-a7ae-1f9033224449`) is not on this Mac (the installed 0.12.6 is
`69649C4E-...`, a different link, and stripped), so the offset could not be resolved by address; the label is what
identifies it. The crash report shows no Metal or GPU-merge frame on any thread.

## Still open

1. **The GPU merge path has never been in a run here.** CLAUDE.md forbids it on this Mac, and the gui's default is on
   wherever a GPU is detected. The Metal pooled buffers behind `mat_wrapper_create_external` are a native writer that
   shares memory with Mats. Run `STAR_REPLAY_ARGS="--moving-camera --use-gpu" tools/heap-hunt/replay-cli-asan.sh ...`
   on a machine that can (CI, another Mac).
2. The corruption may predate frame 611 by many frames (the nano zone is only checked when something walks into it).
   Frames are 145 MB, so a window from frame 1 does not fit on this disk; use a downscaled copy of the sequence
   (not below ~2000 px wide: smaller and no neighbour alignment validates) and a longer window.
3. ASan cannot see writes by OpenCV's own code or IPP. On real data only libgmalloc can, and a whole-cli replay
   under it is hours; try a short window (9-12 frames).

**#108 stays open.**
