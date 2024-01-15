import Foundation
import ShellOut
import logging


/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/



//Garth:cli brian$ top -l  2 | grep -E "^CPU" | tail -1
//CPU usage: 76.15% user, 7.1% sys, 16.82% idle 


public struct ProcesserUsageInfo {
    let user: Double
    let sys: Double
    let idle: Double
}

public actor ProcessorUsage {
    public init () { }

    let regex = /\s*CPU usage: ([\d.]+)% user, ([\d.]+)% sys, ([\d.]+)% idle\s*/

    var usage: ProcesserUsageInfo?
    var lastReadTime: TimeInterval?

    let checkIntervalSeconds: TimeInterval = 10.0

    let numProcessors = Double(ProcessInfo.processInfo.activeProcessorCount)
    
    private func readUsage() {
        do {
            let topOutput = try shellOut(to: "top -l  2 | grep -E \"^CPU\" | tail -1")
            if let result = try regex.wholeMatch(in: topOutput),
               let user = Double(result.1),
               let sys = Double(result.2),
               let idle = Double(result.3)
            {
                Log.d("idle \(idle)")
                self.usage = ProcesserUsageInfo(user: user, sys: sys, idle: idle)
                self.lastReadTime = NSDate().timeIntervalSince1970
            }
        } catch {
            Log.e("error \(error)")
        }
    }

    public func reset() {

        if let usage = usage,
           usage.idle > 10.0/numProcessors
        {
            self.usage = ProcesserUsageInfo(user: usage.user,
                                            sys: usage.sys,
                                            idle: usage.idle - 2/numProcessors)
        } else {
            self.usage = nil
        }
    }
    
    public func percentIdle() -> Double {
        if let usage = usage,
           let lastReadTime = lastReadTime,
           NSDate().timeIntervalSince1970 - lastReadTime < checkIntervalSeconds
        {
            return usage.idle
        }
        readUsage()
        if let usage = usage {
            return usage.idle
        }
        return 0              // XXX fall back case where we can't read 
    }

    public func isIdle(byAtLeast idleAmountPercent: Double) -> Bool {
        if self.percentIdle() < idleAmountPercent { return false }
        self.reset()        
        return true
    }
}
