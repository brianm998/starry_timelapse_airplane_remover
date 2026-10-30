# R7 hand-off: the pyramid readback copy, on Apple Silicon

For whoever (person or Claude session) works on the Apple Silicon Mac. It is written to be read cold.
Everything here comes from `plans/CORE_SPEED_PROPOSAL.md` (section 2 R7, section 1.5, section 6) and from
reading the code on the Intel iMac Pro, where R7 **cannot be judged**: that machine's Vega keeps its textures
`.managed` and its readback goes through a separate `.shared` buffer, and the numbers that matter (memory
footprint, whether the copy is worth removing at all) are Apple Silicon's. Where a statement below is something
I did not verify on any machine, it says so.

Start from `develop` (it has everything up to merge `25e0a47e`, 2026-10-30). Make a worktree under
`.claude/worktrees/<name>` on a branch cut from `develop`.

## 1. What R7 is and why it is worth a day

The GPU SIFT and AKAZE detectors build their scale spaces on the GPU, then **copy every level back into a
fresh `cv::Mat`** so the CPU tail (DoG, extrema, descriptors for SIFT; Hessian, extrema, descriptors for AKAZE)
can read them:

* `GPUOps.swift` `matWrapper(fromReadback:)` (about line 1674): allocates a Mat with `mat_wrapper_new` and
  `memcpy`s the level out of a pooled linear `.shared` `MTLBuffer`, inside an `autoreleasepool`.
* Measured on the iMac (a phase-A profile of 721 k busy samples, GPU SIFT and AKAZE on): that `memcpy` is **8.1 %**
  of phase A for SIFT and **1.7 %** for AKAZE, about ~1.4 GB copied per sky op at detection divisor 1.5.
  Phase A is ~63 minutes of a 1,407-frame run, so ~10 % of it is ~6 minutes.
* The proposal's idea: make the readback buffer the Mat's storage, and give the buffer back to the pool when the
  Mat dies.

**There is a second reason to expect a win on Apple Silicon that the proposal did not have.**
`Config.keypointMemoryMultiplier`'s documentation (`StarCore/Sources/StarCore/Config.swift`, the table near line
546) records that the **GPU SIFT port peaks ~30 % higher than OpenCV's** (sky 53.9× vs 42.3× the working frame at
divisor 1.0) *because its scale space lives in unified-memory buffers on top of what the CPU path holds*. On
unified memory the buffer and its Mat copy are two allocations of the same data. If the Mat is the buffer, that
duplication goes. So here R7 may buy memory as well as time. **Measure it; do not act on it** (section 6).

## 2. The design in the proposal is incomplete: lifetime has to follow OpenCV's refcount

The proposal says "a `cv::Mat` over external memory, owned by a `MatWrapper` with a release callback." That is
not enough, and it would dangle. Look at how the detectors consume the wrapper:

```
SIFTDetector.cpp  ~628-642    gpyr.push_back(ref->mat);  mat_wrapper_release(ref);
AKAZEDetector.cpp ~382-402    evolution[i].Lt = outLt[i]->mat;  evolution[i].Lsmooth = outLsmooth[i]->mat;
                              mat_wrapper_release(outLt[i]);  mat_wrapper_release(outLsmooth[i]);
```

The `cv::Mat` is **copied out of the wrapper and the wrapper is released at once**; the Mat then lives for the
whole CPU tail. A `cv::Mat` constructed over external memory (`cv::Mat(rows, cols, type, data, step)`, which is
what `mat_wrapper_create(takeOwnership: false)` does) has `u == nullptr`, so copies of it **do not extend
anything**: a callback fired when the *wrapper* is released would return the buffer to the pool while the Mats
still point into it, and the next blit would overwrite a pyramid the SIFT tail is reading.

So the buffer's lifetime must be tied to the **Mat's own refcount**:

