# Fixing GPU-accelerated warp/merge — batch per-frame, don't round-trip per-call

A handoff document, in the spirit of `GPU_IMPLEMENTATION_GUIDE.md` (read that
first if you have not — this assumes its §0-§4). This one is narrower: it is
about a specific, now-measured regression in Tier 1's warp/merge kernels
(`Config.useGPU`), found while investigating a real production incident.
Tier 2 (`Config.useGPUForSIFT` / `useGPUForAKAZE`, the SIFT/AKAZE pyramid
builders) is not implicated and should not be touched by this work — it is
mentioned below only as the architecture to copy.

## What happened, in order

1. A real run: GPU-accelerated SIFT keypoint detection on a 1600-frame, 42MP
   sequence completed in about an hour — faster than CPU keypoint detection,
   no problems.
2. The same run reached the merge stage (`Config.useGPU`, the Tier 1
   warp/median-merge kernels). The machine "crawled to a stop" while the user
   was typing, stopped updating its UI entirely, and panicked a few minutes
   later.
3. The panic (full text at the bottom of this document) is a **userspace
   watchdog timeout: no successful checkins from WindowServer (2 induced
   crashes) in 120 seconds** — the kernel's last resort when WindowServer,
   which itself depends on the GPU to composite the display, stops responding
   for two full minutes and killing it twice does not bring it back.
4. **This exact panic signature already happened once on this machine for an
   unrelated reason.** Project memory `gpu-watchdog-panic-simulator.md`
   documents a 2026-08-31 incident: the iOS Simulator's Metal renderer
   (`SimMetalHost`) wedged this same Radeon Pro Vega 64 — 20 GPU resets in 28
   minutes, WindowServer starved of GPU time, same watchdog panic. That
   incident's own writeup says plainly: *"if resets recur with no simulator
   running, re-verdict as failing Vega 64 hardware."* Nothing in this
   session confirms GPU resets occurred this time (the user did not have the
   `/Library/Logs/DiagnosticReports/*gpuRestart*` file handy) — **read that
   memory file, then check for a `*gpuRestart*` report from this incident's
   timestamp before assuming Star's code is the cause with certainty.** If
   one exists, `grep -m2 -E 'Restart Channel|FirstPendingCB' <file>` and look
   at what process it names.

Independent of what that check finds, this session separately measured a
real, reproducible performance regression in the same code path, which is
reason enough on its own to fix it — and a very plausible *mechanism* for the
freeze even if it turns out not to be the literal cause of the panic.

## What was measured

All of this is in `StarCpp/Tests/StarCppBridgeTests/GPUOpsConcurrencyStressTests.swift`
(added this session — run its two newer tests with `swift test -c release
--package-path StarCpp`; they are real, not synthetic-toy scale — 42MP,
matching the reported sequence).

**A single warp, alone, no concurrency at all** (`testSingleWarpRoundTripCostAtRealScale`):

| | mean per call |
|---|---|
| GPU | ~298ms |
| CPU | ~118ms |

GPU is **2.5x slower** than CPU for one 42MP warp, with zero contention —
this alone rules out concurrency as the (sole) explanation.

**The realistic per-frame shape at 18-way concurrency**
(`testRealisticAlignedMergeThroughputAtConcurrency`): 18 concurrent frames,
each an 8-neighbour aligned merge (star's own default neighbour count):

| | total wall time |
|---|---|
| GPU | 58.5s |
| CPU | 24.9s |

GPU is **2.35x slower** end to end.

### Root cause

`ia_align_and_median_merge` (`StarCpp/Sources/StarCpp/ImageAligner.cpp`) calls,
per neighbour: `warpInto` (the real warped image) **and** `warpCoverage`
(literally the same function again — see the comment "Literally the same
call, now" — called on an all-255 probe image, purely to learn which
destination pixels the warp reached). For 8 neighbours that is 16 warp calls,
plus one final merge call: **17 separate GPU round-trips per frame.**

Each round-trip (`MetalGPUBackend.warp` / `medianMergeImpl` in
`StarCpp/Sources/StarCppBridge/GPUOps.swift`) pays, every single time:

- a fresh `.storageModeShared` `MTLBuffer` allocation (`device.makeBuffer(bytes:...)`)
- a new `MTLCommandBuffer` + compute encoder
- `commit()` then a **synchronous, blocking** `waitUntilCompleted()`
- a `memcpy` of the result back into CPU memory

`GPU_IMPLEMENTATION_GUIDE.md`'s own numbers table says "warp: 0.99ms" — that
almost certainly measured GPU-side kernel execution time alone (e.g. via GPU
timestamps), not this full round-trip. The measurements above are ordinary
`Date()` wall-clock time around the actual production entry point, and they
say the round-trip's fixed overhead alone — never mind the kernel — is larger
than the CPU cost of the same 42MP warp on this machine's 18-core Xeon (which
already fans out across cores via OpenCV's own parallelism for a single call).

This is exactly the architectural difference from the SIFT/AKAZE pyramid
builders (`buildSiftPyramid` / `buildAkazePyramid`, same file), which
*measured fast* and ran for an hour across 1600 frames without incident: each
of those builds a whole frame's worth of chained dispatches (Gaussian
blurs, Scharr derivatives, FED diffusion steps, ...) onto **one** command
buffer and synchronizes **once**. The aligned merge does the opposite: one
round-trip per dispatch, 17 times per frame. Whatever the fixed per-call
overhead actually costs, the pyramid builders pay it once; the aligned merge
pays it 17x.

