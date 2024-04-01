import Foundation
import ShellOut
import logging
import KHTSwift
import kht_bridge

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/


/*
 An Actor that knows how idle the cpu(s) on this machine are.
 */
public actor ProcessorUsageReporter {
    // overal usage percentage, not per cpu, i.e. range of 0...100 percent 
    var usage: ProcessorUsage

    // the last usage that was read from the system, not guessed
    var realUsages: [ProcessorUsage] = []

    // how often we check processor usage
    let checkIntervalSeconds: TimeInterval = 7.0

    public init () {
        self.usage = ProcessorUsage(user: 100, // assume the cpu is slammed at start
                                    sys: 0,
                                    idle: 0)
    }

    private func readUsage() -> Double {
        do {
            try ObjC.catchException {
                // Failed to set posix_spawn_file_actions for fd -1 at index 0 with errno 9
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

    // complicated logic to determine how idle the system is,
    // without checking constantly, which degrades performance.
    public func percentIdle() -> Double {
        let now = NSDate().timeIntervalSince1970

        // first check out list of stored real usages
        if realUsages.count > 0,
           let last = realUsages.last // last is most recent
        {
            if now - last.date < checkIntervalSeconds {
                // we have a recent processor usage check, maybe use it

                // 2 second grace period, return cached usage
                if now - last.date < 2 { return usage.idlePercent }

                // compare against previous cached values
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
                        // always re-read, CPU is barely idle, and our saved
                        // cpu usage spans a long enough time window
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
