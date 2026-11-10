import Foundation

/// The errors a frame graph's operations report, for the run's completion to hand on.
///
/// `append` is synchronous: an error closure that appends before it returns has the
/// error in the log before the operation finishes, so a completion operation that
/// depends on it can never read the log first.  (An actor appended to from an
/// unstructured `Task` has no such ordering.)
public final class FrameErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [String] = []

    public init() { }

    public func append(_ error: String) {
        lock.lock()
        defer { lock.unlock() }
        errors.append(error)
    }

    public func elements() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return errors
    }
}
