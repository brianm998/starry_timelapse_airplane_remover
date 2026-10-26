// WGPUBackend.cpp — the wgpu-native (WebGPU) implementation of the GPU warp and aligned merge.
// See WGPUOps_C.h for what this is and where it sits, and WGPUShaders.h for the kernels.
//
// First version, on purpose simple: one device, every operation serialised by one mutex, and every
// buffer created and destroyed per call. The Metal backend grew pools, a slot gate and in-place
// unified-memory binding because measurement showed per-call allocation dominating its GPU time
// (GPU_SLOT_TIME memory); this one does not have them yet and should earn them the same way.
#include "WGPUOps_C.h"
#include "GPUOps_C.h"
#include "MatWrapper.h"
#include "starcpp_bridge_logging.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#ifndef STAR_HAVE_WGPU

// Built without wgpu-native: the symbols exist so callers (Swift tests, GPUOps.registerIfAvailable)
// need no conditional compilation of their own.
extern "C" {
bool wgpu_ops_compiled_in(void) { return false; }
bool wgpu_ops_available(void) { return false; }
const char *wgpu_ops_device_description(void) { return nullptr; }
bool wgpu_ops_aligned_merge_supported(void) { return false; }
bool wgpu_ops_warp(MatWrapperRef, const double *, MatWrapperRef) { return false; }
bool wgpu_ops_aligned_merge(MatWrapperRef, MatWrapperRef *, int, const double *, double, bool,
                            MatWrapperRef) { return false; }
bool wgpu_ops_opted_in(void) { return false; }
bool wgpu_ops_register(void) { return false; }
}

#else  // STAR_HAVE_WGPU

#include <webgpu/webgpu.h>
#include <webgpu/wgpu.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <mutex>
#include <thread>
#include <vector>

#include "WGPUShaders.h"

namespace {

void logMsg(const char *level, const std::string &message) {
    if (KHTLogHandler handler = kht_bridge_get_log_handler()) {
        handler(message.c_str(), level, "WGPUBackend.cpp", "", 0);
    } else {
        std::fprintf(stderr, "[wgpu %s] %s\n", level, message.c_str());
    }
}

WGPUStringView sv(const char *s) { return WGPUStringView{s, WGPU_STRLEN}; }

std::string str(WGPUStringView v) {
    if (!v.data) return std::string();
    return v.length == WGPU_STRLEN ? std::string(v.data) : std::string(v.data, v.length);
}

bool envFlag(const char *name) {
    const char *v = std::getenv(name);
    return v && *v && std::strcmp(v, "0") != 0;
}

// The uniform buffer, laid out as the WGSL `Params` struct (WGPUShaders.h). 704 bytes.
struct alignas(16) Params {
    uint32_t width, height, channels, count;
    uint32_t includeAll;
    float outlier;
    uint32_t outWordsPerRow;
    uint32_t tilesX;
    uint32_t tilesPerNeighbour;
    uint32_t pad[3];
    uint32_t steps[20];   // row step in bytes of source i
    float hinv[144];      // 16 neighbours x nine: the inverse homography, row-major
};
static_assert(sizeof(Params) == 704, "Params must match the WGSL struct");

constexpr uint32_t kTile = 16;   // TS in the shader

constexpr int kMaxSources = 17;        // base + 16 neighbours: the WGSL selects from float[17]
constexpr int kAlignedStorageBuffers = 19;  // 17 sources + the output + the tile table, all declared by the module

struct Plane {
    const uint8_t *ptr = nullptr;
    size_t step = 0;
    size_t length = 0;   // first pixel to the end of the last row's pixels, not rows * step
};

struct Format {
    int rows = 0, cols = 0, channels = 0, bpc = 0;
    size_t rowBytes = 0;

    static bool of(MatWrapperRef ref, Format &out) {
        if (!ref) return false;
        out.rows = (int)mat_wrapper_rows(ref);
        out.cols = (int)mat_wrapper_cols(ref);
        out.channels = (int)mat_wrapper_channels(ref);
        int64_t bits = mat_wrapper_bits_per_component(ref);
        if (out.rows <= 0 || out.cols <= 0 || out.channels < 1 || out.channels > 4) return false;
        if (bits != 8 && bits != 16) return false;
        out.bpc = (int)(bits / 8);
        out.rowBytes = (size_t)out.cols * out.channels * out.bpc;
        return true;
    }

