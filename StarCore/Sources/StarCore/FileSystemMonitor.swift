import Foundation
import logging
import Semaphore

// limit file load and save actions to a limited number of executors
// so that we don't try to load or save too many files at once,
// which can result in timeout errors.

// XXX make this max a parameter
public let fileSystemMonitor = FileSystemMonitor(max: 10)
public let finalFileSystemMonitor = FileSystemMonitor(max: 20)

public actor FileSystemMonitor {

    private let loadSemaphore: AsyncSemaphore
    private let saveSemaphore: AsyncSemaphore
    
    init(max: Int) {
        self.loadSemaphore = AsyncSemaphore(value: max)
        self.saveSemaphore = AsyncSemaphore(value: max)
    }

    public func save(_ closure: @Sendable () async throws -> Void) async throws {
        await saveSemaphore.wait()
        defer { saveSemaphore.signal() }
        try await closure() 
    }
    
    public func load<T>(_ closure: @Sendable () async throws -> T) async throws -> T where T: Sendable {
        await loadSemaphore.wait()
        defer { loadSemaphore.signal() }
        return try await closure()
    }
}
