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
        self.date = NSDate().timeIntervalSince1970

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
    
    init?(from line: String) {
        // CPU usage: 3.44% user, 3.81% sys, 92.74% idle

        // a regex would be cleaner,
        // but swift regexes are a breaking change,
        // which right now is a PITA.
        
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

    // artifically boost cpu usage by some number of cpus
    func withAdditional(cpus: Int) -> ProcessorUsage {
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