    bool plane(MatWrapperRef ref, Plane &out) const {
        if (!ref) return false;
        if ((int)mat_wrapper_rows(ref) != rows || (int)mat_wrapper_cols(ref) != cols ||
            (int)mat_wrapper_channels(ref) != channels ||
            mat_wrapper_bits_per_component(ref) != bpc * 8)
            return false;
        const void *p = mat_wrapper_data_ptr(ref);
        size_t step = mat_wrapper_step(ref);
        if (!p || step < rowBytes || step % (size_t)bpc != 0) return false;
        out.ptr = (const uint8_t *)p;
        out.step = step;
        out.length = (size_t)(rows - 1) * step + rowBytes;
        return true;
    }
};

// Closed-form 3x3 inverse, the same one GPUOps.swift's invert3x3 does (so both backends sample the
// same inverse). Row-major in and out; false when singular.
bool invert3x3(const double *m, double *out) {
    const double a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8];
    const double A = e * i - f * h;
    const double B = -(d * i - f * g);
    const double C = d * h - e * g;
    const double det = a * A + b * B + c * C;
    if (!(std::fabs(det) > 1e-15)) return false;
    const double invDet = 1.0 / det;
    const double D = -(b * i - c * h);
    const double E = a * i - c * g;
    const double F = -(a * h - b * g);
    const double G = b * f - c * e;
    const double H = -(a * f - c * d);
    const double I = a * e - b * d;
    const double r[9] = {A * invDet, D * invDet, G * invDet, B * invDet, E * invDet,
                         H * invDet, C * invDet, F * invDet, I * invDet};
    std::memcpy(out, r, sizeof(r));
    return true;
}

// Appends neighbour `inv`'s tile table (five floats per kTile x kTile tile) to `out`, in double, so the
// shader's float arithmetic only ever covers a small offset from each tile's origin (WGPUShaders.h).
// A tile whose origin projects to nothing usable gets W0 = 0, which the shader reads as uncovered.
void appendTiles(const double *inv, int rows, int cols, std::vector<float> &out) {
    const int tx = (cols + (int)kTile - 1) / (int)kTile, ty = (rows + (int)kTile - 1) / (int)kTile;
    out.reserve(out.size() + (size_t)tx * ty * 5);
    for (int j = 0; j < ty; ++j) {
        for (int i = 0; i < tx; ++i) {
            const double x0 = (double)i * kTile, y0 = (double)j * kTile;
            const double w = inv[6] * x0 + inv[7] * y0 + inv[8];
            float rec[5] = {0, 0, 0, 0, 0};
            if (std::fabs(w) > 1e-9) {
                const double qx = (inv[0] * x0 + inv[1] * y0 + inv[2]) / w * 32.0;
                const double qy = (inv[3] * x0 + inv[4] * y0 + inv[5]) / w * 32.0;
                // far outside any image (they are under 2^19 steps wide): nothing to sample, and the
                // integer part would stop being exact in a float
                if (std::fabs(qx) < 8388608.0 && std::fabs(qy) < 8388608.0 && (float)w != 0.0f) {
                    const double ix = std::floor(qx), iy = std::floor(qy);
                    rec[0] = (float)ix; rec[1] = (float)(qx - ix);
                    rec[2] = (float)iy; rec[3] = (float)(qy - iy);
                    rec[4] = (float)w;
                }
            }
            out.insert(out.end(), rec, rec + 5);
        }
    }
}

struct Backend {
    WGPUInstance instance = nullptr;
    WGPUAdapter adapter = nullptr;
    WGPUDevice device = nullptr;
    WGPUQueue queue = nullptr;
    WGPULimits limits = WGPU_LIMITS_INIT;
    WGPUShaderModule module = nullptr;
    WGPUComputePipeline aligned[2] = {nullptr, nullptr};   // [bpc - 1]
    WGPUComputePipeline warp[2] = {nullptr, nullptr};
    std::string description;
    bool alignedOK = false;

