# wgpu-native — the Vulkan / Direct3D 12 GPU backend

`StarCpp/Sources/StarCpp/WGPUBackend.cpp` runs the warp and the fused aligned merge on any GPU
[wgpu-native](https://github.com/gfx-rs/wgpu-native) can reach: Vulkan on Linux, Direct3D 12 on Windows,
Metal on macOS. The kernels are WGSL (`WGPUShaders.h`), a port of the Metal ones in
`StarCppBridge/GPUOps.swift`. On macOS the Metal backend stays the one in use; this one exists for
Windows and Linux, and to hold the port to Metal byte for byte on a Mac.

It is **opt-in**: nothing loads a GPU driver unless `STAR_WGPU=1` is set, and it does only the warp and the
merge, not the SIFT/AKAZE pyramids. `Config`'s three `useGPUFor*` flags still default to on only where the
full Metal backend exists (`GPUCapability.hasFullAcceleration()`).

## Using it

```bash
wgpu/fetch.sh                  # this machine's platform, pinned release, sha256 checked, into wgpu/<platform>/
touch StarCpp/Package.swift    # the manifest only notices the new directory when it is re-evaluated
STAR_WGPU=1 swift test --package-path StarCpp --filter WGPUOpsTests
```

`wgpu/<platform>/` is git-ignored. Without it `WGPUBackend.cpp` builds as stubs and nothing else changes.

| variable | effect |
|---|---|
| `STAR_WGPU=1` | turn the backend on (registration, probing, use) |
| `STAR_WGPU_ALLOW_CPU_ADAPTER=1` | accept a software adapter (lavapipe, WARP). Refused otherwise: it would be slower than the CPU path. CI sets it. |
| `STAR_WGPU_BACKEND=vulkan\|dx12\|metal` | restrict the instance to one API |
| `STAR_WGPU_FALLBACK=1` | ask wgpu for its fallback adapter |

## CI

`.github/workflows/wgpu.yml` runs `WGPUOpsTests` on Linux (lavapipe), Windows (WARP) and macOS (Metal).
Hosted runners have no GPU, so Linux and Windows prove correctness through each platform's driver stack,
not speed. See `plans/GPU_SUPPORT_EXPANSION.md`.

## Upgrading

Change `VERSION` and the four sha256 values in `fetch.sh` (GitHub shows each asset's digest), then rerun
the tests. v29 uses the callback-info style of `webgpu.h`; a major bump may change struct names.
