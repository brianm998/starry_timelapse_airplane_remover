/*
 TestDataLoader.swift — Load horizon test data from disk.

 Directory structure:
   horizon_test_data/
     stationary/
       sequence1/
         horizon.tiff         ← single mask for all images
         image1.tiff
         imageN.tiff
       sequence2/ ...
     moving/
       sequence1/
         original/
           image1.tiff
           image2.tiff
         horizon/
           image1.tiff        ← matching mask per frame
       sequence2/ ...
*/

import Foundation
import StarCore
import KHTSwift

// MARK: - Data model

/// A single test case: one image paired with its reference horizon mask.
struct TestSample: Sendable {
    let imagePath: String
    let maskPath: String
    let sequenceName: String
    let isStationary: Bool

    /// Cached image dimensions (lazy-loaded)
    var description: String {
        let base = (imagePath as NSString).lastPathComponent
        return "\(sequenceName)/\(base)"
    }
}

/// All loaded test data, split into train/test/validation.
struct TestDataSplit: Sendable {
    let train: [TestSample]
    let test: [TestSample]
    let validation: [TestSample]
    let allSamples: [TestSample]

    var summary: String {
        """
        Test data: \(allSamples.count) total samples
          Train:      \(train.count)
          Test:       \(test.count)
          Validation: \(validation.count)
          Stationary: \(allSamples.filter(\.isStationary).count)
          Moving:     \(allSamples.filter { !$0.isStationary }.count)
        """
    }
}

// MARK: - Loader

enum TestDataLoader {

    static let imageExtensions: Set<String> = ["tiff", "tif", "png", "jpg", "jpeg", "bmp"]

    /// Load all test data from a root directory and split it.
    static func load(
        from rootDir: String,
        trainFraction: Double = 0.7,
        testFraction: Double = 0.2,
        validationFraction: Double = 0.1,
        seed: UInt64 = 42
    ) throws -> TestDataSplit {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: rootDir, isDirectory: &isDir), isDir.boolValue else {
            throw "Test data directory does not exist: \(rootDir)"
        }

        var allSamples: [TestSample] = []

        // Load stationary sequences
        let stationaryDir = (rootDir as NSString).appendingPathComponent("stationary")
        if fm.fileExists(atPath: stationaryDir, isDirectory: &isDir), isDir.boolValue {
            let sequences = try fm.contentsOfDirectory(atPath: stationaryDir)
                .sorted()
            for seq in sequences {
                let seqDir = (stationaryDir as NSString).appendingPathComponent(seq)
                guard fm.fileExists(atPath: seqDir, isDirectory: &isDir), isDir.boolValue else { continue }
                let samples = try loadStationarySequence(dir: seqDir, name: seq)
                allSamples.append(contentsOf: samples)
            }
        }

        // Load moving sequences
        let movingDir = (rootDir as NSString).appendingPathComponent("moving")
        if fm.fileExists(atPath: movingDir, isDirectory: &isDir), isDir.boolValue {
            let sequences = try fm.contentsOfDirectory(atPath: movingDir)
                .sorted()
            for seq in sequences {
                let seqDir = (movingDir as NSString).appendingPathComponent(seq)
                guard fm.fileExists(atPath: seqDir, isDirectory: &isDir), isDir.boolValue else { continue }
                let samples = try loadMovingSequence(dir: seqDir, name: seq)
                allSamples.append(contentsOf: samples)
            }
        }

        guard !allSamples.isEmpty else {
            throw "No test samples found in \(rootDir)"
        }

        // Deterministic shuffle and split
        var rng = SplitMix64(seed: seed)
        var shuffled = allSamples
        for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            shuffled.swapAt(i, j)
        }

        let trainEnd = Int(Double(shuffled.count) * trainFraction)
        let testEnd = trainEnd + Int(Double(shuffled.count) * testFraction)

        let train = Array(shuffled[0..<trainEnd])
        let test = Array(shuffled[trainEnd..<min(testEnd, shuffled.count)])
        let validation = Array(shuffled[min(testEnd, shuffled.count)...])

        return TestDataSplit(
            train: train,
            test: test,
            validation: validation,
            allSamples: allSamples
        )
    }

    /// Load a stationary sequence: one horizon.tiff + N images.
    private static func loadStationarySequence(dir: String, name: String) throws -> [TestSample] {
        let fm = FileManager.default

        // Find horizon mask — look for horizon.tiff, horizon.png, etc.
        let files = try fm.contentsOfDirectory(atPath: dir).sorted()
        guard let horizonFile = files.first(where: { f in
            let base = (f as NSString).deletingPathExtension.lowercased()
            let ext = (f as NSString).pathExtension.lowercased()
            return base == "horizon" && imageExtensions.contains(ext)
        }) else {
            throw "No horizon mask found in stationary sequence: \(dir)"
        }

        let horizonPath = (dir as NSString).appendingPathComponent(horizonFile)

        // All other image files are test images
        var samples: [TestSample] = []
        for file in files {
            let base = (file as NSString).deletingPathExtension.lowercased()
            let ext = (file as NSString).pathExtension.lowercased()
            guard base != "horizon", imageExtensions.contains(ext) else { continue }

            let imagePath = (dir as NSString).appendingPathComponent(file)
            samples.append(TestSample(
                imagePath: imagePath,
                maskPath: horizonPath,
                sequenceName: "stationary/\(name)",
                isStationary: true
            ))
        }
        return samples
    }

    /// Load a moving sequence: original/ and horizon/ subdirectories with matching filenames.
    private static func loadMovingSequence(dir: String, name: String) throws -> [TestSample] {
        let fm = FileManager.default
        let originalDir = (dir as NSString).appendingPathComponent("original")
        let horizonDir = (dir as NSString).appendingPathComponent("horizon")

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: originalDir, isDirectory: &isDir), isDir.boolValue else {
            throw "Missing original/ directory in moving sequence: \(dir)"
        }
        guard fm.fileExists(atPath: horizonDir, isDirectory: &isDir), isDir.boolValue else {
            throw "Missing horizon/ directory in moving sequence: \(dir)"
        }

        let origFiles = try fm.contentsOfDirectory(atPath: originalDir)
            .filter { imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()

        var samples: [TestSample] = []
        for file in origFiles {
            let maskPath = (horizonDir as NSString).appendingPathComponent(file)
            guard fm.fileExists(atPath: maskPath) else {
                // Try with different extensions
                let base = (file as NSString).deletingPathExtension
                var found = false
                for ext in imageExtensions {
                    let altPath = (horizonDir as NSString).appendingPathComponent("\(base).\(ext)")
                    if fm.fileExists(atPath: altPath) {
                        samples.append(TestSample(
                            imagePath: (originalDir as NSString).appendingPathComponent(file),
                            maskPath: altPath,
                            sequenceName: "moving/\(name)",
                            isStationary: false
                        ))
                        found = true
                        break
                    }
                }
                if !found {
                    print("  Warning: no horizon mask for \(file) in \(name), skipping")
                }
                continue
            }

            samples.append(TestSample(
                imagePath: (originalDir as NSString).appendingPathComponent(file),
                maskPath: maskPath,
                sequenceName: "moving/\(name)",
                isStationary: false
            ))
        }
        return samples
    }
}

// MARK: - Simple deterministic RNG

struct SplitMix64: Sendable {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
