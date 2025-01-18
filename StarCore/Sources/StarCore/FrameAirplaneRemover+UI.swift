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
    
    public func applyDecisionTreeToAutoSelectedOutliers(includingDustbin: Bool) async {
        if let classifier = await currentClassifier.get(for: .all) {
            await foreachOutlierGroupMulti(includingDustbin: includingDustbin) { group, isInDustbin in
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
                    if isInDustbin {
                        await self.outlierGroups?.promoteFromDustbin(group)
                    }
                }
            }
        } else {
            Log.w("no classifier")
        }
    }

    public func clearOutlierGroupValueCaches(includingDustbin: Bool) async {
        await foreachOutlierGroupMulti(includingDustbin: includingDustbin) { group, _ in
            await group.clearFeatureValueCache()
        }
    }

    public func applyDecisionTreeToAllOutliers(includingDustbin: Bool) async -> Task<Void,Never>? {
        //Log.d("frame \(self.frameIndex) applyDecisionTreeToAll \(self.outlierGroups?.members.count ?? 0) Outliers")
        let startTime = NSDate().timeIntervalSince1970
        if let classifier = await currentClassifier.get(for: .all), 
           let outlierGroups
        {
            return await Task.detached(priority: .userInitiated) {
                await withTaskGroup(of: Void.self) { taskGroup in
                    for (_, group) in await outlierGroups.getMembers() {
                        taskGroup.addTask {
                            if await group.shouldPaint() == nil {
                                // only apply classifier when no other classification is otherwise present
                                let featureData = await group.featureData()
                                let classification = classifier.classification(of: featureData)
                                await group.shouldPaint(.fromClassifier(classification))
                            }
                        }
                    }
                    if includingDustbin {
                        for (_, group) in await outlierGroups.getDustbin() {
                            taskGroup.addTask {
                                if await group.shouldPaint() == nil {
                                    // only apply classifier when no other classification is otherwise present
                                    let featureData = await group.featureData()
                                    let classification = classifier.classification(of: featureData)
                                    await group.shouldPaint(.fromClassifier(classification))
                                    await outlierGroups.promoteFromDustbin(group)
                                }
                            }
                        }

                    }
                    await taskGroup.waitForAll()
                }
            }
            let endTime = NSDate().timeIntervalSince1970
            Log.i("frame \(self.frameIndex) spent \(endTime - startTime) seconds classifing outlier groups");
        } else {
            Log.w("no classifier")
        }
        Log.d("frame \(self.frameIndex) DONE applyDecisionTreeToAllOutliers")
        return nil
    }
    
    public func userSelectAllOutliers(toShouldPaint shouldPaint: Bool,
                                      includingDustbin: Bool) async
    {
        Task.detached {
            await self.foreachOutlierGroupMulti(includingDustbin: includingDustbin) { group, isInDustbin in
                await group.shouldPaint(.userSelected(shouldPaint))
                if isInDustbin {
                    await self.outlierGroups?.promoteFromDustbin(group)
                }
            }
            // 
        }
    }

    public func userSelectUndecidedOutliers(toShouldPaint shouldPaint: Bool,
                                            includingDustbin: Bool) async
    {
        Task.detached {
            await self.foreachOutlierGroupMulti(includingDustbin: includingDustbin) { group, isInDustbin in
                if await group.shouldPaint() == nil {
                    await group.shouldPaint(.userSelected(shouldPaint))
                    if isInDustbin {
                        await self.outlierGroups?.promoteFromDustbin(group)
                    }
                }
            }
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
                                      and endLocation: CGPoint,
                                      includingDustbin: Bool) async
    {
        await foreachOutlierGroupMulti(between: startLocation,
                                       and: endLocation,
                                       includingDustbin: includingDustbin) { group, isInDustbin in
            await group.shouldPaint(.userSelected(shouldPaint))
            if isInDustbin {
                await self.outlierGroups?.promoteFromDustbin(group)
            }
        }
    }
}
