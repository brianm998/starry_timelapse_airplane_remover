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
public class ProcessorUsageFinder {

    weak var tracker: ProcessorUsageTrackerV2?
    private let interval: Double
    
    public init(interval: Double) {
        self.interval = interval

        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            Log.i("timer fired")
            self.reportUsage()
        }
    }

    private func reportUsage() {
        guard let tracker else { return }
        if let usage = self.readUsage() {
            Task { await tracker.update(with: usage) }
        } else {
            Log.i("couldn't read processor usage")
        }
    }

    
    private func readUsage() -> ProcessorUsage? {
        // if we get no response, assume the CPU is busy
        var ret = ProcessorUsage.busy()
        do {
            try ObjC.catchException {
                // Failed to set posix_spawn_file_actions for fd -1 at index 0 with errno 9
                let usageString = try shellOut(to: "top -R -F -n 0 -l 2 -s 0")
                
                let lines = usageString.split(whereSeparator: \.isNewline)
                
                var isFirst = true

                Log.d("lines: \(lines)")
                
                for line in lines {
                    if line.starts(with: "CPU usage:") {
                        if isFirst {
                            // ignore the first reading 
                            isFirst = false
                        } else {
                            if let usage = ProcessorUsage(from: String(line)) {
                                Log.d("found cpu usage \(usage)")
                                ret = usage
                                break
                            }
                        }
                    }
                }
            }
        } catch {
            Log.e("error \(error)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            Log.i("timer fired")
            self.reportUsage()
        }
        
        return ret
    }
}
