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
bool wgpu_ops_median_merge_supported(void) { return false; }
bool wgpu_ops_median_merge(MatWrapperRef *, int, MatWrapperRef, double, bool, MatWrapperRef) { return false; }
bool wgpu_ops_sift_pyramid(MatWrapperRef, bool, double, int, int, MatWrapperRef *) { return false; }
bool wgpu_ops_akaze_pyramid(MatWrapperRef, float, const GPUAkazeLevelInfo *, int, const int *, const float *, int,
                            float, MatWrapperRef *, MatWrapperRef *) { return false; }
bool wgpu_ops_aligned_merge(MatWrapperRef, MatWrapperRef *, int, const double *, double, bool,
                            MatWrapperRef) { return false; }
bool wgpu_ops_opted_in(void) { return false; }
void wgpu_ops_trim_pool(void) {}
bool wgpu_ops_last_timing(double *) { return false; }
bool wgpu_ops_register(void) { return false; }
}

#else  // STAR_HAVE_WGPU

#include <webgpu/webgpu.h>
#include <webgpu/wgpu.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <map>
#include <mutex>
#include <thread>
#include <vector>

#include "WGPUShaders.h"
#include "WGPUImageShaders.h"

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
    uint32_t hasMisses;
    uint32_t missStep;
    uint32_t pad2;
    uint32_t steps[20];   // row step in bytes of source i
    float hinv[144];      // 16 neighbours x nine: the inverse homography, row-major
};
static_assert(sizeof(Params) == 704, "Params must match the WGSL struct");

constexpr uint32_t kTile = 16;   // TS in the shader

constexpr int kMaxSources = 17;        // base + 16 neighbours: the WGSL selects from float[17]
constexpr int kAlignedStorageBuffers = 19;  // 17 sources + the output + the tile table, all declared by the module
constexpr int kMedianStorageBuffers = 20;   // 17 sources + the output + the misses plane (not the tile table)

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

double nowSeconds() {
    using namespace std::chrono;
    return duration<double>(steady_clock::now().time_since_epoch()).count();
}

// Where one operation's time went, in seconds (wgpu_ops_last_timing): building the tile table and
// parameters, creating and filling the source buffers, recording and validating the command buffer, the
// GPU run (submit until the result is mapped), copying the result out, and the whole call.
struct Timing { double prep = 0, upload = 0, record = 0, gpu = 0, copy = 0, total = 0; };

struct Backend {
    WGPUInstance instance = nullptr;
    WGPUAdapter adapter = nullptr;
    WGPUDevice device = nullptr;
    WGPUQueue queue = nullptr;
    WGPULimits limits = WGPU_LIMITS_INIT;
    WGPUShaderModule module = nullptr;
    WGPUComputePipeline aligned[2] = {nullptr, nullptr};   // [bpc - 1]
    WGPUComputePipeline warp[2] = {nullptr, nullptr};
    WGPUComputePipeline median[2] = {nullptr, nullptr};
    bool medianOK = false;

    // The float-image operations of the SIFT and AKAZE pyramids (WGPUImageShaders.h). Built on first use:
    // a process that never builds a pyramid pays nothing for them.
    WGPUShaderModule imageModule = nullptr;
    std::map<std::string, WGPUComputePipeline> imagePipes;
    bool imageFailed = false;
    uint64_t pyramidBudgetBytes = 3072ull << 20;   // STAR_WGPU_PYRAMID_MB: a pyramid bigger than this is refused
    std::string description;
    bool alignedOK = false;

    Timing last;                         // the latest operation's phases, written under `mutex`
    std::mutex mutex;                    // one operation on the device at a time
    std::atomic<bool> deviceError{false};
    std::string lastError;               // guarded by `mutex` while an operation runs

    // ---- buffer pool and uploads ------------------------------------------------------------
    //
    // A buffer made fresh for every call cost most of an aligned merge's time (measured, 12 MP, 8
    // neighbours, Vega 64: 848 of 1157 ms went into creating and filling 648 MB of buffers): wgpu zero-fills
    // a new buffer and the host pages behind it fault in on first touch. Buffers are kept by
    // (usage, exact size) and reused; every one is fully overwritten before use (uploads write the whole
    // buffer, padding included; the output and readback buffers are written whole by the GPU).
    struct PoolKey {
        WGPUBufferUsage usage; uint64_t size;
        bool operator<(const PoolKey &o) const { return usage != o.usage ? usage < o.usage : size < o.size; }
    };
    std::map<PoolKey, std::vector<WGPUBuffer>> freeBuffers;
    uint64_t pooledBytes = 0;
    uint64_t poolCapBytes = 4096ull << 20;   // STAR_WGPU_POOL_MB; what the free list may hold
    // Staging is the default because wgpuQueueWriteBuffer is far slower here (measured, 12 MP, 8 neighbours,
    // Vega 64 through Metal: 815 ms to upload 648 MB against 152 ms through a persistent mapped staging
    // buffer, and the "GPU" phase 245 ms against 77, because the queue's deferred copies run inside it).
    enum class Upload { Write, Staging };
    Upload uploadMode = Upload::Staging;     // STAR_WGPU_UPLOAD=write|staging
    uint64_t stagingChunk = 8ull << 20;      // STAR_WGPU_STAGING_MB; measured 8 > 32 > 64 > 128 (12 MP, Vega 64)

    WGPUBuffer makeBuffer(uint64_t size, WGPUBufferUsage usage, bool mapped) {
        if (size > limits.maxBufferSize) return nullptr;
        WGPUBufferDescriptor d = WGPU_BUFFER_DESCRIPTOR_INIT;
        d.usage = usage;
        d.size = size;
        d.mappedAtCreation = mapped ? 1 : 0;
        return wgpuDeviceCreateBuffer(device, &d);
    }

    WGPUBuffer acquire(uint64_t size, WGPUBufferUsage usage) {
        auto it = freeBuffers.find(PoolKey{usage, size});
        if (it != freeBuffers.end() && !it->second.empty()) {
            WGPUBuffer b = it->second.back();
            it->second.pop_back();
            pooledBytes -= size;
            return b;
        }
        return makeBuffer(size, usage, false);
    }

    void give(WGPUBuffer b, uint64_t size, WGPUBufferUsage usage) {
        if (pooledBytes + size > poolCapBytes) { wgpuBufferDestroy(b); wgpuBufferRelease(b); return; }
        freeBuffers[PoolKey{usage, size}].push_back(b);
        pooledBytes += size;
    }

    // Frees every pooled buffer; for memory pressure. Safe to call between operations only.
    void trimPool() {
        for (auto &entry : freeBuffers)
            for (WGPUBuffer b : entry.second) { wgpuBufferDestroy(b); wgpuBufferRelease(b); }
        freeBuffers.clear();
        pooledBytes = 0;
    }

