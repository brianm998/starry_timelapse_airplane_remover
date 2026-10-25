import XCTest
import Darwin
@testable import StarCppBridge

/// A real-run report: GPU-accelerated SIFT was fast, but the median-merge step
/// was "really slow" on a 20-frame 42MP sequence and may have contributed to a
/// crash, only tolerable after cutting `numberOfFramesToProcessConcurrently`
/// from 16 to 8. `GPUOps.swift`'s `gpuSlots` semaphore was added in response —
/// nothing previously bounded how many frame-workers could be inside Metal at
/// once, and this machine's discrete GPU makes that expensive (real PCIe
/// traffic, not a unified-memory pointer handoff).
///
/// Two questions that fix alone doesn't answer, raised independently: is the
/// slowdown/crash actually explained by unbounded concurrency, or could the
/// new Metal kernel code itself have a bug — an unbounded loop or a bad
/// dispatch — that hangs the GPU regardless of how many callers there are?
/// A static read of the shader source (every loop bound is `count`/`channels`,
/// both validated <= 17 / <= 4 before dispatch — see GPUOps.swift) found none,
/// but a static read is not the same as running it. This is the closest thing
/// to that other machine this environment can offer: hammer the exact
/// production entry point (`ImageAligner.medianMergeImage`, `useGPU: true`)
/// with real frame-sized, many-source, many-CONCURRENT merges and require that
/// every one finishes inside a generous timeout. A hang here would mean the
/// kernel itself is the problem, independent of `gpuSlots`; a clean finish
/// does not prove the kernel has no bug on other hardware, but it does rule
/// out the specific failure mode ("this GPU code hangs under load") on this
/// machine — the same Vega 64 the real report came from.
final class GPUOpsConcurrencyStressTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(GPUCapability.isAvailable(), "no supported GPU on this machine")
        GPUOps.registerIfAvailable()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GPUOpsConcurrencyStressTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        ImageCache.setLoader { MatWrapper.load(fromFilename: $0) }
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    /// A coarse, blocky gradient rather than real noise: it still varies
    /// enough per (task, source, pixel) that the sort/outlier-cut logic does
    /// real work, but -- unlike per-pixel random noise -- it is what
    /// `cv::imwrite`'s default LZW encoding actually compresses well. Random
    /// noise here made fixture writing (not the merge under test) the
    /// dominant cost: 180 files of per-pixel noise took ~161s to write versus
    /// 2.1s for all 18 concurrent GPU merges combined once written.
    ///
    /// Static, not an instance method: called from `concurrentPerform`'s
    /// worker threads, and a plain instance method would capture `self` (this
    /// `XCTestCase`, not `Sendable`) into that `@Sendable` closure.
    private static func makeMat(width: Int, height: Int, seed: UInt32) -> MatWrapper {
        let count = width * height
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: count)
        let offset = Int(seed % 400)
        for y in 0..<height {
            for x in 0..<width {
                data[y * width + x] = UInt16(8000 + ((x / 8 + y / 8 + offset) % 400))
            }
        }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 16, componentsPerPixel: 1),
                          bytesPerRow: width * MemoryLayout<UInt16>.size,
                          data: UnsafeMutableRawPointer(data),
                          takeOwnership: true)
    }

    /// 18 concurrent 9-source merges (star's own default neighbour count) at
    /// 2000x1500 (3MP) -- smaller than the reported 42MP so the whole suite
    /// still finishes in reasonable CI time, but the thing under test (how
    /// many independent multi-hundred-MB buffer packs and GPU dispatches can
    /// be in flight against one discrete GPU at once) does not depend on the
    /// frame being 42MP specifically; `gpuSlots` bounds count, not size, and a
    /// kernel hang would not need full resolution to reproduce either.
    func testManyConcurrentMediumFrameMergesCompleteWithoutHangingOrCrashing() {
        let width = 2000, height = 1500
        let sourcesPerMerge = 9
        let concurrentMerges = 18
        let scratchDir = scratch!  // a local, not `self.scratch`, for the @Sendable closure below

        let setupStart = Date()
        // Written concurrently, not in a plain sequential .map: each mat.write
        // call turned out to cost ~0.7s regardless of how compressible the
        // pixel data was (fixed per-call overhead, not a compression cost),
        // and this fixture setup is not the thing under test -- the 18
        // concurrent GPU merges below are.
        let bases = (0..<concurrentMerges).map { Self.makeMat(width: width, height: height, seed: UInt32($0 * 1000)) }
        // A flat, pre-sized buffer where each iteration owns exactly one slot
        // (`flat`) that no other iteration ever touches -- unlike appending to
        // a per-task nested array, which would race across threads even at
        // different outer indices (Array's copy-on-write storage is shared).
        let totalFiles = concurrentMerges * sourcesPerMerge
        nonisolated(unsafe) let flatFilenames = UnsafeMutablePointer<String>.allocate(capacity: totalFiles)
        flatFilenames.initialize(repeating: "", count: totalFiles)
        defer { flatFilenames.deinitialize(count: totalFiles); flatFilenames.deallocate() }
        DispatchQueue.concurrentPerform(iterations: totalFiles) { flat in
            let taskIdx = flat / sourcesPerMerge
            let srcIdx = flat % sourcesPerMerge
            let mat = Self.makeMat(width: width, height: height, seed: UInt32(taskIdx * 1000 + srcIdx + 1))
            let path = scratchDir.appendingPathComponent("t\(taskIdx)-s\(srcIdx).tiff").path
            XCTAssertTrue(mat.write(to: path))
            flatFilenames[flat] = path  // each `flat` is written by exactly one iteration, never re-read here
        }
        struct Job { let base: MatWrapper; let filenames: [String] }
        let jobs = (0..<concurrentMerges).map { taskIdx in
            Job(base: bases[taskIdx],
               filenames: (0..<sourcesPerMerge).map { flatFilenames[taskIdx * sourcesPerMerge + $0] })
        }
        print("STRESS setup (writing \(concurrentMerges * sourcesPerMerge) fixture files) took "
              + "\(Date().timeIntervalSince(setupStart))s")

        let expectation = expectation(description: "every concurrent merge finishes")
        expectation.expectedFulfillmentCount = concurrentMerges

        let resultsLock = NSLock()
        nonisolated(unsafe) var results = [Int: [[UInt16]]]()
        let mergeStart = Date()

        for (taskIdx, job) in jobs.enumerated() {
            DispatchQueue.global(qos: .userInitiated).async {
                let merged = ImageAligner.medianMergeImage(job.base, withFilenames: job.filenames,
                                                           outlierThreshold: 3.0, includeAll: true,
                                                           useGPU: true)!
                var rows: [[UInt16]] = []
                if let base = merged.dataPtr {
                    let step = merged.step
                    rows = (0..<merged.rows).map { y in
                        let row = base.advanced(by: y * step).assumingMemoryBound(to: UInt16.self)
                        return (0..<merged.cols).map { row[$0] }
                    }
                }
                resultsLock.lock()
                results[taskIdx] = rows
                resultsLock.unlock()
                expectation.fulfill()
            }
        }

        // Generous: this is explicitly checking for a hang, not measuring
        // speed, and the machine this reproduces on has already shown ~90s of
        // noise on ordinary full runs (see GPU_IMPLEMENTATION_GUIDE.md ยง0).
        wait(for: [expectation], timeout: 180)
        print("STRESS all \(concurrentMerges) merges finished \(Date().timeIntervalSince(mergeStart))s "
              + "after dispatch")

        XCTAssertEqual(results.count, concurrentMerges,
                       "\(concurrentMerges - results.count) merge(s) never completed inside the timeout — "
                       + "a hang, not a crash, would show up exactly this way")

        for (taskIdx, rows) in results {
            XCTAssertEqual(rows.count, height, "task \(taskIdx) returned the wrong number of rows")
            // Every input pixel is in [8000, 11999]; a sigma-clipped median of
            // 10 values drawn from that range cannot land outside it. Values
            // outside would mean corrupted GPU memory, not merely "different
            // arithmetic" -- a real signature of the out-of-bounds write an
            // unbounded loop would cause.
            for row in rows {
                for value in row {
                    XCTAssertTrue((8000...11999).contains(value),
                                  "task \(taskIdx) produced \(value), outside every input's range")
                }
            }
        }
    }

    /// Follow-up to a second real-run report, after `gpuSlots` fixed the crash:
    /// GPU merge "seemed to take a long time, perhaps longer than the non-GPU
    /// version" on the same 20-frame 42MP sequence at full concurrency. The
    /// test above only exercises `medianMergeImage` — the *un-aligned* merge,
    /// one GPU call per job. Production's real per-frame path
    /// (`ImageAligner.alignAndMedianMerge`, what `FrameAlignmentProcessor`
    /// actually calls) is far busier: `ia_align_and_median_merge`
    /// (ImageAligner.cpp) calls `warpInto` *and* `warpCoverage` (literally the
    /// same function, called twice) per neighbour before the final merge, so
    /// star's default 8 neighbours means 17 separate GPU round-trips per
    /// frame, all funnelled through the same `gpuSlots` this file's other test
    /// found fast for 1-round-trip-per-job. This measures the real shape:
    /// 18 concurrent frames x 17 GPU calls = 306 total round-trips through
    /// `gpuSlots`, at real 42MP scale, GPU against CPU.
    ///
    /// Run with `swift test -c release`: this file's 42MP fixtures are filled
    /// by a plain per-pixel Swift loop, and unoptimized (`-Onone`, `swift
    /// test`'s default) that loop alone measured ~15s for one 42MP frame —
    /// debug-mode Swift, not GPU or CPU merge cost, so a debug run makes
    /// fixture setup look like the bottleneck and takes >20 minutes for no
    /// reason. `_isDebugAssertConfiguration()` skips this rather than
    /// silently eating that time again.
    func testRealisticAlignedMergeThroughputAtConcurrency() throws {
        try XCTSkipIf(_isDebugAssertConfiguration(),
                      "run with 'swift test -c release' -- see doc comment")
        let width = 7016, height = 5988  // ~42MP, matching the reported sequence
        let neighborsPerFrame = 8
        let concurrentFrames = 18
        let neighborPoolSize = 10  // reused across jobs, like real consecutive frames share neighbours
        let scratchDir = scratch!

        let setupStart = Date()
        nonisolated(unsafe) let poolFilenames = UnsafeMutablePointer<String>.allocate(capacity: neighborPoolSize)
        poolFilenames.initialize(repeating: "", count: neighborPoolSize)
        defer { poolFilenames.deinitialize(count: neighborPoolSize); poolFilenames.deallocate() }
        DispatchQueue.concurrentPerform(iterations: neighborPoolSize) { i in
            let mat = Self.makeMat(width: width, height: height, seed: UInt32(i + 1))
            let path = scratchDir.appendingPathComponent("pool-\(i).tiff").path
            XCTAssertTrue(mat.write(to: path))
            poolFilenames[i] = path
        }
        let pool = (0..<neighborPoolSize).map { poolFilenames[$0] }
        let bases = (0..<concurrentFrames).map { Self.makeMat(width: width, height: height, seed: UInt32($0 * 1000)) }
        // Frame-index-relative, not content-relative, so one identity homography
        // dict (offsets 1...neighborsPerFrame) is valid for every job -- each job's
        // base is always "frame 0" and its neighbours "frame 1..neighborsPerFrame".
        let identity = MatWrapper(homographyValues: [1, 0, 0, 0, 1, 0, 0, 0, 1])
        let homography = Dictionary(uniqueKeysWithValues: (1...neighborsPerFrame).map { ($0, identity) })
        print("STRESS setup (writing \(neighborPoolSize) pool fixture files at \(width)x\(height)) took "
              + "\(Date().timeIntervalSince(setupStart))s")

        func runAll(useGPU: Bool, frameCount: Int) -> TimeInterval {
            let expectation = expectation(description: "every aligned merge finishes (useGPU: \(useGPU))")
            expectation.expectedFulfillmentCount = frameCount
            let start = Date()
            for taskIdx in 0..<frameCount {
                let neighbors = (0..<neighborsPerFrame).map { n -> AlignmentNeighborInfo in
                    let poolIdx = (taskIdx + n) % neighborPoolSize
                    return AlignmentNeighborInfo(filename: pool[poolIdx], maskFilename: nil,
                                                 keypoints: nil, frameIndex: Int32(n + 1))
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = ImageAligner.alignAndMedianMerge(
                      baseImage: bases[taskIdx], baseFrameIndex: 0, neighbors: neighbors,
                      homography: homography, outlierThreshold: 3.0, includeAll: true, useGPU: useGPU)
                    XCTAssertNotNil(result, "task \(taskIdx) (useGPU: \(useGPU)) produced no result at all")
                    XCTAssertEqual(result?.warpCount, neighborsPerFrame,
                                   "task \(taskIdx) (useGPU: \(useGPU)) warped fewer neighbours than it was given")
                    expectation.fulfill()
                }
            }
            // Generous for the same reason as the test above: this measures
            // throughput, but still must not hang forever if something is wrong.
            wait(for: [expectation], timeout: 600)
            return Date().timeIntervalSince(start)
        }

        // Isolated (frameCount: 1) first: no `gpuSlots` contention is even
        // possible with a single caller, so this isolates "are 17 small GPU
        // round-trips inherently slower than one CPU call" from "does
        // gpuSlots serialize concurrent callers too tightly." If GPU is
        // already slower than CPU here, gpuSlots is not the (sole) story.
        let gpuSolo = runAll(useGPU: true, frameCount: 1)
        let cpuSolo = runAll(useGPU: false, frameCount: 1)
        print("STRESS aligned-merge SOLO (1 frame, no concurrency): "
              + "GPU \(gpuSolo)s, CPU \(cpuSolo)s, ratio \(gpuSolo / cpuSolo)")

        let gpuSeconds = runAll(useGPU: true, frameCount: concurrentFrames)
        print("STRESS aligned-merge GPU: \(concurrentFrames) frames x \(neighborsPerFrame) neighbours "
              + "finished in \(gpuSeconds)s")
        let cpuSeconds = runAll(useGPU: false, frameCount: concurrentFrames)
        print("STRESS aligned-merge CPU: \(concurrentFrames) frames x \(neighborsPerFrame) neighbours "
              + "finished in \(cpuSeconds)s")
        print("STRESS aligned-merge GPU/CPU ratio: \(gpuSeconds / cpuSeconds) "
              + "(> 1 means GPU was slower, which is the thing being investigated)")
    }

    /// Isolates one round-trip's real, end-to-end wall-clock cost -- allocate,
    /// pack, submit, block on `waitUntilCompleted`, read back -- against
    /// GPU_IMPLEMENTATION_GUIDE.md's own "warp: 0.99ms" figure. Ten
    /// sequential, single-threaded calls (no concurrency, no `gpuSlots`
    /// contention with only one caller, no other work in between) at real
    /// 42MP scale.
    ///
    /// Measured: GPU averaged ~298ms/call, CPU ~118ms/call -- GPU is slower
    /// by 2.5x for one warp, alone, with no contention at all. That rules out
    /// `gpuSlots` and concurrency as the (sole) explanation for the
    /// realistic-throughput test above being slower on GPU: this backend's
    /// per-call round-trip overhead (a fresh `.storageModeShared` buffer
    /// allocation, a new `MTLCommandBuffer`, a synchronous
    /// `waitUntilCompleted`, a `memcpy` back out) is, on its own, larger than
    /// the CPU cost of the same 42MP warp. The guide's 0.99ms almost
    /// certainly measured GPU-side kernel execution alone, not this. That gap
    /// is also the architectural difference from the SIFT/AKAZE pyramid
    /// builders, which stayed fast: those pay this same fixed overhead only
    /// *once* per frame, for a whole chain of dispatches on one command
    /// buffer, where `ia_align_and_median_merge`'s 8-neighbour star merge
    /// pays it 17 times (`warpInto` + `warpCoverage` per neighbour, plus the
    /// final merge).
    ///
    /// Run with `swift test -c release` -- see the doc comment on
    /// `testRealisticAlignedMergeThroughputAtConcurrency` above for why.
    func testSingleWarpRoundTripCostAtRealScale() throws {
        try XCTSkipIf(_isDebugAssertConfiguration(),
                      "run with 'swift test -c release' -- see doc comment")
        let width = 7016, height = 5988
        let src = Self.makeMat(width: width, height: height, seed: 1)
        let identity = MatWrapper(homographyValues: [1, 0, 0, 0, 1, 0, 0, 0, 1])

        func timeCalls(useGPU: Bool, count: Int) -> [TimeInterval] {
            (0..<count).map { _ in
                let start = Date()
                _ = ImageAligner.debugWarp(src, homography: identity, useGPU: useGPU)
                return Date().timeIntervalSince(start)
            }
        }

        let gpuTimes = timeCalls(useGPU: true, count: 10)
        let cpuTimes = timeCalls(useGPU: false, count: 10)
        print("STRESS single warp round-trip, GPU (10 calls): \(gpuTimes)")
        print("STRESS single warp round-trip, CPU (10 calls): \(cpuTimes)")
        print("STRESS single warp round-trip GPU mean: \(gpuTimes.reduce(0, +) / Double(gpuTimes.count))s, "
              + "CPU mean: \(cpuTimes.reduce(0, +) / Double(cpuTimes.count))s")
    }

    /// The numbers `MetalGPUBackend.alignedMerge`'s doc comment quotes: one
    /// realistic aligned merge -- a 7008x4672 16-bit RGB frame (33MP, an a7iv),
    /// 8 neighbours rotated and drifted like a star field so their warps leave
    /// real holes, coverage counted -- timed, with the process's peak memory
    /// sampled while it runs, CPU against GPU, alone and then four at a time.
    /// The frames are served from memory, so decoding them is not part of what
    /// is measured.
    ///
    /// Prints rather than asserting anything about speed: it exists to be re-run
    /// on whatever machine has a question about it. Run with `swift test -c
    /// release`, for the same reason as the tests above.
    func testAlignedMergeTimeAndFootprintAtRealScale() throws {
        try XCTSkipIf(_isDebugAssertConfiguration(),
                      "run with 'swift test -c release' -- see doc comment")
        let width = 7008, height = 4672, channels = 3
        let offsets = [-4, -3, -2, -1, 1, 2, 3, 4]

        func frame(_ seed: UInt32) -> MatWrapper {
            let count = width * height * channels
            let data = UnsafeMutablePointer<UInt16>.allocate(capacity: count)
            defer { data.deallocate() }   // the MatWrapper below copies it
            nonisolated(unsafe) let pixels = data
            DispatchQueue.concurrentPerform(iterations: height) { y in
                var h = UInt32(truncatingIfNeeded: y) &* 2_654_435_761 &+ seed &* 40_503
                let row = pixels.advanced(by: y * width * channels)
                for x in 0..<width {
                    for c in 0..<channels {
                        h ^= h << 13; h ^= h >> 17; h ^= h << 5
                        let sky = 6000 + (x * 7 + y * 5) % 3000 + c * 500
                        row[x * channels + c] = (x * 31 + y * 17) % 997 == 0
                            ? 50000 : UInt16(sky + Int(h % 600))
                    }
                }
            }
            return MatWrapper(width: width, height: height,
                              cvType: MatWrapper.cvType(forBitsPerComponent: 16,
                                                        componentsPerPixel: Int32(channels)),
                              bytesPerRow: width * channels * 2,
                              data: UnsafeMutableRawPointer(data), takeOwnership: true)
        }

        let base = frame(1)
        var pool: [String: MatWrapper] = [:]
        var neighbors: [AlignmentNeighborInfo] = []
        var homography: [Int: MatWrapper] = [:]
        for (i, d) in offsets.enumerated() {
            let name = "memory://neighbour-\(i)"
            pool[name] = frame(UInt32(100 + i))
            neighbors.append(AlignmentNeighborInfo(filename: name, maskFilename: nil, keypoints: nil,
                                                   frameIndex: Int32(d)))
            // ~0.02 degrees of field rotation and ~20px of drift per frame,
            // about what a real 33MP star-field sequence's homographies show.
            let theta = 0.0004 * Double(d), scale = 1.0 + 0.0002 * Double(d)
            let cx = Double(width) / 2, cy = Double(height) / 2
            let a = scale * cos(theta), b = -scale * sin(theta)
            let c = scale * sin(theta), e = scale * cos(theta)
            homography[d] = MatWrapper(homographyValues: [
              a, b, cx - a * cx - b * cy - 20.7 * Double(d),
              c, e, cy - c * cx - e * cy + 3.1 * Double(d),
              0, 0, 1])
        }
        ImageCache.setLoader { pool[$0] }

        func merge(useGPU: Bool) {
            let result = ImageAligner.alignAndMedianMerge(
              baseImage: base, baseFrameIndex: 0, neighbors: neighbors, homography: homography,
              outlierThreshold: 1.2, includeAll: false, useGPU: useGPU)
            XCTAssertEqual(result?.warpCount, offsets.count)
        }

        for useGPU in [false, true] {
            let label = useGPU ? "GPU" : "CPU"
            for rep in 0..<3 {
                let (seconds, peak) = Self.measure { merge(useGPU: useGPU) }
                print(String(format: "STRESS aligned merge %@ alone, run %d: %.3fs, peak footprint +%.0fMB",
                             label, rep, seconds, Double(peak) / 1e6))
            }
            let concurrent = 4, total = 12
            let (seconds, peak) = Self.measure {
                DispatchQueue.concurrentPerform(iterations: concurrent) { worker in
                    for _ in stride(from: worker, to: total, by: concurrent) { merge(useGPU: useGPU) }
                }
            }
            print(String(format: "STRESS aligned merge %@, %d merges %d at a time: %.2fs (%.2fs a merge), "
                         + "peak footprint +%.0fMB",
                         label, total, concurrent, seconds, seconds / Double(total), Double(peak) / 1e6))
        }
    }

    /// Runs `body`, sampling this process's physical footprint every 2ms while it
    /// does, and returns how long it took and how far above its starting
    /// footprint the process peaked.
    private static func measure(_ body: () -> Void) -> (seconds: TimeInterval, peakGrowth: UInt64) {
        final class Sampler: @unchecked Sendable {
            let lock = NSLock()
            var running = true
            var peak: UInt64 = 0
        }
        let sampler = Sampler()
        let before = physFootprint()
        let thread = Thread {
            while sampler.lock.withLock({ sampler.running }) {
                let now = physFootprint()
                sampler.lock.withLock { sampler.peak = max(sampler.peak, now) }
                usleep(2000)
            }
        }
        thread.start()
        let start = Date()
        body()
        let seconds = Date().timeIntervalSince(start)
        sampler.lock.withLock { sampler.running = false }
        while !thread.isFinished { usleep(500) }
        return (seconds, sampler.lock.withLock { sampler.peak } &- before)
    }

    private static func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
