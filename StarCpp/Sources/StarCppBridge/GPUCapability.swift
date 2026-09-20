// GPUCapability.swift — hardware detection for GPU-accelerated image ops.
//
// Deliberately independent of whether a GPU backend is actually registered with
// the C++ layer (see GPUOps.swift): clients that only want to show the user
// "does your machine support this" — the gui's settings view, the daemon's
// status to the Kotlin client, the cli's startup log — call this directly, with
// no dependency on `ImageAligner` or any merge machinery having run yet.
#if canImport(Metal)
import Metal
#endif

public enum GPUCapability: Sendable {

    /// Whether this process can run the Metal-accelerated warp/median-merge kernels.
    ///
    /// `Config.useGPU` is a request; this is the other half of the decision every
    /// call site actually makes. A user can leave `useGPU` on by default and still
    /// run entirely on the CPU, silently, on a machine this returns false for — the
    /// GUI's job is to say so (see `statusDescription`), not to make this true.
    public static func isAvailable() -> Bool {
        #if canImport(Metal) && os(macOS)
        return MTLCreateSystemDefaultDevice() != nil
        #else
        // No Metal backend on this platform yet. CUDA/Vulkan are future tiers
        // (see GPU_ACCELERATION_PROPOSAL.md ยง6) — until one lands, GPU ops are
        // macOS-only and this is the single place that says so.
        return false
        #endif
    }

    /// The Metal device name, e.g. "Radeon Pro Vega 64" or "Apple M2 Max", or nil
    /// when `isAvailable()` is false. For display only — nothing here should be
    /// parsed to make a decision; use `isAvailable()` for that.
    ///
    /// Deliberately just the fact, not a sentence: this package (StarCppBridge) sits
    /// below StarCore's localization system, so building the user-facing "GPU
    /// acceleration is supported on this Mac (...)" string is StarCore's job — see
    /// `ui.gpu_status_supported` / `ui.gpu_status_unsupported` in the localization
    /// catalogue, and `Config.gpuAccelerationStatusText()`.
    public static func deviceName() -> String? {
        #if canImport(Metal) && os(macOS)
        return MTLCreateSystemDefaultDevice()?.name
        #else
        return nil
        #endif
    }
}