It is a reasonable, though unconfirmed, hypothesis that repeating that
allocate/submit/wait/readback cycle roughly 17 × 1600 ≈ 27,200 times over a
long run is *also* what wedged the GPU/driver into the freeze that led to the
panic — "the machine crawled to a stop" (a gradual degradation, not an
instant crash) is consistent with some kind of cumulative driver-side
resource pressure from many small allocations, not a single bad dispatch.
This is a hypothesis, not a confirmed root cause — see the `gpuRestart` check
above.

## Immediate mitigation (already applied by the investigating session)

`Config.useGPU` defaults to `true` and, as measured, is currently a **net
loss** for the aligned-merge path on this hardware — not a wash, a
regression. Until this is fixed, turning `Config.useGPU` off (or defaulting
it off on this class of hardware) costs nothing: the CPU path is faster *and*
is what every run before this GPU work used. `Config.useGPUForSIFT` /
`useGPUForAKAZE` are unaffected and worth keeping on — they are not part of
this problem.

## The fix: batch a frame's dispatches onto one command buffer

Model this on `buildSiftPyramid` / `buildAkazePyramid`, not on `warp` /
`medianMergeImpl`. Concretely:

1. **Design one new entry point** (mirroring `GPUSiftPyramidFunc` /
   `GPUAkazePyramidFunc`'s shape in `GPUOps_C.h`) that takes a frame's base
   image, all of its neighbours plus their homographies, and the merge
   parameters (`outlierThreshold`, `includeAll`), and returns the one merged
   result — replacing today's `neighbourCount * 2` warp calls plus one
   separate merge call with a single GPU operation per frame.

2. **Implement it as one `MTLCommandBuffer`**: allocate buffers for the base
   and every neighbour, encode one warp dispatch per neighbour into the
   base's coordinate frame, encode the final median-merge dispatch to read
   directly from those already-GPU-resident warped buffers (no CPU round
   trip in between), then exactly one `commit()` + `waitUntilCompleted()` +
   one final readback. Reuse `.storageModeShared` **buffers** (not textures —
   see the existing comment on `buildSiftPyramid` about `.storageModeShared`
   textures reading back as zero on this Vega without an explicit blit-sync;
   buffers do not have that problem here).

3. **Eliminate the `warpCoverage` duplication while you are in there** — this
   is a real algorithmic simplification, independent of batching. The warp
   kernel (`warp_generic` in `GPUOps.swift`'s Metal source) already computes,
   per destination pixel, exactly which of the four sample corners existed in
   the source (`v00`/`v10`/`v01`/`v11`). Write a second, tiny output buffer
   from that same dispatch recording whether the pixel was reached at all,
   instead of running the entire kernel a second time on a synthetic all-255
   probe image. This alone cuts the per-neighbour round-trip count in half
   even before full batching.

4. **Leave the CPU path exactly as it is.** `warpInto`'s CPU branch and
   `medianMergeTyped` do not change; this replaces only the shape of the GPU
   branch. On any failure, fall back to the existing CPU path for the whole
   frame — there is no partial fallback once a batched dispatch chain is
   committed to, same rule `SIFTDetector.cpp` / `AKAZEDetector.cpp` already
   follow for their own GPU paths.

5. **Re-tune `gpuSlots`** (`MetalGPUBackend` in `GPUOps.swift`) once this
   lands. It currently bounds all of `warp`/`medianMerge`/both pyramid
   builders to 2 concurrent Metal round-trips, chosen conservatively without
   measurement specifically because the *old* per-neighbour-call shape made
   17 round-trips/frame plausible across many concurrent frames. Once a
   frame's aligned merge is one round-trip, its profile matches the
   already-validated `medianMergeImage`-only case
   (`GPUOpsConcurrencyStressTests.testManyConcurrentMediumFrameMergesCompleteWithoutHangingOrCrashing`,
   18 concurrent single-round-trip merges in ~2s) — re-measure before raising
   or lowering the semaphore's value for this new shape.

6. **Decide what to do with the streaming/spill path deliberately, don't
   drift into it.** `ia_align_and_median_merge` has a second code path
   (`MergeSpiller`, engaged when `residentBytes > streamingThresholdBytes`)
   that warps one neighbour at a time and spills it to scratch before the
   next, specifically so only one warp is ever resident. A fully-batched GPU
   command buffer holding every neighbour at once works against that memory
   discipline. The simplest correct answer is probably: the batched GPU path
   only replaces the *resident* branch; the streaming branch keeps calling
   the CPU path (or the existing single-call GPU path) exactly as it does
   today. Say so explicitly in the PR rather than silently changing streaming
   behaviour.

## Validating the fix

- **Correctness**: `StarCpp/Tests/StarCppBridgeTests/GPUOpsTests.swift`'s
  existing warp/merge bit-identity and tolerance tests must still pass
  unchanged — the underlying math is not moving, only how many round trips
  carry it.
- **Speed**: re-run `GPUOpsConcurrencyStressTests.testSingleWarpRoundTripCostAtRealScale`
  and `.testRealisticAlignedMergeThroughputAtConcurrency` with
  `swift test -c release --package-path StarCpp` (they skip themselves under
  a debug build — see their doc comments for why). Success is the GPU/CPU
  ratio dropping *below* 1.0 (GPU actually faster), not merely closer to it.
- **Stability — the part no unit test substitutes for**: the reported
  failure was a full system freeze and kernel panic, not a wrong answer or a
  slow-but-completing run. Run a real multi-hundred-frame (ideally
  multi-hundred to 1000+) 42MP sequence end to end with `useGPU: true` and
  confirm the machine stays responsive throughout — no display freezing, no
  WindowServer stall. Watch for the early warning sign the prior incident's
  writeup names — "screen blinking black / apps freezing in bursts" — and
  abort well before a 120s watchdog window if it appears. If a hang recurs,
  check `/Library/Logs/DiagnosticReports/*gpuRestart*` for `FirstPendingCB`
  naming the Star process this time, using the exact method
  `gpu-watchdog-panic-simulator.md` already documents.

## Files to read first

- `GPU_IMPLEMENTATION_GUIDE.md`, `GPU_ACCELERATION_PROPOSAL.md` — original
  design and the "0.99ms" figure this document's measurements supersede for
  the *real, end-to-end* per-call cost (the isolated kernel-only number may
  still be accurate for what it actually measured).
- `StarCpp/Sources/StarCppBridge/GPUOps.swift` — `MetalGPUBackend`,
  especially `buildSiftPyramid` / `buildAkazePyramid` (the pattern to copy)
  versus `warp` / `medianMergeImpl` (the pattern being replaced, for the
  aligned-merge call site specifically — `medianMerge`'s own standalone entry
  point is used correctly elsewhere, e.g. the static-earth non-aligned merge
  path in `PixelatedImage.swift`, and should not change).
- `StarCpp/Sources/StarCpp/ImageAligner.cpp` — `ia_align_and_median_merge`,
  `warpInto`, `warpCoverage`, the `warpNeighbour` lambda, `forEachMergeSource`,
  `MergeSpiller`.
- `StarCpp/Tests/StarCppBridgeTests/GPUOpsConcurrencyStressTests.swift` —
  this session's diagnostic tests; extend rather than replace them.
- Project memory `gpu-watchdog-panic-simulator.md` — read before concluding
  root cause of the panic below with certainty.

## Non-goals for this pass

- Don't touch `Config.useGPUForSIFT` / `useGPUForAKAZE` or their pyramid
  builders. Not implicated, already fast, already validated separately.
- Don't try to also rebuild the streaming/spill path's GPU usage in the same
  pass unless it falls out easily — see point 6 above.

## Appendix: the panic report in full

```
panic(cpu 4 caller 0xffffff8003ab489b): userspace watchdog timeout: no successful checkins from WindowServer (2 induced crashes) in 120 seconds
service: logd, total successful checkins in 38540 seconds: 3853, last successful checkin: 0 seconds ago
service: WindowServer (2 induced crashes), total successful checkins in 38490 seconds: 3826, last successful checkin: 120 seconds ago
service: remoted, total successful checkins in 38540 seconds: 3851, last successful checkin: 0 seconds ago
service: opendirectoryd, total successful checkins in 38540 seconds: 3853, last successful checkin: 0 seconds ago
service: configd, total successful checkins in 38540 seconds: 3853, last successful checkin: 0 seconds ago

Panicked task 0xffffff95525a1980: 4 threads: pid 127: watchdogd
Process name corresponding to current thread (0xffffff9553de90c8): watchdogd

Mac OS version: 24H23
Kernel version: Darwin Kernel Version 24.6.0: Sun Aug 23 20:30:56 PDT 2026; root:xnu-11417.140.69.712.69~1/RELEASE_X86_64
System model name: iMacPro1,1 (Mac-7BA5B2D9E42DDD94)
System uptime in nanoseconds: 38540730069119 (~10.7 hours)
Compressor Info: 2% of compressed pages limit (OK) and 9% of segments limit (OK) with 7 swapfiles and OK swap space
```

Same top-level signature as the 2026-08-31 incident in
`gpu-watchdog-panic-simulator.md` (WindowServer watchdog timeout after 120s,
induced crashes, kernel panic by design when they don't recover it) — the
memory (compressor 2%/9%, both OK) rules out an OOM cause here too, exactly
as it did then.