    // Buffers taken for one operation, handed back to the pool however it ends.
    struct Lease {
        Backend &backend;
        struct Item { WGPUBuffer buffer; uint64_t size; WGPUBufferUsage usage; };
        std::vector<Item> items;
        // Set when the operation failed part-way: a buffer may be left mapped or still in use, so none
        // of them goes back to the pool.
        bool discard = false;
        explicit Lease(Backend &b) : backend(b) {}
        Lease(const Lease &) = delete;
        Lease &operator=(const Lease &) = delete;
        ~Lease() {
            for (const Item &i : items) {
                if (discard) { wgpuBufferDestroy(i.buffer); wgpuBufferRelease(i.buffer); }
                else backend.give(i.buffer, i.size, i.usage);
            }
        }
        WGPUBuffer take(uint64_t size, WGPUBufferUsage usage) {
            WGPUBuffer b = backend.acquire(size, usage);
            if (b) items.push_back(Item{b, size, usage});
            return b;
        }
    };

    struct MapWriteRequest { std::atomic<bool> done{false}; WGPUMapAsyncStatus status{}; };
    static void onMapWrite(WGPUMapAsyncStatus status, WGPUStringView, void *u1, void *) {
        auto *r = (MapWriteRequest *)u1;
        r->status = status; r->done = true;
    }

    // Fills `dst` (`size` bytes, a multiple of four) with `length` bytes from `src` and zeros after.
    bool upload(WGPUBuffer dst, uint64_t size, const uint8_t *src, size_t length) {
        if (uploadMode == Upload::Write || size <= (1ull << 20)) {   // small: not worth a staging round trip
            const size_t whole = length & ~(size_t)3;
            if (whole) wgpuQueueWriteBuffer(queue, dst, 0, src, whole);
            if (size > whole) {
                uint8_t tail[4] = {0, 0, 0, 0};
                std::memcpy(tail, src + whole, length - whole);
                wgpuQueueWriteBuffer(queue, dst, whole, tail, 4);
            }
            return true;
        }
        // Staging: two persistent mapped buffers, filled and copied in turn. A mapAsync on a buffer the GPU
        // is still reading completes when it is done, so while the GPU copies chunk i out of one buffer the
        // CPU is already filling the other with chunk i + 1. (Waiting with a blocking device poll here
        // would wait for the whole queue and undo that, so only the map callback is waited for.)
        const uint64_t chunk = std::min<uint64_t>(stagingChunk, size);
        const int buffersNeeded = size > chunk ? 2 : 1;
        Lease lease(*this);
        WGPUBuffer stages[2] = {nullptr, nullptr};
        for (int i = 0; i < buffersNeeded; ++i) {
            stages[i] = lease.take(chunk, WGPUBufferUsage_MapWrite | WGPUBufferUsage_CopySrc);
            if (!stages[i]) { lease.discard = true; return false; }
        }
        int turn = 0;
        for (uint64_t off = 0; off < size; off += chunk, turn = (turn + 1) % buffersNeeded) {
            WGPUBuffer stage = stages[turn];
            const uint64_t n = std::min<uint64_t>(chunk, size - off);
            MapWriteRequest mr;
            WGPUBufferMapCallbackInfo cb = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
            cb.mode = WGPUCallbackMode_AllowProcessEvents;
            cb.callback = &Backend::onMapWrite;
            cb.userdata1 = &mr;
            wgpuBufferMapAsync(stage, WGPUMapMode_Write, 0, (size_t)n, cb);
            if (!waitFor([&] { return mr.done.load(); }, 60.0) || mr.status != WGPUMapAsyncStatus_Success) {
                lease.discard = true;
                return false;
            }
            auto *p = (uint8_t *)wgpuBufferGetMappedRange(stage, 0, (size_t)n);
            if (!p) { lease.discard = true; return false; }
            const size_t have = off < length ? (size_t)std::min<uint64_t>(n, length - off) : 0;
            if (have) std::memcpy(p, src + off, have);
            if (have < n) std::memset(p + have, 0, (size_t)(n - have));
            wgpuBufferUnmap(stage);
            WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(device, nullptr);
            wgpuCommandEncoderCopyBufferToBuffer(enc, stage, 0, dst, off, n);
            WGPUCommandBuffer cmd = wgpuCommandEncoderFinish(enc, nullptr);
            wgpuCommandEncoderRelease(enc);
            wgpuQueueSubmit(queue, 1, &cmd);
            wgpuCommandBufferRelease(cmd);
        }
        return true;
    }

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
        if (const char *m = std::getenv("STAR_WGPU_UPLOAD"))
            uploadMode = std::strcmp(m, "write") == 0 ? Upload::Write : Upload::Staging;
        if (const char *m = std::getenv("STAR_WGPU_POOL_MB")) poolCapBytes = (uint64_t)std::atoll(m) << 20;
        if (const char *m = std::getenv("STAR_WGPU_PYRAMID_MB")) pyramidBudgetBytes = (uint64_t)std::atoll(m) << 20;
        if (const char *m = std::getenv("STAR_WGPU_STAGING_MB")) stagingChunk = std::max<uint64_t>(1, (uint64_t)std::atoll(m)) << 20;

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
        medianOK = limits.maxStorageBuffersPerShaderStage >= (uint32_t)kMedianStorageBuffers &&
                   limits.maxBindingsPerBindGroup >= (uint32_t)(kMedianStorageBuffers + 1) &&
                   limits.maxUniformBufferBindingSize >= sizeof(Params);
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
            if (medianOK) median[bpc - 1] = make("median_main");
        }
        wgpuDevicePoll(device, true, nullptr);
        if (deviceError.load() || !warp[0] || !warp[1] || (alignedOK && (!aligned[0] || !aligned[1])) ||
            (medianOK && (!median[0] || !median[1]))) {
            logMsg("warn", "wgpu: the kernels did not compile on " + description);
            return false;
        }
        logMsg("info", "wgpu backend ready on " + description);
        return true;
    }

    // The pipeline for one float-image entry point, created on first use; null when it will not build.
    WGPUComputePipeline imagePipeline(const std::string &entry) {
        auto it = imagePipes.find(entry);
        if (it != imagePipes.end()) return it->second;
        if (imageFailed) return nullptr;
        wgpuDevicePushErrorScope(device, WGPUErrorFilter_Validation);
        if (!imageModule) {
            WGPUShaderSourceWGSL wgsl = WGPU_SHADER_SOURCE_WGSL_INIT;
            wgsl.code = WGPUStringView{kWgslImageSource, std::strlen(kWgslImageSource)};
            WGPUShaderModuleDescriptor md = WGPU_SHADER_MODULE_DESCRIPTOR_INIT;
            md.label = sv("star image kernels");
            md.nextInChain = &wgsl.chain;
            imageModule = wgpuDeviceCreateShaderModule(device, &md);
        }
        WGPUComputePipeline pipe = nullptr;
        if (imageModule) {
            WGPUComputePipelineDescriptor pd = WGPU_COMPUTE_PIPELINE_DESCRIPTOR_INIT;
            pd.label = sv(entry.c_str());
            pd.layout = nullptr;
            pd.compute.module = imageModule;
            pd.compute.entryPoint = sv(entry.c_str());
            pipe = wgpuDeviceCreateComputePipeline(device, &pd);
        }
        if (!endValidation() || !pipe) {
            logMsg("warn", "wgpu: the image kernel '" + entry + "' did not compile; pyramids stay on the CPU");
            imageFailed = true;
            return nullptr;
        }
        imagePipes[entry] = pipe;
        return pipe;
    }

    // ---- one operation ----------------------------------------------------------------------

    // A storage buffer holding `plane`'s bytes as they are (row step and all), padded to whole words.
    WGPUBuffer sourceBuffer(Lease &lease, const Plane &plane) {
        uint64_t size = (plane.length + 3) & ~(uint64_t)3;
        if (size == 0) size = 4;
        if (size > limits.maxStorageBufferBindingSize) return nullptr;
        WGPUBuffer buf = lease.take(size, WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst);
        if (!buf || !upload(buf, size, plane.ptr, plane.length)) return nullptr;
        return buf;
    }

    // A storage buffer holding `values`.
    WGPUBuffer floatBuffer(Lease &lease, const std::vector<float> &values) {
        uint64_t size = (uint64_t)values.size() * sizeof(float);
        if (size == 0) size = 4;
        if (size > limits.maxStorageBufferBindingSize) return nullptr;
        WGPUBuffer buf = lease.take(size, WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst);
        if (!buf || !upload(buf, size, (const uint8_t *)values.data(), values.size() * sizeof(float)))
            return nullptr;
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
    bool run(Lease &lease, WGPUComputePipeline pipeline, const Params &params,
             const std::vector<WGPUBuffer> &sources, int boundSources,
             const std::vector<std::pair<uint32_t, WGPUBuffer>> &extraBindings,
             const Format &fmt, MatWrapperRef dst) {
        const double tStart = nowSeconds();
        double tRecorded = tStart, tMapped = tStart;
        const size_t rowWords = (fmt.rowBytes + 3) / 4;
        const uint64_t outBytes = (uint64_t)rowWords * 4 * (uint64_t)fmt.rows;
        const uint32_t gx = (uint32_t)((rowWords + 7) / 8), gy = (uint32_t)((fmt.rows + 7) / 8);
        if (outBytes > limits.maxStorageBufferBindingSize || gx > limits.maxComputeWorkgroupsPerDimension ||
            gy > limits.maxComputeWorkgroupsPerDimension)
            return false;

        Params p = params;
        p.outWordsPerRow = (uint32_t)rowWords;

        WGPUBuffer paramBuf = lease.take(sizeof(Params), WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst);
        WGPUBuffer outBuf = lease.take(outBytes, WGPUBufferUsage_Storage | WGPUBufferUsage_CopySrc);
        WGPUBuffer readBuf = lease.take(outBytes, WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst);
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
            for (const auto &extra : extraBindings) entry(extra.first, extra.second, wgpuBufferGetSize(extra.second));
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
            tRecorded = nowSeconds();
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
            tMapped = nowSeconds();

            const uint8_t *mapped = (const uint8_t *)wgpuBufferGetConstMappedRange(readBuf, 0, (size_t)outBytes);
            auto *dstPtr = (uint8_t *)const_cast<void *>(mat_wrapper_data_ptr(dst));
            if (!mapped || !dstPtr) { wgpuBufferUnmap(readBuf); break; }
            const size_t dstStep = mat_wrapper_step(dst);
            for (int r = 0; r < fmt.rows; ++r)
                std::memcpy(dstPtr + (size_t)r * dstStep, mapped + (size_t)r * rowWords * 4, fmt.rowBytes);
            wgpuBufferUnmap(readBuf);
            ok = true;
            const double tCopied = nowSeconds();
            last.record = tRecorded - tStart;
            last.gpu = tMapped - tRecorded;
            last.copy = tCopied - tMapped;
        } while (false);

        if (group) wgpuBindGroupRelease(group);
        if (layout) wgpuBindGroupLayoutRelease(layout);
        if (!ok || deviceError.load()) lease.discard = true;
        return ok && !deviceError.load();
    }
};

