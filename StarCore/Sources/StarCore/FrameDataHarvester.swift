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

//public let frameDataHarvesterDataHolder = FrameDataHarvesterDataHolder()

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

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.outlierGroups = nil
        self.previousOutlierGroups = nil
        self.previousOutlierData = nil
        self.nextOutlierGroups = nil
        self.nextOutlierData = nil
    }
    
    init(for frame: FrameAirplaneRemover, treeType: TreeType = .all) async {
        self.width = frame.width
        self.height = frame.height
        switch treeType {
        case .all:
            self.outlierGroups = await frame.outlierGroups
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

        case .isolated:
            self.outlierGroups = nil
            self.previousOutlierGroups = nil
            self.previousOutlierData = nil
            self.nextOutlierGroups = nil
            self.nextOutlierData = nil
        }
        
//        await frameDataHarvesterDataHolder.harvesterStarted()
    }

    deinit {
//        Task { await frameDataHarvesterDataHolder.harvesterDone() }
    }
    
    public func decisionTreeValues(for group: OutlierGroup) async -> [Double] {

        // XXX XXX XXX
        //return [Double](repeating: 0, count: OutlierGroupFeature.allCases.count)
        // XXX XXX XXX
        
        //        let startTime = Date().timeIntervalSince1970

        // start with scores of all zeros
        var neighborLineScores = NeighborLineScores()
        if let exisingNeighborLineScores = await group.exisitingNeighborLineScores {
            // grab existing ones if they exist
            neighborLineScores = exisingNeighborLineScores
        } else if // don't process smaller blobs with this method
                  group.size >= OutlierGroupFeature.minNeighborScoreSize, 
                  let originalGroupLine = await group.originZeroLine,
                  let previousOutlierGroups,
                  let nextOutlierGroups,
                  let previousOutlierData,
                  let nextOutlierData
        {
            // otherwise compute them, if we need them
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

        var ret = [Double](repeating: 0, count: OutlierGroupFeature.allCases.count+1)
        ret[0] = Double(group.id) // group id goes first for later categorization
        
        for type in OutlierGroupFeature.allCases {
            switch type {
            case .numberOfNearbyOutliersInSameFrame:
                if group.size >= OutlierGroupFeature.minNeighborScoreSize {
                    ret[type.sortOrder+1] =
                      await calculateNumberOfNearbyOutliersInSameFrame(of: group,
                                                                       in: outlierGroups)
                }

            case .nearbyDirectOverlapScore:
                if group.size >= OutlierGroupFeature.minNeighborScoreSize {
                    ret[type.sortOrder+1] =
                      calculateNearbyDirectOverlapScore(of: group,
                                                        previousImageData: previousOutlierData,
                                                        nextImageData: nextOutlierData)
                }
            case .boundingBoxOverlapScore:
                if group.size >= OutlierGroupFeature.minNeighborScoreSize {
                    ret[type.sortOrder+1] =
                      calculateBoundingBoxOverlapScore(of: group,
                                                       previousImageData: previousOutlierData,
                                                       nextImageData: nextOutlierData)
                }
            case .neighborLineThetaScore:
                ret[type.sortOrder+1] = neighborLineScores.thetaScore
            case .neighborLineRhoScore:
                ret[type.sortOrder+1] = neighborLineScores.rhoScore
            case .neighborLineSizeScore:
                ret[type.sortOrder+1] = neighborLineScores.sizeScore
            case .neighborLineBrightnessScore:
                ret[type.sortOrder+1] = neighborLineScores.brightnessScore
            case .neighborLineDistanceScore:
                ret[type.sortOrder+1] = neighborLineScores.distanceScore

                // all the rest are fast enough like this
            default:
                ret[type.sortOrder+1] = await type.decisionTreeValue(of: group)
            }
        }

//        let endTime = Date().timeIntervalSince1970
//        Task {
//            await frameDataHarvesterDataHolder.outlierProcessingFinished(in: (endTime-startTime), for: treeType)
//        }
        
        return ret
    }
}
