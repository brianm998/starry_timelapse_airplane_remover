import XCTest
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
                                                           useGPU: true)
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
}
