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
public actor ProcessorUsageTrackerV2 {
    // overal usage percentage, not per cpu, i.e. range of 0...100 percent 
    var usage: ProcessorUsage

    // the last usage that was read from the system, not guessed
    var realUsages: [ProcessorUsage] = []

    var averageIdle: Double = 0.0
    
    let maxUsages = 100
    
    var processorFinder: ProcessorUsageFinder?

    public init () {
        self.usage = ProcessorUsage(user: 100, // assume the cpu is slammed at start
                                    sys: 0,
                                    idle: 0)
        
        self.processorFinder = ProcessorUsageFinder(interval: 5)

        self.processorFinder?.tracker = self
    }

    public func percentIdle() -> Double { usage.idlePercent }
    
    public func update(with usage: ProcessorUsage) {
        realUsages.append(usage)
        if realUsages.count > maxUsages {
            realUsages = Array(realUsages.dropFirst())
        }
        self.averageIdle = computeAverageIdle()
        self.usage = usage
    }

    private func computeAverageIdle() -> Double {
        // assume not idle at start to force loading some real cpu usage info
        var ret: Double = 0     
        for usage in realUsages {
            ret += usage.idlePercent
        }
        ret /= Double(realUsages.count)
        return ret
    }

    // called to indicate that a new cpu intensive process may have started
    public func processRunning() {
        if averageIdle < 33 {
            self.usage = self.usage.withAdditional(cpus: 4)
        } else if averageIdle < 50 {
            self.usage = self.usage.withAdditional(cpus: 2)
            // only care if the average idle is less than 50%
            // fast batches of large sizes will be missed,
            // but restarts are fast, so it's worth it.
            // need to make sure batches have small sleeps between frames
            Log.d("processRunning has usage \(usage)")
        } else if averageIdle < 66 {
            self.usage = self.usage.withAdditional(cpus: 0.5)
        } else {
//            self.usage = self.usage.withAdditional(cpus: 0.5)
        }

    }

    public func isIdle(byAtLeast idleAmountPercent: Double = 20) -> Bool {
        if usage.idlePercent < idleAmountPercent { return false }
        return true
    }
}