1. A small `cv::MatAllocator` subclass (one static instance) whose `allocate(...)` returns a `cv::UMatData`
   pointing at the caller's memory (`data = origdata = ptr`, `size`, `userdata` = a heap struct holding the
   release function and its context, and the `USER_ALLOCATED` flag so nothing tries to `free` it) and whose
   `deallocate(u)` calls the release function and deletes the struct and the `UMatData`. `map`/`unmap`/`copy`
   can raise (nothing here uses them). `StdMatAllocator` in `opencv/opencv/modules/core/src/matrix.cpp` is the
   template; `Mat::release()` / `Mat::deallocate()` there show how `u->refcount` drives `deallocate`.
   (The OpenCV 4.12.0 source is in the **main checkout** at `opencv/opencv/`; a worktree has only the
   `include`/`lib`/`opencv2.framework` symlinks. See `[opencv-source-tree-in-repo]` in project memory if you have it.)
2. A new C entry point next to `mat_wrapper_create` (`StarCpp/Sources/StarCpp/MatWrapper.cpp` ~396, header
   `include/MatWrapper.h`), for example
   `MatWrapperRef mat_wrapper_create_external(int64_t width, int64_t height, int cvType, size_t bytesPerRow, void *data, void (*release)(void *context), void *context)`.
3. In `GPUOps.swift`, `matWrapper(fromReadback:)` becomes: retain the `MTLBuffer` (`Unmanaged.passRetained`), pass
   `buffer.contents()` as `data` and a `@convention(c)` release function whose context is that retained buffer;
   the release function hands the buffer to the pool (or lets it go) instead of `giveReadbackBuffers` doing so
   up front. `buildSiftPyramid` / `buildAkazePyramid` currently `defer { giveReadbackBuffers(pending) }`; that
   must stop for buffers whose Mat now owns them.

`MatWrapperImpl::canAdopt` (`MatWrapperImpl.hpp`) wants `m.u != nullptr`, continuous, not a submatrix, refcount 1 to
share a Mat rather than clone it: an allocator-backed Mat satisfies all four, which is what keeps the wrapper from
silently cloning your Mat back into an ordinary buffer. **Check that explicitly in a test** (see section 5).

### Things that bite

* **The release callback runs on whichever thread drops the last reference**: an OpenCV worker, the
  `NativeWork` queue, a Swift task thread. It must not block, must not need the GPU slot, and must take only the
  pool's lock (`readbackPoolLock`).
* **`autoreleasepool` around `contents()`** is not optional. `MTLBuffer.contents()` is an inner pointer; Swift
  retains and autoreleases the buffer to keep it valid, star's worker threads seldom drain a pool, and the result
  was +430 MB per sky op (project memory `gpu-inner-pointer-autorelease-leak`, pinned by `GPUBufferLifetimeTests`).
  You are *keeping* the pointer far longer than that memcpy ever did, so take it inside the pool, retain the buffer
  yourself, and let the callback balance it. Re-run `GPUBufferLifetimeTests` (3 tests) before and after.
* **The pool policy changes meaning.** `giveReadbackBuffers` keeps at most 2 buffers per length and drops them all
  when `GPUOps.poolingAllowed` is false (`MemoryMonitor` turns pooling off while any reservation waits, because on
  unified memory idle pooled buffers are footprint). Today a buffer is back in the pool as soon as the copy is done.
  With R7 it comes back only when the SIFT/AKAZE tail finishes with the level, which on a busy run is seconds to
  minutes later, so `takeReadbackBuffer` will find the pool empty and call `device.makeBuffer` — the cost the pool
  exists to avoid ("a large share of the time spent in a slot", `GPUOps.swift` ~1618). Measure how often that
  happens; the fix may be a bytes cap instead of "2 per size". The release callback must obey `poolingAllowed` too.
* **Does anything write the levels?** SIFT's reference tail only reads `gpyr`. In `AKAZEDetector.cpp` the CPU
  build path writes `Lt`/`Lsmooth` in place (lines ~321-349), but that is the non-GPU branch; on the GPU branch
  `e.Lsmooth.release()` (~line 421) drops a level early (good: its buffer returns mid-op). **Confirm by reading
  that nothing writes a GPU-built level**; a CPU write into a GPU buffer the pool will reuse is a silent
  corruption, and a read-only mapping is not enforced by anything here.
