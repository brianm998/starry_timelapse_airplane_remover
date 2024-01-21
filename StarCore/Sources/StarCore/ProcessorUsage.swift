import Foundation
import ShellOut
import logging


/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/


/*
 XXX this class needs to keep two historgrams of cpu activity over time.
     one is the real usage coming from reading ps, the other is our bogus
     guesses on reset to avoid calling ps every 200 ms.
 
 XXX also needs to keep track of system usage, as we can crash if system
 usage is high but there is still idle cpu


 run

 top -R -F -n 0 -l 2 -s 0

 read the second one:

 Processes: 984 total, 2 running, 982 sleeping, 4432 threads 
2024/01/21 07:53:54
Load Avg: 5.84, 6.34, 4.56 
CPU usage: 0.98% user, 3.70% sys, 95.30% idle 
MemRegions: 439065 total, 31G resident, 0B private, 12G shared.
PhysMem: 97G used (8025M wired, 1001M compressor), 31G unused.
VM: 49T vsize, 0B framework vsize, 0(0) swapins, 0(0) swapouts.
Networks: packets: 54438748/65G in, 4907575/355G out.
Disks: 34553173/683G read, 5761387/113G written.


 
 */

// overall percentage, not per cpu
public struct ProcessorUsage {
    let user: Double            
    let sys: Double
    let idle: Double

    public init(user: Double,
                sys: Double,
                idle: Double)
    {
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
    
    init?(from line: String) {
        // CPU usage: 3.44% user, 3.81% sys, 92.74% idle
        let parts = line.components(separatedBy: ":")
        let foobar = parts[1].components(separatedBy: ",")
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

    // artifically add some user
    func withAdditional(cpus: Int) -> ProcessorUsage {
        let numProcessors = Double(ProcessInfo.processInfo.activeProcessorCount)
        let percentage = (Double(cpus)/numProcessors)*100
        return ProcessorUsage(user: self.user+percentage,
                              sys: self.sys,
                              idle: self.idle-percentage)
        
    }
}

public actor ProcessorUsageTracker {
    // percent usage per cpu, i.e. two cpus, 200.0 usage
    var usage: ProcessorUsage
    var lastRealUsage: ProcessorUsage?
    var lastReadTime: TimeInterval?

    let checkIntervalSeconds: TimeInterval = 7.0

    public init () {
        self.usage = ProcessorUsage(user: 100,
                                    sys: 0,
                                    idle: 0)
    }

    private func readUsage() {
        do {
            let usageString = try shellOut(to: "top -R -F -n 0 -l 2 -s 0")

            let lines = usageString.split(whereSeparator: \.isNewline)

            var isFirst = true
            
            for line in lines {
                if line.starts(with: "CPU usage:") {
                    if isFirst {
                        // ignore the first reading 
                        isFirst = false
                    } else {
                        if let usage = ProcessorUsage(from: String(line)) {
                            self.usage = usage
                            self.lastRealUsage = usage
                            Log.d("read usage \(usage)")
                            lastReadTime = NSDate().timeIntervalSince1970
                        }
                    }
                }
            }
        } catch {
            Log.e("error \(error)")
        }
    }

    // called to indicate that a new cpu intensive process may have started
    public func processRunning() {
        let idle = idlePercent()
        if idle > 20 {
            self.usage = self.usage.withAdditional(cpus: 4)
            Log.d("reset to usage \(usage)")
        } else {
            Log.d("reset to nil")
            lastReadTime = nil
        }
    }

    public func idlePercent() -> Double {
        if usage.sys > 20 {
            // here we guard against an observed case where the kernel is thrashing
            // in this case the system can report idle cpus, even though
            // those cores cannot accept new processes due to busy kernel.
            // adding new tasks in this case is a bad idea, as it increases thrash :(
            return 0
        } else {
            return usage.idle
        }
    }
    
    public func percentIdle() -> Double {
        if let lastReadTime = lastReadTime,
           NSDate().timeIntervalSince1970 - lastReadTime < checkIntervalSeconds
        {
            // we have a recent processor usage check, maybe use it

            if let lastRealUsage = lastRealUsage,
               lastRealUsage.isDifferent(from: self.usage)
            {
                readUsage()
                return idlePercent()
            } else {
                // use cached values because our guesses hasn't changed much
                return idlePercent()
            }
        } else {
            readUsage()
            return idlePercent()
        }
    }

    public func isIdle(byAtLeast idleAmountPercent: Double = 20) -> Bool {
        if self.percentIdle() < idleAmountPercent { return false }
        return true
    }
}