    std::mutex mutex;                    // one operation on the device at a time
    std::atomic<bool> deviceError{false};
    std::string lastError;               // guarded by `mutex` while an operation runs

    // ---- start-up ---------------------------------------------------------------------------

    template <typename Done>
    bool waitFor(Done &&done, double seconds) {
        auto deadline = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
        while (!done()) {
            if (instance) wgpuInstanceProcessEvents(instance);
            if (done()) break;
            if (std::chrono::steady_clock::now() > deadline) return false;
            if (device) wgpuDevicePoll(device, false, nullptr);
            std::this_thread::sleep_for(std::chrono::microseconds(200));
        }
        return true;
    }

    struct AdapterRequest { std::atomic<bool> done{false}; WGPURequestAdapterStatus status{}; WGPUAdapter adapter{}; std::string message; };
    static void onAdapter(WGPURequestAdapterStatus status, WGPUAdapter adapter, WGPUStringView message,
                          void *u1, void *) {
        auto *r = (AdapterRequest *)u1;
        r->status = status; r->adapter = adapter; r->message = str(message);
        r->done = true;
    }

    struct DeviceRequest { std::atomic<bool> done{false}; WGPURequestDeviceStatus status{}; WGPUDevice device{}; std::string message; };
    static void onDevice(WGPURequestDeviceStatus status, WGPUDevice device, WGPUStringView message,
                         void *u1, void *) {
        auto *r = (DeviceRequest *)u1;
        r->status = status; r->device = device; r->message = str(message);
        r->done = true;
    }

    static void onUncapturedError(WGPUDevice const *, WGPUErrorType type, WGPUStringView message,
                                  void *u1, void *) {
        auto *self = (Backend *)u1;
        self->deviceError = true;
        std::string m = str(message);
        logMsg("error", "wgpu error (type " + std::to_string((int)type) + "): " + m);
    }

