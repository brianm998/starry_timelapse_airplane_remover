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
    
    public func userSelectAllOutliers(toShouldPaint shouldPaint: Bool,
                                      overlapping group: OutlierGroup)
    {
        guard let outlierGroups else { return }

        for group in outlierGroups.groups(overlapping: group) {
            group.shouldPaint(.userSelected(shouldPaint))
        }
    }
    
    public func userSelectAllOutliers(toShouldPaint shouldPaint: Bool,
                                      between startLocation: CGPoint,
                                      and endLocation: CGPoint)
    {
        foreachOutlierGroup(between: startLocation, and: endLocation) { group in
            group.shouldPaint(.userSelected(shouldPaint))
            return .continue
        }
    }

    public func applyDecisionTreeToAutoSelectedOutliers() async {
        if let classifier = currentClassifier {
            foreachOutlierGroup() { group in
                var apply = true
                if let shouldPaint = group.shouldPaint {
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
                    group.shouldPaint(.fromClassifier(classifier.classification(of: group)))
                }
                return .continue
            }
        } else {
            Log.w("no classifier")
        }
    }

    public func clearOutlierGroupValueCaches() async {
        foreachOutlierGroup() { group in
            group.clearFeatureValueCache()
            return .continue
        }
    }

    public func applyDecisionTreeToAllOutliers() async {
        Log.d("frame \(self.frameIndex) applyDecisionTreeToAll \(self.outlierGroups?.members.count ?? 0) Outliers")
        if let classifier = currentClassifier {
            let startTime = NSDate().timeIntervalSince1970
            foreachOutlierGroup() { group in
                if group.shouldPaint == nil {
                    // only apply classifier when no other classification is otherwise present
                    group.shouldPaint(.fromClassifier(classifier.classification(of: group)))
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
    
    public func userSelectAllOutliers(toShouldPaint shouldPaint: Bool) {
        foreachOutlierGroup() { group in
            group.shouldPaint(.userSelected(shouldPaint))
            return .continue
        }
    }

    public func userSelectUndecidedOutliers(toShouldPaint shouldPaint: Bool) {
        foreachOutlierGroup() { group in
            if group.shouldPaint == nil {
                group.shouldPaint(.userSelected(shouldPaint))
            }
            return .continue
        }
    }
}