// ---- float images and the pyramids ------------------------------------------------------------

struct ImageParams {
    uint32_t w, h, sw, sh;
    int32_t radius;
    uint32_t replicate;
    uint32_t yoff;
    uint32_t pad0;
    float f0, f1, f2, f3;
};
static_assert(sizeof(ImageParams) == 48, "ImageParams must match the WGSL struct IP");

// A float image on the device: tightly packed rows of `w` floats.
struct FImage {
    WGPUBuffer buf = nullptr;
    uint32_t w = 0, h = 0;
    uint64_t bytes() const { return (uint64_t)w * h * 4; }
};

// A chain of float-image operations recorded into one command buffer. Every buffer it names comes from
// the operation's lease; a failure anywhere sets `ok` and the rest of the chain is skipped, so the caller
// checks once, at `submit`.
struct ImageChain {
    Backend &b;
    Backend::Lease &lease;
    WGPUCommandEncoder enc = nullptr;
    std::vector<WGPUBindGroup> groups;
    std::vector<WGPUBindGroupLayout> layouts;
    bool ok = true;
    bool begun = false;

    ImageChain(Backend &backend, Backend::Lease &l) : b(backend), lease(l) {}
    ImageChain(const ImageChain &) = delete;
    ImageChain &operator=(const ImageChain &) = delete;
    ~ImageChain() { finish(); }

    FImage image(uint32_t w, uint32_t h) {
        FImage im;
        im.w = w; im.h = h;
        if (w == 0 || h == 0 || im.bytes() > b.limits.maxStorageBufferBindingSize ||
            im.bytes() > b.limits.maxBufferSize) { ok = false; return im; }
        im.buf = lease.take(im.bytes(), WGPUBufferUsage_Storage | WGPUBufferUsage_CopySrc | WGPUBufferUsage_CopyDst);
        if (!im.buf) ok = false;
        return im;
    }