    bool init() {
        const bool allowCPU = envFlag("STAR_WGPU_ALLOW_CPU_ADAPTER");

        WGPUInstanceExtras extras = {};
        extras.chain.sType = (WGPUSType)WGPUSType_InstanceExtras;
        extras.backends = WGPUInstanceBackend_All;
        if (const char *b = std::getenv("STAR_WGPU_BACKEND")) {
            std::string name(b);
            if (name == "vulkan") extras.backends = WGPUInstanceBackend_Vulkan;
            else if (name == "dx12") extras.backends = WGPUInstanceBackend_DX12;
            else if (name == "metal") extras.backends = WGPUInstanceBackend_Metal;
        }
        WGPUInstanceDescriptor idesc = WGPU_INSTANCE_DESCRIPTOR_INIT;
        idesc.nextInChain = &extras.chain;
        instance = wgpuCreateInstance(&idesc);
        if (!instance) { logMsg("warn", "wgpu: could not create an instance"); return false; }

        WGPURequestAdapterOptions opts = WGPU_REQUEST_ADAPTER_OPTIONS_INIT;
        opts.powerPreference = WGPUPowerPreference_HighPerformance;
        opts.forceFallbackAdapter = envFlag("STAR_WGPU_FALLBACK") ? 1 : 0;
        AdapterRequest areq;
        WGPURequestAdapterCallbackInfo acb = WGPU_REQUEST_ADAPTER_CALLBACK_INFO_INIT;
        acb.mode = WGPUCallbackMode_AllowProcessEvents;
        acb.callback = &Backend::onAdapter;
        acb.userdata1 = &areq;
        wgpuInstanceRequestAdapter(instance, &opts, acb);
        if (!waitFor([&] { return areq.done.load(); }, 30.0) ||
            areq.status != WGPURequestAdapterStatus_Success || !areq.adapter) {
            logMsg("info", "wgpu: no adapter (" + areq.message + ")");
            return false;
        }
        adapter = areq.adapter;

        WGPUAdapterInfo info = WGPU_ADAPTER_INFO_INIT;
        wgpuAdapterGetInfo(adapter, &info);
        const char *backendName = info.backendType == WGPUBackendType_Vulkan ? "Vulkan"
                                : info.backendType == WGPUBackendType_D3D12  ? "D3D12"
                                : info.backendType == WGPUBackendType_Metal  ? "Metal" : "other";
        const char *typeName = info.adapterType == WGPUAdapterType_DiscreteGPU     ? "discrete"
                             : info.adapterType == WGPUAdapterType_IntegratedGPU   ? "integrated"
                             : info.adapterType == WGPUAdapterType_CPU             ? "software" : "unknown";
        std::string name = str(info.description);
        if (name.empty()) name = str(info.device);
        description = name + " (" + backendName + ", " + typeName + ")";
        const bool software = info.adapterType == WGPUAdapterType_CPU;
        wgpuAdapterInfoFreeMembers(info);
        if (software && !allowCPU) {
            logMsg("info", "wgpu: only a software adapter was found (" + description +
                           "); not using it. Set STAR_WGPU_ALLOW_CPU_ADAPTER=1 to allow it.");
            return false;
        }

        // Ask for everything the adapter offers: the defaults (128MB storage bindings, 8 storage
        // buffers a stage) are far below what one frame's merge needs.
        if (wgpuAdapterGetLimits(adapter, &limits) != WGPUStatus_Success) {
            logMsg("warn", "wgpu: could not read the adapter's limits");
            return false;
        }
        limits.nextInChain = nullptr;
        alignedOK = limits.maxStorageBuffersPerShaderStage >= (uint32_t)kAlignedStorageBuffers &&
                    limits.maxBindingsPerBindGroup >= (uint32_t)(kAlignedStorageBuffers + 1) &&
                    limits.maxUniformBufferBindingSize >= sizeof(Params);

        WGPUDeviceDescriptor ddesc = WGPU_DEVICE_DESCRIPTOR_INIT;
        ddesc.label = sv("star");
        ddesc.requiredLimits = &limits;
        ddesc.uncapturedErrorCallbackInfo.callback = &Backend::onUncapturedError;
        ddesc.uncapturedErrorCallbackInfo.userdata1 = this;
        DeviceRequest dreq;
        WGPURequestDeviceCallbackInfo dcb = WGPU_REQUEST_DEVICE_CALLBACK_INFO_INIT;
        dcb.mode = WGPUCallbackMode_AllowProcessEvents;
        dcb.callback = &Backend::onDevice;
        dcb.userdata1 = &dreq;
        wgpuAdapterRequestDevice(adapter, &ddesc, dcb);
        if (!waitFor([&] { return dreq.done.load(); }, 30.0) ||
            dreq.status != WGPURequestDeviceStatus_Success || !dreq.device) {
            logMsg("warn", "wgpu: could not create a device (" + dreq.message + ")");
            return false;
        }
        device = dreq.device;
        queue = wgpuDeviceGetQueue(device);

        WGPUShaderSourceWGSL wgsl = WGPU_SHADER_SOURCE_WGSL_INIT;
        wgsl.code = WGPUStringView{kWgslSource, std::strlen(kWgslSource)};
        WGPUShaderModuleDescriptor mdesc = WGPU_SHADER_MODULE_DESCRIPTOR_INIT;
        mdesc.label = sv("star kernels");
        mdesc.nextInChain = &wgsl.chain;
        module = wgpuDeviceCreateShaderModule(device, &mdesc);
        if (!module) { logMsg("warn", "wgpu: could not create the shader module"); return false; }

        for (int bpc = 1; bpc <= 2; ++bpc) {
            WGPUConstantEntry consts[2] = {WGPU_CONSTANT_ENTRY_INIT, WGPU_CONSTANT_ENTRY_INIT};
            consts[0].key = sv("BPC");  consts[0].value = bpc;
            consts[1].key = sv("MAXV"); consts[1].value = bpc == 1 ? 255.0 : 65535.0;
            auto make = [&](const char *entry) {
                WGPUComputePipelineDescriptor pd = WGPU_COMPUTE_PIPELINE_DESCRIPTOR_INIT;
                pd.label = sv(entry);
                pd.layout = nullptr;   // derived from what the entry point uses
                pd.compute.module = module;
                pd.compute.entryPoint = sv(entry);
                pd.compute.constantCount = 2;
                pd.compute.constants = consts;
                return wgpuDeviceCreateComputePipeline(device, &pd);
            };
            warp[bpc - 1] = make("warp_main");
            if (alignedOK) aligned[bpc - 1] = make("aligned_main");
        }
        wgpuDevicePoll(device, true, nullptr);
        if (deviceError.load() || !warp[0] || !warp[1] || (alignedOK && (!aligned[0] || !aligned[1]))) {
            logMsg("warn", "wgpu: the kernels did not compile on " + description);
            return false;
        }
        logMsg("info", "wgpu backend ready on " + description);
        return true;
    }