* **A pyramid the CPU still reads is memory the GPU pool can no longer reuse.** Peak footprint per op can go up in
  the window between the GPU finishing and the tail finishing; it can also go down (no Mat copy). Which wins is
  the whole question (section 4).
* **Row stride.** `matWrapper(fromReadback:)` checks `mat_wrapper_step == rowBytes`; the readback buffers are tight
  (`width * 4` bytes a row). Keep the stride exactly that and keep the Mat continuous.

## 3. Step 0 (required first), then an optional bigger change

**Read the Step 0 paragraph below before anything else in this document**: the GPU pyramid builders create
`.managed` textures, which the code itself says Apple Silicon does not have, so the path R7 changes may not run there
yet. The optional "do not blit at all" idea comes after it.

### The optional change: do not blit at all

On Apple Silicon `.shared` textures are correct (the comment on `buildSiftPyramid` says `.managed` was chosen
because a `.shared` *texture* a compute kernel writes read back as zeros **on the Vega**, and to "revisit if this
ever needs to run on Apple Silicon"). There the pyramid levels could be textures created *from* a `.shared` buffer
(`makeTexture(descriptor:offset:bytesPerRow:)`, with `bytesPerRow` meeting
`device.minimumLinearTextureAlignment(for:)`), written by the kernels in place, and the Mat made over the same
buffer: no blit, no copy. That removes `encodeReadbacks` (~line 1649) as well as the memcpy. It is a larger change
with its own alignment and storage-mode traps, and it belongs after R7 proper, behind the same A/B. Treat it as a
follow-up decision for the owner, not part of this hand-off's "done".

### Step 0, before any R7 work: does the GPU pyramid path run on this machine at all?
The pyramid textures are created `.storageModeManaged`, unconditionally: `MetalGPUBackend.makeFloatTexture`
(`GPUOps.swift` ~1602) sets `descriptor.storageMode = .managed`, and `FloatTexturePool` (~225) hands out those
textures. The code's own comments (~235 and ~1120) say Apple Silicon "has no `.managed` and wants `.shared`
here", and the project has never run these builders on Apple Silicon. I did not verify what Metal does with a
`.managed` texture descriptor on this machine (it may fail, return nil, or silently behave as shared). `makeFloatTexture`
returns `MTLTexture?` and the builders return `Bool`, so a failure would most likely show up as `buildSiftPyramid` /
`buildAkazePyramid` returning false and the detector falling back to the CPU path. I did not read how every caller handles
a nil texture. **If that is what happens, R7 is moot until the storage mode is fixed**, and the profile numbers in
section 1 (taken on a Vega with the GPU path running) say nothing about what the Mac does.

So: run `GPUOpsTests`, `SIFTDetectorTests` and `AKAZEDetectorTests` unmodified and check, with a log line or a
breakpoint, that `buildSiftPyramid` and `buildAkazePyramid` return true and the GPU path is the one that ran. If not,
make the texture storage conditional (`device.hasUnifiedMemory` → `.shared`; the merge path already branches on
`unified`, ~948 and ~1019, and is the pattern to follow). The pyramid code never calls `synchronize` on a texture
(the readback is a GPU-side blit from the texture into a `.shared` buffer), so nothing else in it depends on
`.managed`; but the Vega's "`.shared` textures read back as zeros" failure is a Vega fact, so assert on Apple Silicon
that the existing pyramid tests (`testGPUPyramidAgreesWithTheReferencePyramid`) agree with the reference, not just that
a texture was made. Report that as its own finding (section 9, item 1); it is a prerequisite fix, not R7.

## 4. What to measure (and how not to fool yourself)

Lessons from the Intel work that apply directly:

* **Sample the whole run, not a window.** A 25 s `sample` of one phase overstated several kernels 2-5×. Take a
  `sample` window every ~25 s across a whole phase-A run and aggregate top-of-stack by symbol.
* **CPU-seconds of a whole run do not resolve a ~5 % effect** on a shared machine: the same binary differed 15 %
  between repeats. Judge small effects by the profile share and a harness, and alternate A/B runs.
* **A cold page cache doubles a run** (537 s then 248 s, same 60 frames). Alternate A and B on a warm cache; never
  compare the first run.
* **Do not trust `/usr/bin/time -l`'s "real"** on a run that may have been paused; use log timestamps.
* One heavy job at a time on a shared machine, and nice it.

Measurements, in order:

1. **Baseline on `develop`** (before any change): the phase-A profile above on a real moving 24 MP night sequence,
   cli, with `--moving-camera --use-gpu-for-sift --use-gpu-for-akaze` (and `--use-gpu`; `Config` defaults all three on
   whenever a Metal device exists, but pass them so the run says what it ran; `cli --help` has the rest). Confirm
   from the profile that the GPU pyramid builders are on the stack at all (step 0 in section 3). Record the
   share of `matWrapper(fromReadback:)`'s memcpy and of `makeBuffer`.
2. **Footprint harness**, one op per fresh process (`StarCpp/Tests/StarCppBridgeTests/KeypointFootprintMeasurement.swift`):

   ```bash
   STAR_KP_MEASURE=1 STAR_KP_MP=33 STAR_KP_TYPE=sky STAR_KP_GPU=1 STAR_KP_DIVISOR=1.5 \
     swift test -c release --filter KeypointFootprintMeasurement
   ```
   for `sky` and `earth`, `STAR_KP_GPU` 0 and 1, divisors 1, 1.5, 2, and MP 33 and 42. It prints a `KPMEASURE`
   line (peak footprint over the working frame, the unit `keypointMemoryMultiplier` is in). Also two concurrent
   sky ops (the Intel work found 1.7 GB with a fix, 3.2-4.7 GB without).
3. **After R7**, the same three, plus `GPUOpsConcurrencyStressTests`, `GPUBufferLifetimeTests`.
4. A **whole-run A/B** on the same sequence, alternating, warm cache, with the kill switch below.

## 5. How to show it is identical

Output must not change. R7 only changes where bytes live.

* Add a **kill switch**, e.g. `STAR_READBACK=copy` in the environment (read once) and a matching
  `ia_debug_set_...` / `GPUOps` test hook, so one binary can run both ways. The repo has precedents:
  `STAR_WARP=opencv`, `STAR_MATCH=opencv`, `STAR_MEDIAN_KERNEL=welford`, and the `ia_debug_set_exact_warp` /
  `ia_debug_set_pair_match` hooks in `ImageAligner.h` with their Swift wrappers.
* **Per-level byte equality:** build a SIFT pyramid and an AKAZE pyramid both ways from the same image and compare
  every level byte for byte. Also assert the Mats really are allocator-backed (`u != nullptr`) after passing
  through `MatWrapperImpl`, so a future `canAdopt` change cannot make them copies silently.
* **Existing tests that must stay green** (they compare the GPU port to the reference): `SIFTDetectorTests`
  `testGPUPyramidAgreesWithTheReferencePyramid` (~250), `testRecycledPyramidTexturesGiveTheSameKeypoints` (~275),
  `testGPUPortAgreesWithRealSIFTOnARealisticNightSky` (~306); `AKAZEDetectorTests`
  `testGPUPyramidAgreesWithTheReferencePyramid` (~195), `testGPUPortAgreesWithRealAKAZEOnARealisticGround` (~225);
  `GPUBufferLifetimeTests` (~22, ~40, ~62).
* **A real run, both ways:** a 30-60 frame moving sequence through the whole cli with and without the switch.
  Compare the stored homographies *decoded* (`homography.db`, table `homographies(frame_index, type, data)`;
  compare `json.loads(data)`, not bytes, because `JSONEncoder` does not order keys) and the keypoint files and
  the final frames. Identical is the bar.

## 6. What *not* to change

* **`Config.keypointMemoryMultiplier` and `effectiveKeypointMemoryMultiplier`.** If R7 lowers the peak, report
  the new figures; do not lower the constant. It is the admission estimate for the memory ledger, a too-low value
  has taken a user's session down before (the 0.11.4 logout), and lowering it is the owner's decision.
* The memory ledger, the 0.25 realized-ratio floor, `MemoryMonitor`.
* `.managed` vs `.shared` texture choices, unless you are doing the section 3 follow-up on purpose.

## 7. Building and running on the Mac

* Packages: `StarCpp` (`swift test` there runs the C++/bridge tests, including all the GPU ones), `StarCore`,
  `cli` (`swift build -c release` there builds the cli). A fresh worktree needs the OpenCV symlinks the build
  expects, from the main checkout: `ln -s <main>/opencv/include opencv/include`, same for `lib` and
  `opencv2.framework` (`StarCpp/Package.swift` links `../opencv/lib/macos/libopencv2.a`, which is a universal
  x86_64+arm64 archive). `StarCore` tests also want `external_binaries/bin` (ffmpeg) in the worktree.
  The project memory `gui-worktree-build` has the GUI recipe if you need it.
* `swift test -c release` is required for the footprint harness; the debug build is ~10× slower on the C++.
* This tree compiles C++ for both architectures; on arm64 the x86-only fast paths are compiled out
  (`STAR_X86_AVX2_KERNELS`): `ExactWarp.hpp` is off because OpenCV's arm64 build uses fused multiply-adds, so
  `cv::warpPerspective` runs as before; the median merge runs the original Welford kernel; the cloud stage's box
  blur runs its scalar form. `Config` defaults `useGPUForMerge` (and the two keypoint flags) on whenever a Metal
  device exists. That is expected, not a bug.
* Project rules (`CLAUDE.md`): every user-visible string lives in the i18n catalogue with a real translation in
  every language (R7 should add none); the macOS gui and the Kotlin desktop client change together for
  user-facing changes (R7 changes none). Do not commit or push unless asked. Remove probe data and scratch logs
  (`~/Documents/star-log-*.txt`) when done.

## 8. While you are on the Mac: check what the Intel machine could not

These came from this branch and were verified only on x86-64. Run them and report:

* `swift test` in `StarCpp` and `StarCore` in full. **Known failure on Intel at `develop`:**
  `OpenCVQoSTests.testLowQoSUsesFewerWorkersThanNormalQoS` (it probes the prebuilt OpenCV's worker width; it
  fails the same way on `efb4d68c`, before any of this work). On the Intel box `StarCore` also fails
  `VideoConvertTests.testTheShippedToolsCanBeRunOnThisMachine` (the shipped ffmpeg build check); I did not run it
  on clean develop. See whether either differs on arm64.
* `PairMatchEquivalenceTests` (the pair-shared descriptor matcher runs on arm64 as well; its equivalence to
  `BFMatcher` is proven by the suite there, not by anything I could run), `TiffCompressionTests`,
  `StallWatchTests`, `FeatheredCompositeTests`.
* On arm64 the exact warp is off (see section 7), so the band-limited earth merge (`bandLimitedEarthMerge`)
  takes whatever path `cv::warpPerspective` and the GPU merge give it; I wrote and verified the band only on x86-64.
  Worth one real run, moving and static, to confirm the final frames are byte-identical with
  `bandLimitedEarthMerge` on and off.

## 9. What to send back

A short note, with numbers, in this order: (1) does the GPU pyramid path run on this machine (step 0, section 3: the
`.managed` texture storage), what you changed to make it run if not, and which tests pass;
(2) the baseline and after-R7 phase-A profile share of the readback copy and of `makeBuffer`; (3) the footprint
harness table, before and after, sky and earth, single and two concurrent ops; (4) the whole-run A/B (alternating,
warm cache) and the identity evidence from section 5; (5) your recommendation on the pool policy and on whether
the section 3 follow-up is worth doing; (6) anything in this document that turned out to be wrong. If R7 is not
worth it on Apple Silicon (the copy is cheap there, or the footprint rises), say so and why; that is a valid result.