    // A small read-only buffer (blur weights, resize tables).
    WGPUBuffer small(const void *data, size_t bytes) {
        uint64_t size = (bytes + 3) & ~(size_t)3;
        if (size == 0) size = 4;
        WGPUBuffer buf = lease.take(size, WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst);
        if (!buf) { ok = false; return nullptr; }
        std::vector<uint8_t> padded(size, 0);
        std::memcpy(padded.data(), data, bytes);
        if (!b.upload(buf, size, padded.data(), size)) ok = false;
        return buf;
    }

    void begin() {
        wgpuDevicePushErrorScope(b.device, WGPUErrorFilter_Validation);
        enc = wgpuDeviceCreateCommandEncoder(b.device, nullptr);
        begun = true;
    }

    // One dispatch over the destination's w x h. `bindings` are (binding index, buffer) for the entry
    // point's own bindings 1...5; the uniform parameters are binding 0.
    void dispatch(const char *entry, const ImageParams &p,
                  std::initializer_list<std::pair<uint32_t, WGPUBuffer>> bindings) {
        if (!ok || !begun) { ok = false; return; }
        const uint32_t gx = (p.w + 7) / 8, gy = (p.h + 7) / 8;
        WGPUComputePipeline pipe = b.imagePipeline(entry);
        WGPUBuffer ub = lease.take(sizeof(ImageParams), WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst);
        if (!pipe || !ub || gx > b.limits.maxComputeWorkgroupsPerDimension ||
            gy > b.limits.maxComputeWorkgroupsPerDimension) { ok = false; return; }
        wgpuQueueWriteBuffer(b.queue, ub, 0, &p, sizeof(ImageParams));
        WGPUBindGroupLayout layout = wgpuComputePipelineGetBindGroupLayout(pipe, 0);
        std::vector<WGPUBindGroupEntry> entries;
        auto add = [&](uint32_t binding, WGPUBuffer buffer) {
            WGPUBindGroupEntry e = WGPU_BIND_GROUP_ENTRY_INIT;
            e.binding = binding; e.buffer = buffer; e.offset = 0; e.size = wgpuBufferGetSize(buffer);
            entries.push_back(e);
        };
        add(0, ub);
        for (const auto &bd : bindings) add(bd.first, bd.second);
        WGPUBindGroupDescriptor gd = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
        gd.layout = layout;
        gd.entryCount = entries.size();
        gd.entries = entries.data();
        WGPUBindGroup group = wgpuDeviceCreateBindGroup(b.device, &gd);
        layouts.push_back(layout);
        groups.push_back(group);
        WGPUComputePassEncoder pass = wgpuCommandEncoderBeginComputePass(enc, nullptr);
        wgpuComputePassEncoderSetPipeline(pass, pipe);
        wgpuComputePassEncoderSetBindGroup(pass, 0, group, 0, nullptr);
        wgpuComputePassEncoderDispatchWorkgroups(pass, gx, gy, 1);
        wgpuComputePassEncoderEnd(pass);
        wgpuComputePassEncoderRelease(pass);
    }

    void copy(const FImage &from, const FImage &to) {
        if (!ok || !begun) { ok = false; return; }
        wgpuCommandEncoderCopyBufferToBuffer(enc, from.buf, 0, to.buf, 0, from.bytes());
    }

    // Ends the recording and, when everything validated, runs it to completion.
    bool submit() {
        if (!begun) return false;
        WGPUCommandBuffer cmd = wgpuCommandEncoderFinish(enc, nullptr);
        wgpuCommandEncoderRelease(enc);
        enc = nullptr;
        begun = false;
        const bool valid = b.endValidation();
        bool good = ok && valid && cmd;
        if (good) {
            wgpuQueueSubmit(b.queue, 1, &cmd);
            wgpuDevicePoll(b.device, true, nullptr);
            good = !b.deviceError.load();
        }
        if (cmd) wgpuCommandBufferRelease(cmd);
        for (WGPUBindGroup g : groups) if (g) wgpuBindGroupRelease(g);
        for (WGPUBindGroupLayout l : layouts) if (l) wgpuBindGroupLayoutRelease(l);
        groups.clear(); layouts.clear();
        if (!good) { ok = false; lease.discard = true; }
        return good;
    }

    // Anything still recording when the chain goes out of scope is closed off without being run.
    void finish() {
        if (begun) {
            WGPUCommandBuffer cmd = wgpuCommandEncoderFinish(enc, nullptr);
            wgpuCommandEncoderRelease(enc);
            enc = nullptr; begun = false;
            b.endValidation();
            if (cmd) wgpuCommandBufferRelease(cmd);
            lease.discard = true;
        }
        for (WGPUBindGroup g : groups) if (g) wgpuBindGroupRelease(g);
        for (WGPUBindGroupLayout l : layouts) if (l) wgpuBindGroupLayoutRelease(l);
        groups.clear(); layouts.clear();
    }
};

// The coefficients cv::GaussianBlur convolves a CV_32F image with for `sigma` and an odd kernel `size`:
// cv::getGaussianKernel's exp(-x^2 / 2 sigma^2), normalised to sum to one, in double, handed over as float.
// `size` <= 0 is GaussianBlur's own rule for float depths, cvRound(sigma * 4 * 2 + 1) | 1.
std::vector<float> gaussianKernel(double sigma, int explicitSize = 0) {
    const int size = explicitSize > 0 ? explicitSize : ((int)std::nearbyint(sigma * 4 * 2 + 1) | 1);
    const int half = size / 2;
    const double scale = -0.5 / (sigma * sigma);
    std::vector<double> raw((size_t)size);
    double sum = 0;
    for (int i = 0; i < size; ++i) {
        const double x = (double)(i - half);
        raw[(size_t)i] = std::exp(scale * x * x);
        sum += raw[(size_t)i];
    }
    std::vector<float> out((size_t)size);
    for (int i = 0; i < size; ++i) out[(size_t)i] = (float)(raw[(size_t)i] / sum);
    return out;
}

