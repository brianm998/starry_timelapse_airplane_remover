# R7 on Apple Silicon (M5 Max, 36 GB): results

Branch from `develop` c26c3c5fd. Nothing committed. Order follows section 9 of `R7_APPLE_SILICON_HANDOFF.md`.

## 1. Does the GPU pyramid path run here? Yes.
`makeFloatTexture` asks for `.managed` and Metal returns a `.managed` texture (`storageMode.rawValue == 1`), not nil.
Both builders ran; no change to the storage mode was needed. SIFT `testGPUPyramidAgreesWithTheReferencePyramid`,
`testRecycledPyramidTexturesGiveTheSameKeypoints`, `testGPUPortAgreesWithRealSIFTOnARealisticNightSky` pass.
Two failures on unmodified code, both before any R7 change:
* `AKAZEDetectorTests.testGPUPyramidAgreesWithTheReferencePyramid`: 487 of 501 reference keypoints match, threshold 490
  (deterministic, 487 each run). Likely arm64 FMA differences; not investigated, and not compared against Intel `develop`.
* `GPUBufferLifetimeTests.testRepeatedPyramidBuildsDoNotAccumulateReadbackBuffers` failed once, then passed on three
  reruns (footprint-based, flaky).
Also: `SkyStarRefinementTests.swift` did not type-check under Swift 6.4 (blocked the whole test target); fixed with explicit types.

## What was built
* `mat_wrapper_create_external` (`MatWrapper.cpp/.h`): a `cv::MatAllocator` whose `deallocate` calls a release function,
  so the buffer's lifetime follows OpenCV's refcount, not the wrapper's. `mat_wrapper_has_refcounted_buffer` for tests.
* `GPUOps.swift`: `matWrappers(fromReadbacks:)` builds Mats over the pooled buffers; the release function returns the buffer
  to the pool (pool still keeps at most 2 per size and obeys `poolingAllowed`). Kill switch `STAR_READBACK=copy`
  (`GPUOps.setReadbackCopies` for tests). `readbackPoolCounts()` counters exist but I did not read them in a real run.
* Read-only check: nothing writes a GPU-built level (the in-place `Lt += Lstep` is the CPU branch only; SIFT only reads `gpyr`).
* `Tests/.../ZeroCopyReadbackTests.swift` (6 tests, all pass): every SIFT level byte-identical copy vs zero-copy; levels are
  refcounted and every buffer is returned exactly once; a live pyramid is not overwritten by the next build; SIFT and AKAZE
  keypoint+descriptor files byte-identical both ways; no footprint growth over repeated builds.
Existing GPU suites (SIFT, AKAZE except the above, GPUOpsTests, concurrency stress, MatWrapperTests) pass.

## 3. Footprint harness (release, one op per fresh process, whole-op peak, x working frame; 2 reps, repeats agree to ~0.5x)
| MP | type | divisor | copy | zero-copy |
|----|------|---------|------|-----------|
| 33 | sky | 1 | 78.9-80.9 | 72.4 |
| 33 | sky | 1.5 | 45.2-45.3 | 35.8 |
| 33 | sky | 2 | 25.5-26.4 | 21.0 |
| 42 | sky | 1 | 78.9 | 72.3 |
| 42 | sky | 1.5 | 45.0 | 35.5 |
| 42 | sky | 2 | 26.1-26.2 | 20.9 |
| 33 / 42 | earth (AKAZE) | 1 / 1.5 / 2 | 54-55 / 28-29 / 18-19 | same within noise |
Sky (GPU SIFT) drops by 7 (divisor 1) to ~9.5 (divisor 1.5) working frames; earth does not change. Wall time in the harness is lower
with zero-copy for sky (about 1.1 vs 1.5 s at 1.5) and slightly lower for earth, but single-op times are noisy.
Caveat: the harness's synthetic sky frame yields 0 keypoints (CPU path too), so it measures the pyramid, not a full op.
Two concurrent ops: not measured. `keypointMemoryMultiplier` untouched (section 6); the table above is the evidence for the owner.

## Not done
* Phase-A profile shares (copy memcpy, `makeBuffer`) and the whole-run A/B on a real moving sequence: no night sequence on this
  machine. The pool-miss question (buffers now return late, so `takeReadbackBuffer` may call `makeBuffer` more) is therefore open;
  read `GPUOps.readbackPoolCounts()` in a real run (`made` vs `reused`) before deciding on a bytes cap.
* Homography/final-frame comparison over a real run, `bandLimitedEarthMerge` check, section 8 full `swift test` runs.
* The "no blit at all" follow-up: not attempted.

## Recommendation
Worth keeping: byte-identical output, lower peak on SIFT, no loss on AKAZE. Validate the pool behaviour on a real sequence before merging.
