import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// Says, in the log, when a run has gone quiet and why that can be told.
///
/// A run on 2026-10-28 logged nothing for 2 minutes 27 seconds: the governor's own line read
/// CPU 0%, GPU 0%, 0 MB/s, the disk gate full with 41 waiting, and then frames trickled back one
/// at a time.  Nothing in the log could say whether star had stopped itself or been stopped.
/// Those are different bugs, and the two signals that tell them apart are cheap to keep.
///
///  * **The process was not running.**  The governor samples every 5 seconds from inside the
///    process.  A sample that arrives far later than that, over a window in which star used
///    little CPU, is a process that was not scheduled: `SIGSTOP` from outside (a debugger,
///    a job-control stop, a tool run against it), a sleeping machine, or every thread stuck in
///    the kernel (a volume that stopped answering).  The governor cannot watch it happen — it
///    is stopped too — but it is the first thing to run afterwards, and it can say how long
///    the gap was.  "Little" is a tenth of the machine, not none: a window that is mostly the
///    gap still averages the work done before and after it, and a run on 2026-10-30 that went
///    silent for 3m29s after half a minute of work averaged 2%, which a threshold of 1% let
///    through.
///  * **The governor was starved.**  The same late sample over a window the CPU was busy in is
///    a process that ran, whose timer did not get a thread: the Swift pool held by blocking
///    calls.  Quieter, but a timer that is 20 seconds late is worth one line.
///  * **The run is wedged.**  Gates are holding work — a CPU slot running, a disk stream in
///    flight or waiting, callers queued for the GPU or for memory — and for a minute nothing
///    has used CPU, GPU or disk or finished an operation.  A wait that never ends (a lock
///    held across an `await`, a dependency that never arrives) looks exactly like this, and
///    so does a process that is being stopped over and over a few seconds at a time.
///
/// Both are reported once, with the resource line that was current, and a wedge again every
/// five minutes it lasts, so a log of a stuck run has a line for every stretch of it and is
/// not filled by the same line twelve times an hour.
struct StallWatch: Sendable, Equatable {

    enum Finding: Sendable, Equatable {
        /// The sample covered `seconds` of wall clock in which the process used little CPU.
        case processNotRunning(seconds: Double, cpuPercent: Double)
        /// The sample came `seconds` after the last while the CPU was busy.
        case governorLate(seconds: Double, cpuPercent: Double)
        /// Work has been held, with nothing using any resource, for `seconds`.
        case noProgress(seconds: Double)
    }

    /// A sample this much later than it was due (the governor runs every 5 seconds).
    static let lateSampleSeconds = 20.0
    /// Over such a window, less than this is a process that was mostly not running; more is one
    /// that was, whose governor was slow to get a thread.
    static let pausedCPUPercent = 10.0
    /// Over an ordinary window, less than this is idle (for the wedge count).
    static let idleCPUPercent = 1.0
    static let wedgedAfterSeconds = 60.0
    static let repeatEverySeconds = 300.0

    private var quietSeconds = 0.0
    private var lastReportedQuiet: Double?

    /// What this sample says.  Call it once per sample, in order.
    mutating func observe(_ sample: ResourceSample) -> [Finding] {
        let window = sample.windowSeconds

        // A window this long is a sample that did not run on time.  With little CPU in it that is
        // the process having been away, not the run having nothing to do; with a lot, a timer
        // that starved.  Either way it does not count toward a wedge.
        if window >= Self.lateSampleSeconds {
            quietSeconds = 0
            lastReportedQuiet = nil
            return sample.cpuPercent < Self.pausedCPUPercent
                ? [.processNotRunning(seconds: window, cpuPercent: sample.cpuPercent)]
                : [.governorLate(seconds: window, cpuPercent: sample.cpuPercent)]
        }

        guard Self.holdsWorkWithoutUsingAnything(sample) else {
            quietSeconds = 0
            lastReportedQuiet = nil
            return []
        }
        quietSeconds += window
        guard quietSeconds >= Self.wedgedAfterSeconds else { return [] }
        if let last = lastReportedQuiet, quietSeconds - last < Self.repeatEverySeconds { return [] }
        lastReportedQuiet = quietSeconds
        return [.noProgress(seconds: quietSeconds)]
    }

    static func holdsWorkWithoutUsingAnything(_ sample: ResourceSample) -> Bool {
        let holdsWork = sample.cpuRunning > 0
            || sample.gpuWaiting > 0
            || sample.memoryWaiting > 0
            || sample.volumes.contains { $0.inFlight > 0 || $0.waiting > 0 }
        guard holdsWork else { return false }
        return sample.cpuPercent < Self.idleCPUPercent
            && sample.gpuPercent < Self.idleCPUPercent
            && sample.throughputPerMinute == 0
            && sample.volumes.allSatisfy { $0.bytesPerSecond == 0 }
    }

    /// The line for the log: what was seen, then the resource line it was seen in, then the
    /// process's own state as the kernel reports it.
    static func message(for finding: Finding, report: ResourceReport) -> String {
        let seen: String
        switch finding {
        case .processNotRunning(let seconds, let cpuPercent):
            seen = String(format: "stall watch: the governor's sample came %.0fs after the last "
                          + "(it runs every 5s) with the CPU %.1f%% busy over that time — star was "
                          + "not running for most of it (stopped by a signal or a debugger, the "
                          + "machine slept, or every thread was stuck in the kernel, e.g. on a "
                          + "volume that stopped answering)", seconds, cpuPercent)
        case .governorLate(let seconds, let cpuPercent):
            seen = String(format: "stall watch: the governor's sample came %.0fs after the last "
                          + "(it runs every 5s) with the CPU %.1f%% busy over that time — star was "
                          + "running, but nothing gave this timer a thread for that long (the "
                          + "Swift pool held by blocking calls)", seconds, cpuPercent)
        case .noProgress(let seconds):
            seen = String(format: "stall watch: %.0fs with work held at a gate and no CPU, GPU "
                          + "or disk in use and no operation finished", seconds)
        }
        return seen + "; " + report.line + "; process state: " + ProcessState.describe()
    }
}

/// The kernel's account of this process: running, sleeping, or stopped.
enum ProcessState {
    static func describe() -> String {
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        // <sys/proc.h>: SIDL 1, SRUN 2, SSLEEP 3, SSTOP 4, SZOMB 5
        switch Int(info.kp_proc.p_stat) {
        case 1: return "being created"
        case 2: return "runnable"
        case 3: return "sleeping"
        case 4: return "stopped"
        case 5: return "zombie"
        case let other: return "state \(other)"
        }
        #elseif canImport(Glibc)
        // /proc/self/stat is "pid (comm) S ...": the state follows the last closing parenthesis.
        guard let text = try? String(contentsOfFile: "/proc/self/stat", encoding: .utf8),
              let close = text.lastIndex(of: ")")
        else { return "unknown" }
        let state = text[text.index(after: close)...].drop { $0 == " " }.first
        switch state {
        case "R": return "running"
        case "S", "D": return "sleeping"
        case "T", "t": return "stopped"
        case "Z": return "zombie"
        case let other?: return "state \(other)"
        case nil: return "unknown"
        }
        #else
        return "unknown"
        #endif
    }
}