// computeResizeAreaTab (OpenCV's resize.cpp) for one axis of an INTER_AREA downscale from `source` to
// `destination` samples: per destination index four (source index, weight) slots in the order OpenCV sums
// them, unused ones -1. Built in double, as OpenCV builds it: its 1e-3 cut-offs on the partial cells are
// compared at that precision, which a float on the GPU could not reproduce. False when a destination index
// would need more than four taps, which a downscale by at most about 2 never does.
bool areaResizeTable(int source, int destination, std::vector<int32_t> &index, std::vector<float> &weight) {
    if (source <= 0 || destination <= 0 || destination > source) return false;
    const double scale = 1.0 / ((double)destination / (double)source);
    index.assign((size_t)destination * 4, -1);
    weight.assign((size_t)destination * 4, 0.0f);
    for (int d = 0; d < destination; ++d) {
        const double fs1 = (double)d * scale;
        const double fs2 = fs1 + scale;
        const double cellWidth = std::min(scale, (double)source - fs1);
        int s1 = (int)std::ceil(fs1);
        const int s2 = std::min((int)std::floor(fs2), source - 1);
        s1 = std::min(s1, s2);
        std::vector<std::pair<int, float>> taps;
        if ((double)s1 - fs1 > 1e-3) taps.push_back({s1 - 1, (float)(((double)s1 - fs1) / cellWidth)});
        for (int t = s1; t < s2; ++t) taps.push_back({t, (float)(1.0 / cellWidth)});
        if (fs2 - (double)s2 > 1e-3)
            taps.push_back({s2, (float)(std::min(std::min(fs2 - (double)s2, 1.0), cellWidth) / cellWidth)});
        if (taps.size() > 4) return false;
        for (size_t k = 0; k < taps.size(); ++k) {
            index[(size_t)d * 4 + k] = taps[k].first;
            weight[(size_t)d * 4 + k] = taps[k].second;
        }
    }
    return true;
}

// cv::GaussianBlur(src, dst, Size(size, size), sigma, sigma, border) on a CV_32F image: rows, then
// columns, through `tmp`. The border is BORDER_REFLECT_101 unless `replicate`.
void gaussianBlur(ImageChain &c, const FImage &src, const FImage &tmp, const FImage &dst, double sigma,
                  int size = 0, bool replicate = false) {
    const std::vector<float> weights = gaussianKernel(sigma, size);
    WGPUBuffer wb = c.small(weights.data(), weights.size() * sizeof(float));
    ImageParams p = {};
    p.w = src.w; p.h = src.h; p.sw = src.w; p.sh = src.h;
    p.radius = (int32_t)(weights.size() / 2);
    p.replicate = replicate ? 1u : 0u;
    c.dispatch("gauss_row", p, {{1, src.buf}, {2, tmp.buf}, {3, wb}});
    c.dispatch("gauss_col", p, {{1, tmp.buf}, {2, dst.buf}, {3, wb}});
}

// Copies a finished image out into a new CV_32FC1 Mat (the caller releases it). Runs on its own submission.
MatWrapperRef readImage(Backend &b, Backend::Lease &lease, const FImage &im) {
    WGPUBuffer rb = lease.take(im.bytes(), WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst);
    if (!rb) return nullptr;
    wgpuDevicePushErrorScope(b.device, WGPUErrorFilter_Validation);
    WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(b.device, nullptr);
    wgpuCommandEncoderCopyBufferToBuffer(enc, im.buf, 0, rb, 0, im.bytes());
    WGPUCommandBuffer cmd = wgpuCommandEncoderFinish(enc, nullptr);
    wgpuCommandEncoderRelease(enc);
    if (!b.endValidation()) { if (cmd) wgpuCommandBufferRelease(cmd); lease.discard = true; return nullptr; }
    wgpuQueueSubmit(b.queue, 1, &cmd);
    wgpuCommandBufferRelease(cmd);
    Backend::MapRequest mr;
    WGPUBufferMapCallbackInfo mcb = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
    mcb.mode = WGPUCallbackMode_AllowProcessEvents;
    mcb.callback = &Backend::onMap;
    mcb.userdata1 = &mr;
    wgpuBufferMapAsync(rb, WGPUMapMode_Read, 0, (size_t)im.bytes(), mcb);
    if (!b.waitFor([&] { return mr.done.load(); }, 120.0) || mr.status != WGPUMapAsyncStatus_Success) {
        lease.discard = true;
        return nullptr;
    }
    const uint8_t *mapped = (const uint8_t *)wgpuBufferGetConstMappedRange(rb, 0, (size_t)im.bytes());
    MatWrapperRef mat = mapped ? mat_wrapper_new((int64_t)im.w, (int64_t)im.h, mat_wrapper_cv_type_for(32, 1))
                               : nullptr;
    if (mat) {
        auto *out = (uint8_t *)const_cast<void *>(mat_wrapper_data_ptr(mat));
        const size_t step = mat_wrapper_step(mat);
        for (uint32_t r = 0; r < im.h; ++r)
            std::memcpy(out + (size_t)r * step, mapped + (size_t)r * im.w * 4, (size_t)im.w * 4);
    }
    wgpuBufferUnmap(rb);
    return mat;
}

// A base image uploaded into a new float image, repacked first when its rows are padded.
FImage uploadBase(Backend &b, ImageChain &c, MatWrapperRef base) {
    const uint32_t cols = (uint32_t)mat_wrapper_cols(base), rows = (uint32_t)mat_wrapper_rows(base);
    FImage im = c.image(cols, rows);
    if (!c.ok) return im;
    const uint8_t *ptr = (const uint8_t *)mat_wrapper_data_ptr(base);
    const size_t step = mat_wrapper_step(base);
    if (!ptr) { c.ok = false; return im; }
    bool uploaded;
    if (step == (size_t)cols * 4) {
        uploaded = b.upload(im.buf, im.bytes(), ptr, (size_t)im.bytes());
    } else {
        std::vector<uint8_t> packed((size_t)im.bytes());
        for (uint32_t r = 0; r < rows; ++r)
            std::memcpy(packed.data() + (size_t)r * cols * 4, ptr + (size_t)r * step, (size_t)cols * 4);
        uploaded = b.upload(im.buf, im.bytes(), packed.data(), packed.size());
    }
    if (!uploaded) c.ok = false;
    return im;
}

std::atomic<Backend *> g_backend{nullptr};   // set once, after a successful start-up
std::once_flag g_once;

// Opt-in until it has been measured on real hardware: nothing touches a GPU driver (and so nothing can
// crash in one) unless STAR_WGPU is set. Tests and CI set it.
Backend *backend() {
    if (!envFlag("STAR_WGPU")) return nullptr;
    std::call_once(g_once, [] {
        auto *b = new Backend();
        if (b->init()) g_backend.store(b);   // a failed start-up is not retried; the object is left to the OS
    });
    return g_backend.load();
}

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

void wgpu_ops_trim_pool(void) {
    // never starts the backend: a memory-pressure trim in a process that does not use it must stay free
    Backend *b = g_backend.load();
    if (!b) return;
    std::lock_guard<std::mutex> lock(b->mutex);
    b->trimPool();
}

