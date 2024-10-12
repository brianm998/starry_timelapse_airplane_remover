import Foundation
import CoreGraphics
import logging
import Cocoa

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

 */


/*
 UI related methods
 */
extension FrameAirplaneRemover {
    
    public func applyDecisionTreeToAutoSelectedOutliers() async {
        if let classifier = currentClassifier {
            await foreachOutlierGroupAsync() { group in
                var apply = true
                if let shouldPaint = await group.shouldPaint() {
                    switch shouldPaint {
                    case .userSelected(_):
                        // leave user selected ones in place
                        apply = false
                    default:
                        break
                    }
                }
                if apply {
                    Log.d("applying decision tree")
                    await group.shouldPaint(.fromClassifier(await classifier.asyncClassification(of: group)))
                }
                return .continue
            }
        } else {
            Log.w("no classifier")
        }
    }

    public func clearOutlierGroupValueCaches() async {
        await foreachOutlierGroupAsync() { group in
            await group.clearFeatureValueCache()
            return .continue
        }
    }

    public func applyDecisionTreeToAllOutliers() async {
        //Log.d("frame \(self.frameIndex) applyDecisionTreeToAll \(self.outlierGroups?.members.count ?? 0) Outliers")
        if let classifier = currentClassifier {
            let startTime = NSDate().timeIntervalSince1970
            await foreachOutlierGroupAsync() { group in
                if await group.shouldPaint() == nil {
                    // only apply classifier when no other classification is otherwise present
                    await group.shouldPaint(.fromClassifier(await classifier.asyncClassification(of: group)))
                }
                return .continue
            }
            let endTime = NSDate().timeIntervalSince1970
            Log.i("frame \(self.frameIndex) spent \(endTime - startTime) seconds classifing outlier groups");
        } else {
            Log.w("no classifier")
        }
        Log.d("frame \(self.frameIndex) DONE applyDecisionTreeToAllOutliers")
    }
    
    public func userSelectAllOutliers(toShouldPaint shouldPaint: Bool) async {
        await foreachOutlierGroupAsync() { group in
            await group.shouldPaint(.userSelected(shouldPaint))
            return .continue
        }
    }

    public func userSelectUndecidedOutliers(toShouldPaint shouldPaint: Bool) async {
        await foreachOutlierGroupAsync() { group in
            if await group.shouldPaint() == nil {
                await group.shouldPaint(.userSelected(shouldPaint))
            }
            return .continue
        }
    }

    public func userSelectAllOutliers(toShouldPaint shouldPaint: Bool,
                                      overlapping group: OutlierGroup) async
    {
        guard let outlierGroups else { return }

        for group in await outlierGroups.groups(overlapping: group) {
            await group.shouldPaint(.userSelected(shouldPaint))
        }
    }
    
    public func userSelectAllOutliers(toShouldPaint shouldPaint: Bool,
                                      between startLocation: CGPoint,
                                      and endLocation: CGPoint) async
    {
        await foreachOutlierGroupAsync(between: startLocation, and: endLocation) { group in
            await group.shouldPaint(.userSelected(shouldPaint))
            return .continue
        }
    }
}