    // ---- one operation ----------------------------------------------------------------------

    WGPUBuffer makeBuffer(uint64_t size, WGPUBufferUsage usage, bool mapped) {
        if (size > limits.maxBufferSize) return nullptr;
        WGPUBufferDescriptor d = WGPU_BUFFER_DESCRIPTOR_INIT;
        d.usage = usage;
        d.size = size;
        d.mappedAtCreation = mapped ? 1 : 0;
        return wgpuDeviceCreateBuffer(device, &d);
    }

    // A storage buffer holding `plane`'s bytes as they are (row step and all), padded to whole words.
    WGPUBuffer sourceBuffer(const Plane &plane) {
        uint64_t size = (plane.length + 3) & ~(uint64_t)3;
        if (size == 0) size = 4;
        if (size > limits.maxStorageBufferBindingSize) return nullptr;
        WGPUBuffer buf = makeBuffer(size, WGPUBufferUsage_Storage, true);
        if (!buf) return nullptr;
        void *p = wgpuBufferGetMappedRange(buf, 0, (size_t)size);
        if (!p) { wgpuBufferRelease(buf); return nullptr; }
        std::memcpy(p, plane.ptr, plane.length);
        if (size > plane.length) std::memset((uint8_t *)p + plane.length, 0, (size_t)(size - plane.length));
        wgpuBufferUnmap(buf);
        return buf;
    }

    // A storage buffer holding `count` floats.
    WGPUBuffer floatBuffer(const std::vector<float> &values) {
        uint64_t size = (uint64_t)values.size() * sizeof(float);
        if (size == 0) size = 4;
        if (size > limits.maxStorageBufferBindingSize) return nullptr;
        WGPUBuffer buf = makeBuffer(size, WGPUBufferUsage_Storage, true);
        if (!buf) return nullptr;
        void *p = wgpuBufferGetMappedRange(buf, 0, (size_t)size);
        if (!p) { wgpuBufferRelease(buf); return nullptr; }
        std::memset(p, 0, (size_t)size);
        std::memcpy(p, values.data(), values.size() * sizeof(float));
        wgpuBufferUnmap(buf);
        return buf;
    }

    struct ScopeRequest { std::atomic<bool> done{false}; WGPUPopErrorScopeStatus status{}; WGPUErrorType type{}; std::string message; };
    static void onScope(WGPUPopErrorScopeStatus status, WGPUErrorType type, WGPUStringView message,
                        void *u1, void *) {
        auto *r = (ScopeRequest *)u1;
        r->status = status; r->type = type; r->message = str(message);
        r->done = true;
    }

    // Closes the validation scope opened before recording; true when nothing in it was invalid.
    // wgpu-native turns a submitted invalid command buffer into a Rust panic that aborts the process,
    // which a library whose every call is allowed to answer "false" must never reach.
    bool endValidation() {
        ScopeRequest sr;
        WGPUPopErrorScopeCallbackInfo cb = WGPU_POP_ERROR_SCOPE_CALLBACK_INFO_INIT;
        cb.mode = WGPUCallbackMode_AllowProcessEvents;
        cb.callback = &Backend::onScope;
        cb.userdata1 = &sr;
        wgpuDevicePopErrorScope(device, cb);
        if (!waitFor([&] { return sr.done.load(); }, 30.0)) return false;
        if (sr.status != WGPUPopErrorScopeStatus_Success || sr.type != WGPUErrorType_NoError) {
            logMsg("warn", "wgpu: refusing to submit work that failed validation: " + sr.message);
            return false;
        }
        return true;
    }

