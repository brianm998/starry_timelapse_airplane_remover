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
import StarCpp

public enum GPUCapability: Sendable {

    /// Whether this process can run the Metal-accelerated warp/median-merge kernels.
    ///
    /// `Config.useGPUForMerge` is a request; this is the other half of the decision
    /// every call site actually makes. A user can leave `useGPUForMerge` on by
    /// default and still run entirely on the CPU, silently, on a machine this
    /// returns false for — the GUI's job is to say so (see `statusDescription`),
    /// not to make this true.
    public static func isAvailable() -> Bool {
        #if canImport(Metal) && os(macOS)
        return MTLCreateSystemDefaultDevice() != nil
        #else
        // The wgpu-native backend (Vulkan / Direct3D 12): opt-in via STAR_WGPU, and false unless the
        // build has the library (wgpu/fetch.sh) and the machine has a real adapter. It starts the
        // device the first time it is asked, so only callers that need the answer pay for it.
        return wgpu_ops_available()
        #endif
    }

    /// Whether the GPU backend here accelerates everything `useGPUForMerge`, `useGPUForSIFT` and
    /// `useGPUForAKAZE` stand for, and has been measured well enough to be on by default. That is the
    /// Metal backend and only that: the wgpu-native one does the warp and the aligned merge, not the
    /// keypoint pyramids, and is opt-in until it has been timed on real hardware. `Config` defaults
    /// the three flags, and sizes its keypoint memory estimates, from this rather than from
    /// `isAvailable()`, so a merge-only backend cannot make it believe the keypoints are on the GPU too.
    public static func hasFullAcceleration() -> Bool {
        #if canImport(Metal) && os(macOS)
        return MTLCreateSystemDefaultDevice() != nil
        #else
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
        guard let description = wgpu_ops_device_description() else { return nil }
        return String(cString: description)
        #endif
    }
}
