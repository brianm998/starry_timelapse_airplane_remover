import Foundation
import StarCoreC
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// How many frames star works on at once by default.
///
/// `ProcessInfo.processorCount` is the *logical* count — on a hyperthreaded machine, twice
/// the cores — and defaulting to it was defaulting to twice as much concurrency as the
/// machine has hardware for.  Nothing star runs concurrently gets faster for it: the heavy
/// operations are SIFT detection, homography warps and blob analysis, all compute- and
/// memory-bandwidth-bound, so two of them on the two threads of one core contend for the
/// same execution units instead of running twice as fast.
///
/// What each of them does do is reserve a working frame's worth of RAM, and the memory
/// gating is sized from this number: `Config.keypointConcurrency` takes it as the cap that
/// the memory budget is then applied under, and `FrameSaveQueue` sizes itself from it too.
/// On a 36-thread, 18-core machine, defaulting to 36 asked the budget to cover twice the
/// frames the machine could usefully work on — which on a large sequence is the difference
/// between a run that fits and one that spends its time in the compressor.
///
/// So: physical cores, from `star_physical_core_count`, which asks the OS
/// (`hw.physicalcpu`, `/proc/cpuinfo` topology, `GetLogicalProcessorInformation`).  Nothing
/// stops a user raising it — the gui's field still goes to the logical count — this is only
/// where a sequence that has never been configured starts.
public enum PhysicalCores {

    /// The machine's physical cores, or the logical count where the OS will not say.
    ///
    /// Computed once: it cannot change while the process runs, and it is read from
    /// `Config`'s property initialiser, which runs for every `Config` anyone builds.
    public static let count: Int = {
        let logical = ProcessInfo.processInfo.processorCount
        let physical = Int(star_physical_core_count())

        guard physical > 0 else {
            // No topology to be had — an unusual platform, or a kernel that does not
            // report it.  The logical count is the right answer on a machine with no SMT
            // to discount, and the safe one on a machine that has it.
            Log.i("physical core count unavailable; using the logical count (\(logical))")
            return logical
        }

        // A physical count above the logical one is nonsense, and would mean asking for
        // more concurrency than the machine admits to having.
        guard physical <= logical else {
            Log.w("physical core count \(physical) exceeds the logical count \(logical) — " +
                  "using the logical count")
            return logical
        }
        return physical
    }()
}