bool wgpu_ops_last_timing(double *seconds) {
    Backend *b = backend();
    if (!b || !seconds) return false;
    std::lock_guard<std::mutex> lock(b->mutex);
    const Timing &t = b->last;
    seconds[0] = t.prep; seconds[1] = t.upload; seconds[2] = t.record;
    seconds[3] = t.gpu;  seconds[4] = t.copy;   seconds[5] = t.total;
    return true;
}

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

    const double tStart = nowSeconds();
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

    const double tPrepared = nowSeconds();
    std::lock_guard<std::mutex> lock(b->mutex);
    b->deviceError = false;
    b->last = Timing();
    Backend::Lease lease(*b);
    WGPUBuffer sb = b->sourceBuffer(lease, srcPlane);
    if (!sb) return false;
    WGPUBuffer tb = b->floatBuffer(lease, tiles);
    if (!tb) return false;
    std::vector<WGPUBuffer> images{sb};
    const double tUploaded = nowSeconds();
    const bool ok = b->run(lease, b->warp[fmt.bpc - 1], params, images, 1, {{19, tb}}, fmt, dst);
    b->last.prep = tPrepared - tStart;
    b->last.upload = tUploaded - tPrepared;
    b->last.total = nowSeconds() - tStart;
    return ok;
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

    const double tStart = nowSeconds();
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

    const double tPrepared = nowSeconds();
    std::lock_guard<std::mutex> lock(b->mutex);
    b->deviceError = false;
    b->last = Timing();
    Backend::Lease lease(*b);
    std::vector<WGPUBuffer> images;
    for (const Plane &plane : planes) {
        WGPUBuffer sb = b->sourceBuffer(lease, plane);
        if (!sb) return false;
        images.push_back(sb);
    }
    WGPUBuffer tb = b->floatBuffer(lease, tiles);
    if (!tb) return false;
    const double tUploaded = nowSeconds();
    const bool ok = b->run(lease, b->aligned[fmt.bpc - 1], params, images, kMaxSources, {{19, tb}}, fmt, dst);
    b->last.prep = tPrepared - tStart;
    b->last.upload = tUploaded - tPrepared;
    b->last.total = nowSeconds() - tStart;
    return ok;
}

bool wgpu_ops_median_merge_supported(void) {
    Backend *b = backend();
    return b && b->medianOK;
}

bool wgpu_ops_median_merge(MatWrapperRef *sources, int count, MatWrapperRef misses,
                           double outlierThreshold, bool includeAll, MatWrapperRef dst) {
    Backend *b = backend();
    if (!b || !b->medianOK || !sources || !dst || count < 1 || count > kMaxSources) return false;
    Format fmt;
    if (!Format::of(sources[0], fmt)) return false;
    Plane dstPlane;
    if (!fmt.plane(dst, dstPlane)) return false;
    std::vector<Plane> planes((size_t)count);
    for (int i = 0; i < count; ++i)
        if (!fmt.plane(sources[i], planes[(size_t)i])) return false;

    // The misses plane is one byte a pixel over the same grid; it is ignored when includeAll.
    Plane missPlane;
    const bool useMisses = misses && !includeAll;
    if (useMisses) {
        if ((int)mat_wrapper_rows(misses) != fmt.rows || (int)mat_wrapper_cols(misses) != fmt.cols ||
            mat_wrapper_channels(misses) != 1 || mat_wrapper_bits_per_component(misses) != 8)
            return false;
        const void *mp = mat_wrapper_data_ptr(misses);
        const size_t ms = mat_wrapper_step(misses);
        if (!mp || ms < (size_t)fmt.cols) return false;
        missPlane.ptr = (const uint8_t *)mp;
        missPlane.step = ms;
        missPlane.length = (size_t)(fmt.rows - 1) * ms + (size_t)fmt.cols;
    }

    const double tStart = nowSeconds();
    Params params = {};
    params.width = (uint32_t)fmt.cols;
    params.height = (uint32_t)fmt.rows;
    params.channels = (uint32_t)fmt.channels;
    params.count = (uint32_t)(count - 1);   // sources after the first, as the aligned merge counts neighbours
    params.includeAll = includeAll ? 1u : 0u;
    params.outlier = (float)outlierThreshold;
    for (int i = 0; i < count; ++i) params.steps[i] = (uint32_t)planes[(size_t)i].step;
    params.hasMisses = useMisses ? 1u : 0u;
    params.missStep = useMisses ? (uint32_t)missPlane.step : 0u;
    const double tPrepared = nowSeconds();

    std::lock_guard<std::mutex> lock(b->mutex);
    b->deviceError = false;
    b->last = Timing();
    Backend::Lease lease(*b);
    std::vector<WGPUBuffer> images;
    for (const Plane &plane : planes) {
        WGPUBuffer sb = b->sourceBuffer(lease, plane);
        if (!sb) return false;
        images.push_back(sb);
    }
    WGPUBuffer mb = nullptr;
    if (useMisses) {
        mb = b->sourceBuffer(lease, missPlane);
    } else {
        const std::vector<float> placeholder(1, 0.0f);   // the binding must hold something
        mb = b->floatBuffer(lease, placeholder);
    }
    if (!mb) return false;
    const double tUploaded = nowSeconds();
    const bool ok = b->run(lease, b->median[fmt.bpc - 1], params, images, kMaxSources, {{20, mb}}, fmt, dst);
    b->last.prep = tPrepared - tStart;
    b->last.upload = tUploaded - tPrepared;
    b->last.total = nowSeconds() - tStart;
    return ok;
}