    struct MapRequest { std::atomic<bool> done{false}; WGPUMapAsyncStatus status{}; };
    static void onMap(WGPUMapAsyncStatus status, WGPUStringView, void *u1, void *) {
        auto *r = (MapRequest *)u1;
        r->status = status;
        r->done = true;
    }

    // Runs `pipeline` over the destination's packed words and copies the result into `dst`.
    // `sources` are bound at 2...; slots past sources.size() repeat sources[0], so no declared
    // binding is ever left empty (the aligned module declares all 17).
    bool run(WGPUComputePipeline pipeline, const Params &params, const std::vector<WGPUBuffer> &sources,
             int boundSources, WGPUBuffer tilesBuf, const Format &fmt, MatWrapperRef dst) {
        const size_t rowWords = (fmt.rowBytes + 3) / 4;
        const uint64_t outBytes = (uint64_t)rowWords * 4 * (uint64_t)fmt.rows;
        const uint32_t gx = (uint32_t)((rowWords + 7) / 8), gy = (uint32_t)((fmt.rows + 7) / 8);
        if (outBytes > limits.maxStorageBufferBindingSize || gx > limits.maxComputeWorkgroupsPerDimension ||
            gy > limits.maxComputeWorkgroupsPerDimension)
            return false;

        Params p = params;
        p.outWordsPerRow = (uint32_t)rowWords;

        WGPUBuffer paramBuf = makeBuffer(sizeof(Params), WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst, false);
        WGPUBuffer outBuf = makeBuffer(outBytes, WGPUBufferUsage_Storage | WGPUBufferUsage_CopySrc, false);
        WGPUBuffer readBuf = makeBuffer(outBytes, WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst, false);
        WGPUBindGroupLayout layout = nullptr;
        WGPUBindGroup group = nullptr;
        bool ok = false;

        do {
            if (!paramBuf || !outBuf || !readBuf) break;
            wgpuQueueWriteBuffer(queue, paramBuf, 0, &p, sizeof(Params));

            wgpuDevicePushErrorScope(device, WGPUErrorFilter_Validation);
            layout = wgpuComputePipelineGetBindGroupLayout(pipeline, 0);
            std::vector<WGPUBindGroupEntry> entries;
            auto entry = [&](uint32_t binding, WGPUBuffer buffer, uint64_t size) {
                WGPUBindGroupEntry e = WGPU_BIND_GROUP_ENTRY_INIT;
                e.binding = binding; e.buffer = buffer; e.offset = 0; e.size = size;
                entries.push_back(e);
            };
            entry(0, paramBuf, sizeof(Params));
            entry(1, outBuf, outBytes);
            for (int s = 0; s < boundSources; ++s) {
                WGPUBuffer b = s < (int)sources.size() ? sources[(size_t)s] : sources[0];
                entry(2 + (uint32_t)s, b, wgpuBufferGetSize(b));
            }
            entry(19, tilesBuf, wgpuBufferGetSize(tilesBuf));
            WGPUBindGroupDescriptor gd = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
            gd.layout = layout;
            gd.entryCount = entries.size();
            gd.entries = entries.data();
            group = wgpuDeviceCreateBindGroup(device, &gd);

            WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(device, nullptr);
            WGPUComputePassEncoder pass = wgpuCommandEncoderBeginComputePass(enc, nullptr);
            wgpuComputePassEncoderSetPipeline(pass, pipeline);
            wgpuComputePassEncoderSetBindGroup(pass, 0, group, 0, nullptr);
            wgpuComputePassEncoderDispatchWorkgroups(pass, gx, gy, 1);
            wgpuComputePassEncoderEnd(pass);
            wgpuComputePassEncoderRelease(pass);
            wgpuCommandEncoderCopyBufferToBuffer(enc, outBuf, 0, readBuf, 0, outBytes);
            WGPUCommandBuffer cmd = wgpuCommandEncoderFinish(enc, nullptr);
            wgpuCommandEncoderRelease(enc);
            if (!endValidation()) {
                if (cmd) wgpuCommandBufferRelease(cmd);
                break;
            }
            wgpuQueueSubmit(queue, 1, &cmd);
            wgpuCommandBufferRelease(cmd);

            MapRequest mr;
            WGPUBufferMapCallbackInfo mcb = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
            mcb.mode = WGPUCallbackMode_AllowProcessEvents;
            mcb.callback = &Backend::onMap;
            mcb.userdata1 = &mr;
            wgpuBufferMapAsync(readBuf, WGPUMapMode_Read, 0, (size_t)outBytes, mcb);
            wgpuDevicePoll(device, true, nullptr);
            if (!waitFor([&] { return mr.done.load(); }, 120.0)) break;
            if (mr.status != WGPUMapAsyncStatus_Success || deviceError.load()) break;

            const uint8_t *mapped = (const uint8_t *)wgpuBufferGetConstMappedRange(readBuf, 0, (size_t)outBytes);
            auto *dstPtr = (uint8_t *)const_cast<void *>(mat_wrapper_data_ptr(dst));
            if (!mapped || !dstPtr) { wgpuBufferUnmap(readBuf); break; }
            const size_t dstStep = mat_wrapper_step(dst);
            for (int r = 0; r < fmt.rows; ++r)
                std::memcpy(dstPtr + (size_t)r * dstStep, mapped + (size_t)r * rowWords * 4, fmt.rowBytes);
            wgpuBufferUnmap(readBuf);
            ok = true;
        } while (false);

        if (group) wgpuBindGroupRelease(group);
        if (layout) wgpuBindGroupLayoutRelease(layout);
        for (WGPUBuffer b : {paramBuf, outBuf, readBuf}) if (b) { wgpuBufferDestroy(b); wgpuBufferRelease(b); }
        return ok && !deviceError.load();
    }
};

