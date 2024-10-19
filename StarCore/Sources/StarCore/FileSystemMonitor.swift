import Foundation
import logging

// limit file load and save actions to a limited number of executors
// so that we don't try to load or save too many files at once,
// which can result in timeout errors.

public let fileSystemMonitor = FileSystemMonitor(maxActors: 30)

public actor FileSystemMonitor {
    fileprivate let fileSystemActors: [FileSystemActor]

    var currentIndex = 0
    
    init(maxActors: Int) {
        var actors: [FileSystemActor] = []
        for _ in 0...maxActors {
            actors.append(FileSystemActor())
        }
        fileSystemActors = actors
    }

    public func load<T>(_ closure: @Sendable @escaping () async throws -> T) async throws -> T where T: Sendable {
        let index = getIndex()
        return try await fileSystemActors[index].load(closure)
    }

    public func save(_ closure: @Sendable @escaping () async throws -> Void) async throws {
        let index = getIndex()
        try await fileSystemActors[index].save(closure)
    }

    fileprivate func getIndex() -> Int {
        let index = currentIndex
        currentIndex += 1
        if currentIndex >= fileSystemActors.count { currentIndex = 0 }
        return index
    }
}

// the individual actors that actually load or save files
fileprivate actor FileSystemActor {
    public func load<T>(_ closure: () async throws -> T) async throws -> T where T: Sendable {
        try await closure()
    }

    public func save(_ closure: () async throws -> Void) async throws {
        try await closure()
    }
}
