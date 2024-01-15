import Foundation
import ShellOut
import logging


/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

public actor ProcessorUsage {
    public init () {
        self.usage = numProcessors*100
    }

    // percent usage per cpu, i.e. two cpus, 200.0 usage
    var usage: Double
    var lastReadTime: TimeInterval?

    let checkIntervalSeconds: TimeInterval = 15.0

    let numProcessors = Double(ProcessInfo.processInfo.activeProcessorCount)
    
    private func readUsage() {
        do {
            let usageString = try shellOut(to: "ps -e -o %cpu | awk '{s+=$1} END {print s}'")
            if let cpuUsage = Double(usageString) {
                Log.d("read cpuUsage \(cpuUsage)")
                usage = cpuUsage
                lastReadTime = NSDate().timeIntervalSince1970
            }
        } catch {
            Log.e("error \(error)")
        }
    }

    // called to indicate that a new cpu intensive process may have started
    public func reset() {
        if idlePercent() > 20 {
            usage += 100
            Log.d("reset to usage \(usage)")
        } else {
            Log.d("reset to nil")
            lastReadTime = nil
        }
    }

    public func idlePercent() -> Double {
        (numProcessors*100 - usage) / numProcessors
    }
    
    public func percentIdle() -> Double {
        if let lastReadTime = lastReadTime,
           NSDate().timeIntervalSince1970 - lastReadTime < checkIntervalSeconds
        {
            return idlePercent()
        }
        readUsage()
        return idlePercent()
    }

    public func isIdle(byAtLeast idleAmountPercent: Double) -> Bool {
        if self.percentIdle() < idleAmountPercent { return false }
        return true
    }
}
