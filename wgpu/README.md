# wgpu-native — the Vulkan / Direct3D 12 GPU backend

`StarCpp/Sources/StarCpp/WGPUBackend.cpp` runs on any GPU [wgpu-native](https://github.com/gfx-rs/wgpu-native)
can reach: Vulkan on Linux, Direct3D 12 on Windows, Metal on macOS. It provides everything `GPUOps_C.h`'s seam
asks for:

| Handler | Kernels | Notes |
|---|---|---|
| warp | `WGPUShaders.h` | OpenCV's 1/32-pixel quantisation; tile-origin projection (see the file comment) |
| aligned merge | `WGPUShaders.h` | the fused warp + coverage + sigma-clipped median, one dispatch |
| median merge | `WGPUShaders.h` | the standalone merge; matched the CPU sample for sample in the tests |
| SIFT pyramid | `WGPUImageShaders.h` | float buffers, separable blur, 2x up/down |
| AKAZE pyramid | `WGPUImageShaders.h` | blur, Scharr, Perona-Malik, FED steps, area resize |

The kernels are WGSL, a port of the Metal ones in `StarCppBridge/GPUOps.swift`. On macOS the Metal backend stays
the one in use; this one exists for Windows and Linux, and to hold the port against Metal on a Mac.

It is **opt-in**: nothing loads a GPU driver unless `STAR_WGPU=1` is set. `Config`'s three `useGPUFor*` flags
still default to on only where the full Metal backend exists (`GPUCapability.hasFullAcceleration()`), so on
Linux and Windows a user turns them on deliberately.

## Performance (what was measured, on what)

AMD Radeon Pro Vega 64 through wgpu's Metal backend, release build, 12 MP frame. Software adapters (CI) say
nothing about speed, and **nothing here has been timed on a real Vulkan or Direct3D 12 driver**.

| | CPU | Metal backend | wgpu |
|---|---|---|---|
| aligned merge, 16-bit RGB, 8 neighbours | 642 ms | 128 ms | ~200 ms |
| SIFT, whole detector, 8-bit | 2379 ms | 1599 ms | ~1030 ms |
| AKAZE, whole detector, 8-bit | 2014 ms | 2015 ms | ~2040 ms |

AKAZE is not helped by either GPU backend here: its CPU tail dominates, so its flag stays off by default.

Uploads decided most of the merge: `wgpuQueueWriteBuffer` took 815 ms for 648 MB against 152 ms through a
persistent mapped staging buffer (80 ms with two buffers ping-ponging 8 MB chunks), and the buffers are pooled
by exact size. Tunables: `STAR_WGPU_UPLOAD=write|staging`, `STAR_WGPU_STAGING_MB` (8), `STAR_WGPU_POOL_MB`
(4096), `STAR_WGPU_PYRAMID_MB` (3072: a pyramid bigger than this is left to the CPU). `GPUOps.trimTexturePool()`
(the memory-pressure hook) trims the pool when the backend has started.

## Using it

```bash
wgpu/fetch.sh                  # this machine's platform, pinned release, sha256 checked, into wgpu/<platform>/
touch StarCpp/Package.swift    # the manifest only notices the new directory when it is re-evaluated
STAR_ONLY_WGPU_TESTS=1 STAR_WGPU=1 swift test --package-path StarCpp --filter StarCppWGPUTests
STAR_ONLY_WGPU_TESTS=1 STAR_WGPU=1 STAR_WGPU_BENCH=1 swift test -c release -Xswiftc -enable-testing \
    --package-path StarCpp --filter WGPUBenchmarkTests     # timings, BENCH lines; STAR_WGPU_BENCH_MP sets the size
```

`wgpu/<platform>/` is git-ignored. Without it `WGPUBackend.cpp` builds as stubs and nothing else changes.

| variable | effect |
|---|---|
| `STAR_WGPU=1` | turn the backend on (registration, probing, use) |
| `STAR_WGPU_ALLOW_CPU_ADAPTER=1` | accept a software adapter (lavapipe, WARP). Refused otherwise: it would be slower than the CPU path. CI sets it. |
| `STAR_WGPU_BACKEND=vulkan\|dx12\|metal` | restrict the instance to one API |
| `STAR_WGPU_FALLBACK=1` | ask wgpu for its fallback adapter |

## CI

`.github/workflows/wgpu.yml` runs the whole `StarCppWGPUTests` target on Linux (lavapipe), Windows (WARP) and
macOS (Metal).
Hosted runners have no GPU, so Linux and Windows prove correctness through each platform's driver stack,
not speed. See `plans/GPU_SUPPORT_EXPANSION.md`.

## Upgrading

Change `VERSION` and the four sha256 values in `fetch.sh` (GitHub shows each asset's digest), then rerun
the tests. v29 uses the callback-info style of `webgpu.h`; a major bump may change struct names.