// Builds the Gaussian scale-space pyramid SIFTDetector.cpp needs (GPUSiftPyramidFunc's contract, see
// GPUOps_C.h): octave-major, layer-minor, nOctaves * (nOctaveLayers + 3) new CV_32FC1 Mats in outPyramid.
// A port of buildSiftPyramid in GPUOps.swift: createInitialImage's optional bilinear 2x upscale and its blur
// by sigDiff, then buildGaussianPyramid's incremental sigma schedule, with each new octave the previous
// one's last layer taken at every second pixel. On false nothing in outPyramid is set.
bool wgpu_ops_sift_pyramid(MatWrapperRef base, bool doubleImageSize, double sigma, int nOctaves,
                           int nOctaveLayers, MatWrapperRef *outPyramid) {
    Backend *b = backend();
    if (!b || !base || !outPyramid || nOctaves < 1 || nOctaveLayers < 1) return false;
    if (mat_wrapper_bits_per_component(base) != 32 || mat_wrapper_channels(base) != 1) return false;
    const uint32_t cols = (uint32_t)mat_wrapper_cols(base), rows = (uint32_t)mat_wrapper_rows(base);
    if (cols == 0 || rows == 0) return false;

    // The size of every octave, and what the whole pyramid will hold on the device
    const int layers = nOctaveLayers + 3;
    std::vector<uint32_t> ow((size_t)nOctaves), oh((size_t)nOctaves);
    ow[0] = doubleImageSize ? cols * 2 : cols;
    oh[0] = doubleImageSize ? rows * 2 : rows;
    for (int o = 1; o < nOctaves; ++o) { ow[(size_t)o] = ow[(size_t)o - 1] / 2; oh[(size_t)o] = oh[(size_t)o - 1] / 2; }
    uint64_t total = (uint64_t)cols * rows * 4 * (doubleImageSize ? 5 : 1);
    for (int o = 0; o < nOctaves; ++o) {
        if (ow[(size_t)o] == 0 || oh[(size_t)o] == 0) return false;
        total += (uint64_t)ow[(size_t)o] * oh[(size_t)o] * 4 * (uint64_t)(layers + 1);   // the layers and a scratch
    }
    if (total > b->pyramidBudgetBytes) return false;   // too big for the device's memory: the CPU does it

    std::lock_guard<std::mutex> lock(b->mutex);
    b->deviceError = false;
    Backend::Lease lease(*b);
    ImageChain chain(*b, lease);

    const FImage input = uploadBase(*b, chain, base);
    if (!chain.ok) return false;
    chain.begin();

    FImage current = input;
    if (doubleImageSize) {
        FImage doubled = chain.image(cols * 2, rows * 2);
        ImageParams p = {};
        p.w = cols * 2; p.h = rows * 2; p.sw = cols; p.sh = rows;
        chain.dispatch("upsample_linear_2x", p, {{1, input.buf}, {2, doubled.buf}});
        current = doubled;
    }

    // createInitialImage's own blur by sigDiff, as createInitialImageReference computes it
    const double initSigma = 0.5;
    const double sigDiffSq = doubleImageSize ? sigma * sigma - initSigma * initSigma * 4
                                             : sigma * sigma - initSigma * initSigma;
    const double sigDiff = std::sqrt(std::max(sigDiffSq, 0.01));

    // buildGaussianPyramid's incremental sigma schedule: sigma_total^2 = sigma_i^2 + sigma_{i-1}^2, so
    // blur i only adds what blur i-1 is missing
    std::vector<double> sig((size_t)layers);
    sig[0] = sigma;
    const double k = std::pow(2.0, 1.0 / (double)nOctaveLayers);
    for (int i = 1; i < layers; ++i) {
        const double sigPrev = std::pow(k, (double)(i - 1)) * sigma;
        const double sigTotal = sigPrev * k;
        sig[(size_t)i] = std::sqrt(sigTotal * sigTotal - sigPrev * sigPrev);
    }

    std::vector<FImage> level((size_t)nOctaves * (size_t)layers);
    std::vector<FImage> scratch((size_t)nOctaves);
    for (int o = 0; o < nOctaves; ++o) scratch[(size_t)o] = chain.image(ow[(size_t)o], oh[(size_t)o]);
    level[0] = chain.image(ow[0], oh[0]);
    gaussianBlur(chain, current, scratch[0], level[0], sigDiff);

    for (int o = 0; o < nOctaves && chain.ok; ++o) {
        for (int i = 0; i < layers && chain.ok; ++i) {
            const size_t idx = (size_t)o * (size_t)layers + (size_t)i;
            if (o == 0 && i == 0) continue;
            if (i == 0) {
                // the base of a new octave: the previous octave's last layer at every second pixel
                const FImage &src = level[(size_t)(o - 1) * (size_t)layers + (size_t)nOctaveLayers];
                FImage dst = chain.image(src.w / 2, src.h / 2);
                ImageParams p = {};
                p.w = dst.w; p.h = dst.h; p.sw = src.w; p.sh = src.h;
                chain.dispatch("downsample_nearest_2x", p, {{1, src.buf}, {2, dst.buf}});
                level[idx] = dst;
            } else {
                const FImage &src = level[idx - 1];
                level[idx] = chain.image(src.w, src.h);
                gaussianBlur(chain, src, scratch[(size_t)o], level[idx], sig[(size_t)i]);
            }
        }
    }
    if (!chain.submit()) return false;

    // each level out into its own new Mat
    for (size_t idx = 0; idx < level.size(); ++idx) {
        MatWrapperRef mat = readImage(*b, lease, level[idx]);
        if (!mat) {
            for (size_t j = 0; j < idx; ++j) { mat_wrapper_release(outPyramid[j]); outPyramid[j] = nullptr; }
            return false;
        }
        outPyramid[idx] = mat;
    }
    return true;
}