Backend *g_backend = nullptr;
std::once_flag g_once;

// Opt-in until it has been measured on real hardware: nothing touches a GPU driver (and so nothing can
// crash in one) unless STAR_WGPU is set. Tests and CI set it.
Backend *backend() {
    if (!envFlag("STAR_WGPU")) return nullptr;
    std::call_once(g_once, [] {
        auto *b = new Backend();
        if (b->init()) g_backend = b;   // a failed start-up is not retried; the object is left to the OS
    });
    return g_backend;
}

// Frees every source buffer when an operation ends, however it ends.
struct Sources {
    std::vector<WGPUBuffer> buffers;
    ~Sources() { for (WGPUBuffer b : buffers) { wgpuBufferDestroy(b); wgpuBufferRelease(b); } }
};

}  // namespace

extern "C" {

bool wgpu_ops_compiled_in(void) { return true; }

bool wgpu_ops_available(void) { return backend() != nullptr; }

const char *wgpu_ops_device_description(void) {
    Backend *b = backend();
    return b ? b->description.c_str() : nullptr;
}

bool wgpu_ops_aligned_merge_supported(void) {
    Backend *b = backend();
    return b && b->alignedOK;
}

bool wgpu_ops_opted_in(void) { return envFlag("STAR_WGPU"); }

bool wgpu_ops_warp(MatWrapperRef src, const double *homography, MatWrapperRef dst) {
    Backend *b = backend();
    if (!b || !src || !dst || !homography) return false;
    Format fmt;
    Plane srcPlane;
    if (!Format::of(src, fmt) || !fmt.plane(src, srcPlane)) return false;
    Plane dstPlane;
    if (!fmt.plane(dst, dstPlane)) return false;
    double inverse[9];
    if (!invert3x3(homography, inverse)) return false;

    Params params = {};
    params.width = (uint32_t)fmt.cols;
    params.height = (uint32_t)fmt.rows;
    params.channels = (uint32_t)fmt.channels;
    params.steps[0] = (uint32_t)srcPlane.step;
    params.tilesX = (uint32_t)((fmt.cols + (int)kTile - 1) / (int)kTile);
    params.tilesPerNeighbour = params.tilesX * (uint32_t)((fmt.rows + (int)kTile - 1) / (int)kTile);
    for (int k = 0; k < 9; ++k) params.hinv[k] = (float)inverse[k];
    std::vector<float> tiles;
    appendTiles(inverse, fmt.rows, fmt.cols, tiles);

    std::lock_guard<std::mutex> lock(b->mutex);
    b->deviceError = false;
    Sources sources;
    WGPUBuffer sb = b->sourceBuffer(srcPlane);
    if (!sb) return false;
    sources.buffers.push_back(sb);
    WGPUBuffer tb = b->floatBuffer(tiles);
    if (!tb) return false;
    sources.buffers.push_back(tb);   // freed with the rest
    std::vector<WGPUBuffer> images(sources.buffers.begin(), sources.buffers.begin() + 1);
    return b->run(b->warp[fmt.bpc - 1], params, images, 1, tb, fmt, dst);
}

bool wgpu_ops_aligned_merge(MatWrapperRef base, MatWrapperRef *neighbours, int neighbourCount,
                            const double *homographies, double outlierThreshold, bool includeAll,
                            MatWrapperRef dst) {
    Backend *b = backend();
    if (!b || !b->alignedOK || !base || !neighbours || !homographies || !dst) return false;
    if (neighbourCount < 1 || neighbourCount + 1 > kMaxSources) return false;
    Format fmt;
    if (!Format::of(base, fmt)) return false;
    Plane dstPlane;
    if (!fmt.plane(dst, dstPlane)) return false;

    std::vector<Plane> planes((size_t)neighbourCount + 1);
    if (!fmt.plane(base, planes[0])) return false;
    for (int i = 0; i < neighbourCount; ++i)
        if (!fmt.plane(neighbours[i], planes[(size_t)i + 1])) return false;

    Params params = {};
    params.width = (uint32_t)fmt.cols;
    params.height = (uint32_t)fmt.rows;
    params.channels = (uint32_t)fmt.channels;
    params.count = (uint32_t)neighbourCount;
    params.includeAll = includeAll ? 1u : 0u;
    params.outlier = (float)outlierThreshold;
    for (int i = 0; i <= neighbourCount; ++i) params.steps[i] = (uint32_t)planes[(size_t)i].step;
    params.tilesX = (uint32_t)((fmt.cols + (int)kTile - 1) / (int)kTile);
    params.tilesPerNeighbour = params.tilesX * (uint32_t)((fmt.rows + (int)kTile - 1) / (int)kTile);
    std::vector<float> tiles;
    for (int i = 0; i < neighbourCount; ++i) {
        double inverse[9];
        if (!invert3x3(homographies + i * 9, inverse)) return false;
        for (int k = 0; k < 9; ++k) params.hinv[i * 9 + k] = (float)inverse[k];
        appendTiles(inverse, fmt.rows, fmt.cols, tiles);
    }

    std::lock_guard<std::mutex> lock(b->mutex);
    b->deviceError = false;
    Sources sources;
    for (const Plane &plane : planes) {
        WGPUBuffer sb = b->sourceBuffer(plane);
        if (!sb) return false;
        sources.buffers.push_back(sb);
    }
    const size_t imageBuffers = sources.buffers.size();
    WGPUBuffer tb = b->floatBuffer(tiles);
    if (!tb) return false;
    sources.buffers.push_back(tb);   // freed with the rest, but not bound as a source
    std::vector<WGPUBuffer> images(sources.buffers.begin(), sources.buffers.begin() + (long)imageBuffers);
    return b->run(b->aligned[fmt.bpc - 1], params, images, kMaxSources, tb, fmt, dst);
}

// Registers without probing: the handlers start the device on their first call and say "no" when there
// is none, so a process that never turns the GPU on never loads a driver.
bool wgpu_ops_register(void) {
    if (!envFlag("STAR_WGPU")) return false;
    gpu_ops_set_handlers(&wgpu_ops_warp, nullptr, &wgpu_ops_aligned_merge);
    return true;
}

}  // extern "C"

#endif  // STAR_HAVE_WGPU
