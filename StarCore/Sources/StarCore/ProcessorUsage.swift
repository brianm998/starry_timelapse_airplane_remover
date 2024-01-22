import Foundation
import ShellOut
import logging


/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// overall percentage, not per cpu
public struct ProcessorUsage {
    let user: Double            
    let sys: Double
    let idle: Double
    let date: TimeInterval
    
    public init(user: Double,
                sys: Double,
                idle: Double)
    {
        self.date = NSDate().timeIntervalSince1970

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
            self.date = NSDate().timeIntervalSince1970
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

public actor ProcessorUsageTracker {
    // overal usage percentage, not per cpu, i.e. range of 0...100 percent 
    var usage: ProcessorUsage

    // the last usage that was read from the system, not guessed
    var realUsages: [ProcessorUsage] = []

    // when the last read happened
    let checkIntervalSeconds: TimeInterval = 7.0

    public init () {
        self.usage = ProcessorUsage(user: 100,
                                    sys: 0,
                                    idle: 0)
    }

    private func readUsage() -> Double {
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
                            self.realUsages.append(usage)

                            while realUsages.count > 10 {
                                realUsages.removeFirst(1)
                            }

                            Log.d("CPU usage: \(usage)")
                        }
                    }
                }
            }
        } catch {
            Log.e("error \(error)")
        }
        return usage.idlePercent
    }

    private var averageIdle: Double {
        // assume not idle at start to force loading some real cpu usage info
        var ret: Double = 0     
        for usage in realUsages {
            ret += usage.idle
        }
        ret /= Double(realUsages.count)
        return ret
    }

    // called to indicate that a new cpu intensive process may have started
    public func processRunning() {
        if averageIdle < 50 {
            // only care if the average idle is less than 50%
            // fast batches of large sizes will be missed,
            // but restarts are fast, so it's worth it.
            // need to make sure batches have small sleeps between frames
            self.usage = self.usage.withAdditional(cpus: 2)
            Log.d("processRunning has usage \(usage)")
        }
    }

    public func percentIdle() -> Double {
        //if true { return readUsage() }
        let now = NSDate().timeIntervalSince1970


            // first check out list of stored real usages
        if realUsages.count > 0,
           let last = realUsages.last
        {
            if now - last.date < checkIntervalSeconds {
                // we have a recent processor usage check, maybe use it

                if now - last.date < 2 { return usage.idlePercent }
                
                if realUsages.count == 1 {
                    // we have just one previous stored value
                    if realUsages[0].isDifferent(from: self.usage) {
                        let ret = readUsage()
                        //Log.d("ret \(ret)")
                        return ret
                    } else {
                        let ret = usage.idlePercent
                        //Log.d("ret usage \(ret)")
                        return ret
                    }
                } else {
                    // we have more than one old real usage

                    if last.date - realUsages[0].date > checkIntervalSeconds,
                       usage.idlePercent < 10
                    {
                        // always re-read
                        let ret = readUsage()
                        //Log.d("ret \(ret)")
                        return ret
                    } else {
                        // here we have a bunch of repeated checks close together
                        // just use one of them if they're close to the same
                        // this can happen when we're starting a lot of tasks
                        // that don't use much CPU
                        let first = realUsages[0]
                        var allAreSame = true
                        for other in realUsages.dropFirst() {
                            if other.isDifferent(from: first, by: 20) {
                                allAreSame = false
                                break
                            }
                        }
                        if allAreSame,
                           now - last.date < 1
                        {
                            // XXX sometimes this goes bad
                            let ret = usage.idlePercent
                            //Log.d("ret usage \(ret)")
                            return ret
                        } else {
                            let ret = readUsage()
                            //Log.d("ret \(ret)")
                            return ret
                        }
                    }
                }
            } else {
                // over the check interval, read real usage
                let ret = readUsage()
                //Log.d("ret \(ret)")
                return ret
            }
        } else {
            // we have no real old usages
            // always re-read
            let ret = readUsage()
            //Log.d("ret \(ret)")
            return ret
        }
    }

    public func isIdle(byAtLeast idleAmountPercent: Double = 20) -> Bool {
        if self.percentIdle() < idleAmountPercent { return false }
        return true
    }
}