// Builds the nonlinear diffusion scale-space pyramid AKAZEDetector.cpp needs (GPUAkazePyramidFunc's
// contract, see GPUOps_C.h): outLt / outLsmooth each get `levelCount` new CV_32FC1 Mats (the caller releases
// them). A port of buildAkazePyramid in GPUOps.swift, step for step as AKAZEDetector.cpp's
// buildPyramidReference does it: level 0 is one 9-tap blur (kernel size from soffset); each later level
// is the previous level's Lt halved by INTER_AREA at a new octave or copied within one; its Lsmooth is a
// 5-tap sigma-1 blur of that; Scharr derivatives and the Perona-Malik G2 diffusivity come from Lsmooth;
// and Fast Explicit Diffusion steps (a five-point stencil, then Lt += Lstep) advance Lt. Every AKAZE blur
// reads BORDER_REPLICATE. On false nothing in outLt / outLsmooth is set.
bool wgpu_ops_akaze_pyramid(MatWrapperRef img, float soffset, const GPUAkazeLevelInfo *levels, int levelCount,
                            const int *stepCounts, const float *tsteps, int tstepsCount, float kcontrastBase,
                            MatWrapperRef *outLt, MatWrapperRef *outLsmooth) {
    Backend *b = backend();
    if (!b || !img || !levels || !stepCounts || !outLt || !outLsmooth || levelCount < 2) return false;
    if (mat_wrapper_bits_per_component(img) != 32 || mat_wrapper_channels(img) != 1) return false;
    const uint32_t cols = (uint32_t)mat_wrapper_cols(img), rows = (uint32_t)mat_wrapper_rows(img);
    if (cols == 0 || rows == 0) return false;

    // what the pyramid holds on the device at once: per level its Lt, Lsmooth, Lx, Ly, the flow, one Lstep
    // and a blur scratch, plus the input
    uint64_t total = (uint64_t)cols * rows * 4;
    int totalSteps = 0;
    for (int i = 0; i < levelCount; ++i) {
        if (levels[i].width <= 0 || levels[i].height <= 0) return false;
        total += (uint64_t)levels[i].width * (uint64_t)levels[i].height * 4 * 7;
        if (i > 0) { if (stepCounts[i] < 0) return false; totalSteps += stepCounts[i]; }
    }
    if (totalSteps > 0 && (!tsteps || tstepsCount < totalSteps)) return false;
    if (total > b->pyramidBudgetBytes) return false;

    std::lock_guard<std::mutex> lock(b->mutex);
    b->deviceError = false;
    Backend::Lease lease(*b);
    ImageChain chain(*b, lease);

    const FImage input = uploadBase(*b, chain, img);
    if (!chain.ok) return false;
    chain.begin();

    // blur scratch images by size, shared by that size's blurs (the passes run in order)
    std::map<uint64_t, FImage> scratchBySize;
    auto scratchFor = [&](uint32_t w, uint32_t h) -> FImage {
        const uint64_t key = ((uint64_t)w << 32) | h;
        auto it = scratchBySize.find(key);
        if (it == scratchBySize.end()) it = scratchBySize.emplace(key, chain.image(w, h)).first;
        return it->second;
    };

    // Level 0: one blur by soffset, used as both Lt and Lsmooth (create_nonlinear_scale_space's
    // `evolution[0].Lsmooth.copyTo(evolution[0].Lt)`). The kernel size is buildPyramidReference's,
    // cvCeil(2(1 + (soffset - 0.8) / 0.3)) | 1, in float as it computes it: 9 for the default 1.6.
    const float sizeF = 2.0f * (1.0f + (soffset - 0.8f) / 0.3f);
    const int level0Size = (int)std::ceil(sizeF) | 1;
    std::vector<FImage> lt((size_t)levelCount), smoothImg((size_t)levelCount);
    lt[0] = chain.image(cols, rows);
    gaussianBlur(chain, input, scratchFor(cols, rows), lt[0], (double)soffset, level0Size, true);
    smoothImg[0] = lt[0];

    float kcontrast = kcontrastBase;
    int stepOffset = 0;
    for (int i = 1; i < levelCount && chain.ok; ++i) {
        const uint32_t w = (uint32_t)levels[i].width, h = (uint32_t)levels[i].height;
        const FImage &prev = lt[(size_t)i - 1];

        // this level's pre-diffusion Lt: the previous one halved at a new octave, copied within one
        FImage cur = chain.image(w, h);
        if (levels[i].newOctave != 0) {
            std::vector<int32_t> xi, yi;
            std::vector<float> xw, yw;
            if (!areaResizeTable((int)prev.w, (int)w, xi, xw) || !areaResizeTable((int)prev.h, (int)h, yi, yw)) {
                chain.ok = false;
                break;
            }
            std::vector<float> af(xw);
            af.insert(af.end(), yw.begin(), yw.end());
            std::vector<int32_t> ai(xi);
            ai.insert(ai.end(), yi.begin(), yi.end());
            WGPUBuffer afb = chain.small(af.data(), af.size() * sizeof(float));
            WGPUBuffer aib = chain.small(ai.data(), ai.size() * sizeof(int32_t));
            ImageParams p = {};
            p.w = w; p.h = h; p.sw = prev.w; p.sh = prev.h;
            p.yoff = (uint32_t)xw.size();
            chain.dispatch("resize_area", p, {{1, prev.buf}, {2, cur.buf}, {3, afb}, {4, aib}});
            kcontrast *= 0.75f;
        } else {
            if (prev.w != w || prev.h != h) { chain.ok = false; break; }
            chain.copy(prev, cur);
        }

        // Lsmooth: the fixed 5x5 sigma-1 blur of the pre-diffusion Lt (five taps, not a full Gaussian:
        // truncated at 2 sigma it is narrower than its sigma says)
        FImage smooth = chain.image(w, h);
        gaussianBlur(chain, cur, scratchFor(w, h), smooth, 1.0, 5, true);

        FImage lx = chain.image(w, h), ly = chain.image(w, h), flow = chain.image(w, h);
        ImageParams p = {};
        p.w = w; p.h = h; p.sw = w; p.sh = h;
        chain.dispatch("scharr_x", p, {{1, smooth.buf}, {2, lx.buf}});
        chain.dispatch("scharr_y", p, {{1, smooth.buf}, {2, ly.buf}});
        ImageParams pm = p;
        pm.f0 = kcontrast;
        chain.dispatch("pm_g2", pm, {{1, lx.buf}, {2, flow.buf}, {5, ly.buf}});

        // FED steps: Lstep from the current Lt and the flow, then Lt += Lstep, in place
        const int count = stepCounts[i];
        if (count > 0) {
            FImage lstep = chain.image(w, h);
            for (int sIdx = 0; sIdx < count; ++sIdx) {
                ImageParams step = p;
                step.f0 = tsteps[stepOffset + sIdx];
                chain.dispatch("fed_step", step, {{1, cur.buf}, {2, lstep.buf}, {5, flow.buf}});
                chain.dispatch("add_in_place", p, {{1, lstep.buf}, {2, cur.buf}});
            }
        }
        stepOffset += count;
        lt[(size_t)i] = cur;
        smoothImg[(size_t)i] = smooth;
    }
    if (!chain.submit()) return false;

    // Lt levels, then Lsmooth levels, each out into its own new Mat (level 0 is one image read twice)
    int made = 0;
    auto release = [&] {
        for (int i = 0; i < made; ++i) {
            if (outLt[i]) { mat_wrapper_release(outLt[i]); outLt[i] = nullptr; }
            if (outLsmooth[i]) { mat_wrapper_release(outLsmooth[i]); outLsmooth[i] = nullptr; }
        }
    };
    for (int i = 0; i < levelCount; ++i) {
        outLt[i] = readImage(*b, lease, lt[(size_t)i]);
        outLsmooth[i] = readImage(*b, lease, smoothImg[(size_t)i]);
        made = i + 1;
        if (!outLt[i] || !outLsmooth[i]) { release(); return false; }
    }
    return true;
}

// Registers without probing: the handlers start the device on their first call and say "no" when there
// is none, so a process that never turns the GPU on never loads a driver.
bool wgpu_ops_register(void) {
    if (!envFlag("STAR_WGPU")) return false;
    gpu_ops_set_handlers(&wgpu_ops_warp, &wgpu_ops_median_merge, &wgpu_ops_aligned_merge);
    // Separate registrations, as in GPUOps_C.h: the pyramids are gated by their own Config flags.
    gpu_ops_set_sift_pyramid_handler(&wgpu_ops_sift_pyramid);
    gpu_ops_set_akaze_pyramid_handler(&wgpu_ops_akaze_pyramid);
    return true;
}

}  // extern "C"

#endif  // STAR_HAVE_WGPU
