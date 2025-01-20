import SwiftUI
import StarCore
import logging

@MainActor @Observable
public final class OutlierWindowViewModel {

    public var isSidePanelShowing = false
    public var houghLineFinderArgs: HoughLineFinder.Args?

    public var lineInfo: [HoughLineFinder.LineInfo] = []

    public var selectedLines = Set<HoughLineFinder.LineInfo.ID>()

    public func didSelect(ids: Set<HoughLineFinder.LineInfo.ID>) {
        if ids.count == 1,
           selectedOutliers.count == 1
        {
            for value in ids {
                if let lineInfo = lineInfo.first(where: { $0.id == value }) {
                    Log.d("selected line \(lineInfo.line)")
                    Task {
                        await selectedOutliers[0].set(line: lineInfo)
                    }
                }
            }
        }
    }
    
    public func loadLineInfo() async {
        if selectedOutliers.count == 1 {
            let outlier = selectedOutliers[0]
            let finder = await outlier.lineFinder
            var data = finder.lineData
            data.sort { $0.score > $1.score }
            self.lineInfo = data
        }
    }
    
    init() {
        Task { houghLineFinderArgs = await constants.getHoughLineFinderArgs() }
    }

    public var selectedOutliers: [OutlierGroup] = []

    public var showName = false
    public var showCenterX = false
    public var showCenterY = false
    public var showWidth = true
    public var showHeight = true
    public var showMinX = false
    public var showMinY = false
    public var showMaxX = false
    public var showMaxY = false
    public var showHypotenuse = true
    public var showAspectRatio = true
    public var showFillAmount = true
    public var showSurfaceAreaRatio = true
    public var showAveragebrightness = true
    public var showMedianBrightness = true
    public var showMaxBrightness = true
    public var showNumberOfNearbyOutliersInSameFrame = true
    public var showMaxHoughTransformCount = true
    public var showPixelBorderAmount = true
    public var showAverageLineVariance = true
    public var showLineLength = true
    public var showNearbyDirectOverlapScore = true
    public var showBoundingBoxOverlapScore = true
    public var showLineFillAmount = true
    public var showBorderBrightness = true
    public var showBunchCount = true
    public var showMedianBunchSize = true
    public var showMaxBunchSize = true
    public var showNeighborLineScore = true
    
    public func selectAll() {
        setAll(to: true)
    }

    public func clearAll() {
        setAll(to: false)
    }

    public func setAll(to value: Bool) {
        showName = value
        showCenterX = value
        showCenterY = value
        showWidth = value
        showHeight = value
        showMinX = value
        showMinY = value
        showMaxX = value
        showMaxY = value
        showHypotenuse = value
        showAspectRatio = value
        showFillAmount = value
        showSurfaceAreaRatio = value
        showAveragebrightness = value
        showMedianBrightness = value
        showMaxBrightness = value
        showNumberOfNearbyOutliersInSameFrame = value
        showMaxHoughTransformCount = value
        showPixelBorderAmount = value
        showAverageLineVariance = value
        showLineLength = value
        showNearbyDirectOverlapScore = value
        showBoundingBoxOverlapScore = value
        showLineFillAmount = value
        showBorderBrightness = value
        showBunchCount = value
        showMedianBunchSize = value
        showMaxBunchSize = value
        showNeighborLineScore = value
    }
}
