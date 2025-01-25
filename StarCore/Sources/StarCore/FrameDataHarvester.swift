/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import KHTSwift
import logging
import SwiftUI

public actor FrameDataHarvesterDataHolder {

    public var harvesterCount: Int = 0
    public var allOutlierGroupCount: Int = 0
    public var allTotalOutlierProcessingTime: TimeInterval = 0
    public var isolatedOutlierGroupCount: Int = 0
    public var isolatedTotalOutlierProcessingTime: TimeInterval = 0

    private var callback: ((Int,Int,TimeInterval,Int,TimeInterval) -> Void)?

    public func setCallback(_ callback: (@Sendable (Int,Int,TimeInterval,Int,TimeInterval) -> Void)?) {
        self.callback = callback
    }
    
    public func harvesterStarted() {
        harvesterCount += 1
        callback?(harvesterCount,
                  allOutlierGroupCount,
                  allTotalOutlierProcessingTime,
                  isolatedOutlierGroupCount,
                  isolatedTotalOutlierProcessingTime)
    }

    public func harvesterDone() {
        harvesterCount -= 1
        callback?(harvesterCount,
                  allOutlierGroupCount,
                  allTotalOutlierProcessingTime,
                  isolatedOutlierGroupCount,
                  isolatedTotalOutlierProcessingTime)
    }

    public func outlierProcessingFinished(in interval: TimeInterval, for treeType: TreeType) {
        switch treeType {
        case .all:
            allOutlierGroupCount += 1
            allTotalOutlierProcessingTime += interval
        case .isolated:
            allOutlierGroupCount += 1
            allTotalOutlierProcessingTime += interval
        }
        callback?(harvesterCount,
                  allOutlierGroupCount,
                  allTotalOutlierProcessingTime,
                  isolatedOutlierGroupCount,
                  isolatedTotalOutlierProcessingTime)
    }
}

public let frameDataHarvesterDataHolder = FrameDataHarvesterDataHolder()

/*
 show:

 - number of harvesters exist
 - number of outlier groups processed
 - time it took to process each one
 
 */
public final class FrameDataHarvester: Sendable {

    let width: Int
    let height: Int
    let outlierGroups: OutlierGroups?
    let previousOutlierGroups: OutlierGroups?
    let previousOutlierData: FrameHolder? // row major indexed, outlier id keyed
    let nextOutlierGroups: OutlierGroups?
    let nextOutlierData: FrameHolder?     // row major indexed, outlier id keyed

    init(for frame: FrameAirplaneRemover) async {
        self.outlierGroups = await frame.outlierGroups
        self.width = frame.width
        self.height = frame.height
        let previousFrame = await frame.getPreviousFrame() 
        self.previousOutlierGroups = await previousFrame?.getOutlierGroups()
        if let arr = await previousOutlierGroups?.outlierImageDataFunc() {
            self.previousOutlierData = FrameHolder(arr, width: width, height: height)
        } else {
            self.previousOutlierData = nil
        }
        let nextFrame = await frame.getNextFrame()
        self.nextOutlierGroups = await nextFrame?.getOutlierGroups()
        if let arr = await nextOutlierGroups?.outlierImageDataFunc() {
            self.nextOutlierData = FrameHolder(arr, width: width, height: height)
        } else {
            self.nextOutlierData = nil
        }

        await frameDataHarvesterDataHolder.harvesterStarted()
    }

    deinit {
        Task { await frameDataHarvesterDataHolder.harvesterDone() }
    }
    
    public func decisionTreeValues(for group: OutlierGroup,
                                   with treeType: TreeType = .all) async -> [Double]
    {
        let startTime = Date().timeIntervalSince1970
        var neighborLineScores = NeighborLineScores()
        if treeType == .all,
           let originalGroupLine = await group.originZeroLine,
           let previousOutlierGroups,
           let nextOutlierGroups,
           let previousOutlierData,
           let nextOutlierData
        {
            neighborLineScores = await
              StarCore.neighborLineScores(of: group,
                                          width: width,
                                          height: height,
                                          with: previousOutlierGroups,
                                          and: nextOutlierGroups,
                                          previousOutlierImage: previousOutlierData,
                                          nextOutlierImage: nextOutlierData,
                                          originalGroupLine: originalGroupLine)
            await group.set(neighborLineScores: neighborLineScores)
        }

        var ret = [Double](repeating: 0, count: OutlierGroupFeature.allCases.count)
        
        for type in OutlierGroupFeature.allCases {
            if type.isUsed(for: treeType) {
                switch type {
                case .numberOfNearbyOutliersInSameFrame:
                    ret[type.sortOrder] =
                      await calculateNumberOfNearbyOutliersInSameFrame(of: group, in: outlierGroups)
                    
                case .nearbyDirectOverlapScore:
                    ret[type.sortOrder] =
                      calculateNearbyDirectOverlapScore(of: group,
                                                        previousImageData: previousOutlierData,
                                                        nextImageData: nextOutlierData)
                case .boundingBoxOverlapScore:
                    ret[type.sortOrder] =
                      calculateBoundingBoxOverlapScore(of: group,
                                                       previousImageData: previousOutlierData,
                                                       nextImageData: nextOutlierData)
                case .neighborLineThetaScore:
                    ret[type.sortOrder] = neighborLineScores.thetaScore
                case .neighborLineRhoScore:
                    ret[type.sortOrder] = neighborLineScores.rhoScore
                case .neighborLineSizeScore:
                    ret[type.sortOrder] = neighborLineScores.sizeScore
                case .neighborLineBrightnessScore:
                    ret[type.sortOrder] = neighborLineScores.brightnessScore
                case .neighborLineDistanceScore:
                    ret[type.sortOrder] = neighborLineScores.distanceScore

                    // all the rest are fast enough like this
                default:
                    ret[type.sortOrder] = await type.decisionTreeValue(of: group)
                }
            }
        }

        let endTime = Date().timeIntervalSince1970
        Task {
            await frameDataHarvesterDataHolder.outlierProcessingFinished(in: (endTime-startTime), for: treeType)
        }
        
        return ret
    }
}
