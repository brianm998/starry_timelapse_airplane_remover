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
No corruption was reported by any run, so no follow-up was filed.

## Ruled out

- Swift lifetime of the throwaway `hMat` in `warpedAsHorizonMask` (optimised ASan: no use-after-free).
- `MatWrapperImpl` adopt/alias; `BufferHolder.toMat` (clones); the three non-owning wrappers over Swift arrays
  (all clone inside the closure).
- `ExactWarp`, `BoxBlur`, `MedianMerge`: all landed after 0.12.6 (2026-10-27).
- `pib_warp_horizon_mask` / `pib_warp_image` (`PixelatedImageBridge.cpp`): plain `cv::warpPerspective` into a local
  `cv::Mat`, no manual buffer writes.
- The mask/warp/downscale/distance-transform workload at 12-way concurrency, by the runs above. Caveat: ASan
  cannot instrument gas-assembled objects, and libgmalloc ran at 1/8 scale, so a size-dependent bug would be missed.

## Still open (need an interactive session; the evidence is outside the pipeline's reach)

1. Identify thread 42's `.LLOOP_4Agas_1` routine from the crash `.ips` image list. gas-assembled objects in the
   static `libopencv2.a` are IPP ICV (`*_as.s.o`), which ASan cannot instrument.
2. Replay a9-2 frames 595-615 through the composite step with real decoded frames, from a copy or scratch run
   (the crashed run's `star_temp` on /sp is 458 GB and must not be mutated).
3. libgmalloc at a larger scale than 8 (try `STAR_HEAP_HUNT_SCALE=2`, expect hours).
4. The corruption may predate frame 611 by many frames; a replay of 595-615 alone may not reproduce it.

**#108 stays open.**
