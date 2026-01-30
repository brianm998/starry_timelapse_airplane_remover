import Foundation
import CoreGraphics
import KHTSwift
import kht_bridge
import Combine

@MainActor
@Observable
public class FrameObserver {
    public init() { }

    public var numberOfPositiveOutliers: Int? 
    public var numberOfNegativeOutliers: Int? 
    public var numberOfUndecidedOutliers: Int?
    public var numberOfTrashOutliers: Int?

    public var starAlignmentResults: FrameAlignmentResults?
    public var earthAlignmentResults: FrameAlignmentResults?

    public var numberOfSkyKeyPoints: Int?
    public var numberOfEarthKeyPoints: Int?
    
    public var cleanMethod: CleanMethod?
    
    // XXX stick more here, like state

    public func set(cleanMethod: CleanMethod) {
        self.cleanMethod = cleanMethod
    }
    
    public func set(starAlignmentResults: FrameAlignmentResults) {
        self.starAlignmentResults = starAlignmentResults
    }

    public func set(earthAlignmentResults: FrameAlignmentResults) {
        self.earthAlignmentResults = earthAlignmentResults
    }
    
    public func set(numberOfPositiveOutliers: Int) {
        self.numberOfPositiveOutliers = numberOfPositiveOutliers
    }

    public func set(numberOfNegativeOutliers: Int) {
        self.numberOfNegativeOutliers = numberOfNegativeOutliers
    }

    public func set(numberOfUndecidedOutliers: Int) {
        self.numberOfUndecidedOutliers = numberOfUndecidedOutliers
    }

    public func set(numberOfTrashOutliers: Int) {
        self.numberOfTrashOutliers = numberOfTrashOutliers
    }

    public func set(numberOfSkyKeyPoints: Int) {
        self.numberOfSkyKeyPoints = numberOfSkyKeyPoints
    }

    public func set(numberOfEarthKeyPoints: Int) {
        self.numberOfEarthKeyPoints = numberOfEarthKeyPoints
    }
    
    func set(numberOfPositiveOutliers: Int,
             numberOfNegativeOutliers: Int,
             numberOfUndecidedOutliers: Int,
             numberOfTrashOutliers: Int)
    {
        self.numberOfPositiveOutliers = numberOfPositiveOutliers
        self.numberOfNegativeOutliers = numberOfNegativeOutliers
        self.numberOfUndecidedOutliers = numberOfUndecidedOutliers
        self.numberOfTrashOutliers = numberOfTrashOutliers
    }
}
