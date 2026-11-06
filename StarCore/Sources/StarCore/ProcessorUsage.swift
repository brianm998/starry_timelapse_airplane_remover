import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// overall percentage, not per cpu
public struct ProcessorUsage {
    let user: Double        // 0..100 percentage of user process cpu usage
    let sys: Double         // 0..100 percentage of system cpu usage
    let idle: Double        // 0..100 percentage of cpu time spent idle
    let date: TimeInterval  // observation time

    private let numProcessors = Double(ProcessInfo.processInfo.activeProcessorCount)
    
    public init(user: Double,
                sys: Double,
                idle: Double)
    {
        self.date = Date().timeIntervalSince1970

        // keep values in the range of 0...100
        
        if user < 0 {
            self.user = 0
        } else if user > 100 {
            self.user = 100
        } else {
            self.user = user
        }

        if sys < 0 {
            self.sys = 0
        } else if sys > 100 {
            self.sys = 100
        } else {
            self.sys = sys
        }

        if idle < 0 {
            self.idle = 0
        } else if idle > 100 {
            self.idle = 100
        } else {
            self.idle = idle
        }
    }
    
    public static func busy() -> ProcessorUsage { // all busy
        ProcessorUsage(user: 100, sys: 0, idle: 0)
    }
    
    init?(from line: String) {
        // CPU usage: 3.44% user, 3.81% sys, 92.74% idle

        // a regex would be cleaner,
        // but swift regexes are a breaking change,
        // which right now is a PITA.

        // Check the shape before indexing into it.  This is a failable initializer and it
        // already returns nil when the three numbers do not parse, but it used to subscript
        // parts[1], foobar[1] and foobar[2] unguarded — so a line with no colon, or with fewer
        // than three comma separated fields after it, trapped instead of returning nil.
        //
        // The caller only feeds it lines starting "CPU usage:", which guarantees the colon and
        // in practice supplies all three fields, so this was unreachable as long as top's output
        // keeps its present shape.  It is worth fixing anyway: a trap here cannot be recovered
        // from, and the ObjC.catchException around the caller does not catch Swift traps, so a
        // change to top's format on some future macOS would take star down rather than leave it
        // reusing the previous sample.
        let parts = line.components(separatedBy: ":")
        guard parts.count >= 2 else { return nil }

        let foobar = parts[1].components(separatedBy: ",")
        guard foobar.count >= 3 else { return nil }

        let user = foobar[0].components(separatedBy: "%")
        let sys = foobar[1].components(separatedBy: "%")
        let idle = foobar[2].components(separatedBy: "%")

        if let user = Double(user[0].dropFirst()),
           let sys = Double(sys[0].dropFirst()),
           let idle = Double(idle[0].dropFirst())
        {
            self.user = user
            self.sys = sys
            self.idle = idle
            self.date = Date().timeIntervalSince1970
        } else {
            return nil
        }
    }

    func isDifferent(from other: ProcessorUsage,
                     by percentageDiff: Double = 50) -> Bool
    {
        let user_diff = abs(self.user - other.user)
        let sys_diff = abs(self.sys - other.sys)
        let idle_diff = abs(self.idle - other.idle)

        return user_diff > percentageDiff ||
          sys_diff > percentageDiff ||
          idle_diff > percentageDiff
    }

    // artifically boost cpu usage by some number of cpus
    func withAdditional(cpus: Double) -> ProcessorUsage {
        let percentage = (cpus/numProcessors)*100
        return ProcessorUsage(user: self.user+percentage,
                              sys: self.sys,
                              idle: self.idle-percentage)
    }
    
    public var idlePercent: Double {
        if self.sys > 20 {
            // here we guard against an observed case where the kernel is thrashing
            // in this case the system can report idle cpus, even though
            // those cores cannot accept new processes due to busy kernel.
            // adding new tasks in this case is a bad idea, as it increases thrash :(
            return 0
        } else {
            return self.idle
        }
    }
}



/// The cumulative cpu tick counters of the whole machine, as the kernel keeps them.  The counters are 32 bit and wrap, so only the
/// difference between two readings means anything (`ProcessorUsage.from(ticks:previous:)`).
struct ProcessorTicks: Equatable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

extension ProcessorUsage {
    /// The usage over the time between two tick readings, or nil when no ticks passed between them (no basis for a percentage).
    ///
    /// What `top` reported as "CPU usage", read from the kernel instead: `top` is a child process, which a sandboxed app may not run.
    /// Nice time counts as user time, as it does in `top`.
    static func from(ticks: ProcessorTicks, previous: ProcessorTicks) -> ProcessorUsage? {
        // wrapping subtraction: a counter that rolled over between the readings still gives the right difference
        let user = Double(ticks.user &- previous.user) + Double(ticks.nice &- previous.nice)
        let sys = Double(ticks.system &- previous.system)
        let idle = Double(ticks.idle &- previous.idle)
        let total = user + sys + idle
        guard total > 0 else { return nil }
        return ProcessorUsage(user: user / total * 100, sys: sys / total * 100, idle: idle / total * 100)
    }
}

#if os(macOS)
import Darwin

/// `host_statistics(HOST_CPU_LOAD_INFO)`: the tick counters, with no child process and nothing a sandbox forbids.
enum HostProcessorTicks {
    static func read() -> ProcessorTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // the tuple is indexed by CPU_STATE_USER, _SYSTEM, _IDLE, _NICE
        return ProcessorTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }
}

/// Reads the machine's usage from `HostProcessorTicks`, one reading at a time.  A reading is the usage since the one before, so the
/// first has nothing to compare with: it waits a moment and reads again, rather than report the cpu as idle (or busy) on no evidence.
struct ProcessorTickSampler {
    private var last: (ticks: ProcessorTicks, at: Date)?

    /// A previous reading older than this says nothing about now.
    static let freshSeconds: TimeInterval = 30
    static let firstWindowSeconds: TimeInterval = 0.2

    mutating func sample() -> ProcessorUsage? {
        guard let first = HostProcessorTicks.read() else { return nil }
        let firstAt = Date()
        let baseline: ProcessorTicks
        let current: ProcessorTicks
        if let last, firstAt.timeIntervalSince(last.at) < Self.freshSeconds {
            baseline = last.ticks
            current = first
        } else {
            Thread.sleep(forTimeInterval: Self.firstWindowSeconds)
            guard let second = HostProcessorTicks.read() else { return nil }
            baseline = first
            current = second
        }
        last = (current, Date())
        return ProcessorUsage.from(ticks: current, previous: baseline)
    }
}
#endif
