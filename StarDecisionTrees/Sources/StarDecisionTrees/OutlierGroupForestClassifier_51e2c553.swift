/*
   written by decision_tree_generator on 2024-05-22 17:13:51 +0000.

   The classifications of 4 trees are combined here with weights from test data.
   
   Trees were computed to the maximum depth possible

   Trees were NOT pruned with test data

   tree(StarCore.DecisionTreeParams(name: "9e7f4b1a", inputSequences: ["/qp/star_validated/05_21_2024-4-out-train"], positiveTrainingSize: 13002, negativeTrainingSize: 4051380, decisionTypes: [StarCore.OutlierGroup.Feature.size, StarCore.OutlierGroup.Feature.width, StarCore.OutlierGroup.Feature.height, StarCore.OutlierGroup.Feature.centerX, StarCore.OutlierGroup.Feature.centerY, StarCore.OutlierGroup.Feature.minX, StarCore.OutlierGroup.Feature.minY, StarCore.OutlierGroup.Feature.maxX, StarCore.OutlierGroup.Feature.maxY, StarCore.OutlierGroup.Feature.hypotenuse, StarCore.OutlierGroup.Feature.aspectRatio, StarCore.OutlierGroup.Feature.fillAmount, StarCore.OutlierGroup.Feature.surfaceAreaRatio, StarCore.OutlierGroup.Feature.averagebrightness, StarCore.OutlierGroup.Feature.medianBrightness, StarCore.OutlierGroup.Feature.maxBrightness, StarCore.OutlierGroup.Feature.avgCountOfFirst10HoughLines, StarCore.OutlierGroup.Feature.maxThetaDiffOfFirst10HoughLines, StarCore.OutlierGroup.Feature.maxRhoDiffOfFirst10HoughLines, StarCore.OutlierGroup.Feature.avgCountOfAllHoughLines, StarCore.OutlierGroup.Feature.maxThetaDiffOfAllHoughLines, StarCore.OutlierGroup.Feature.maxRhoDiffOfAllHoughLines, StarCore.OutlierGroup.Feature.numberOfNearbyOutliersInSameFrame, StarCore.OutlierGroup.Feature.adjecentFrameNeighboringOutliersBestTheta, StarCore.OutlierGroup.Feature.maxHoughTransformCount, StarCore.OutlierGroup.Feature.maxHoughTheta, StarCore.OutlierGroup.Feature.maxOverlap, StarCore.OutlierGroup.Feature.pixelBorderAmount, StarCore.OutlierGroup.Feature.averageLineVariance, StarCore.OutlierGroup.Feature.lineLength, StarCore.OutlierGroup.Feature.histogramStreakDetection, StarCore.OutlierGroup.Feature.longerHistogramStreakDetection, StarCore.OutlierGroup.Feature.neighboringInterFrameOutlierThetaScore, StarCore.OutlierGroup.Feature.maxOverlapTimesThetaHisto, StarCore.OutlierGroup.Feature.nearbyDirectOverlapScore, StarCore.OutlierGroup.Feature.boundingBoxOverlapScore], decisionSplitTypes: [StarCore.DecisionSplitType.median], maxDepth: Optional(-1), pruned: false))

   tree(StarCore.DecisionTreeParams(name: "5be539cb", inputSequences: ["/qp/star_validated/05_21_2024-4-out-train"], positiveTrainingSize: 13002, negativeTrainingSize: 4051380, decisionTypes: [StarCore.OutlierGroup.Feature.size, StarCore.OutlierGroup.Feature.width, StarCore.OutlierGroup.Feature.height, StarCore.OutlierGroup.Feature.centerX, StarCore.OutlierGroup.Feature.centerY, StarCore.OutlierGroup.Feature.minX, StarCore.OutlierGroup.Feature.minY, StarCore.OutlierGroup.Feature.maxX, StarCore.OutlierGroup.Feature.maxY, StarCore.OutlierGroup.Feature.hypotenuse, StarCore.OutlierGroup.Feature.aspectRatio, StarCore.OutlierGroup.Feature.fillAmount, StarCore.OutlierGroup.Feature.surfaceAreaRatio, StarCore.OutlierGroup.Feature.averagebrightness, StarCore.OutlierGroup.Feature.medianBrightness, StarCore.OutlierGroup.Feature.maxBrightness, StarCore.OutlierGroup.Feature.avgCountOfFirst10HoughLines, StarCore.OutlierGroup.Feature.maxThetaDiffOfFirst10HoughLines, StarCore.OutlierGroup.Feature.maxRhoDiffOfFirst10HoughLines, StarCore.OutlierGroup.Feature.avgCountOfAllHoughLines, StarCore.OutlierGroup.Feature.maxThetaDiffOfAllHoughLines, StarCore.OutlierGroup.Feature.maxRhoDiffOfAllHoughLines, StarCore.OutlierGroup.Feature.numberOfNearbyOutliersInSameFrame, StarCore.OutlierGroup.Feature.adjecentFrameNeighboringOutliersBestTheta, StarCore.OutlierGroup.Feature.maxHoughTransformCount, StarCore.OutlierGroup.Feature.maxHoughTheta, StarCore.OutlierGroup.Feature.maxOverlap, StarCore.OutlierGroup.Feature.pixelBorderAmount, StarCore.OutlierGroup.Feature.averageLineVariance, StarCore.OutlierGroup.Feature.lineLength, StarCore.OutlierGroup.Feature.histogramStreakDetection, StarCore.OutlierGroup.Feature.longerHistogramStreakDetection, StarCore.OutlierGroup.Feature.neighboringInterFrameOutlierThetaScore, StarCore.OutlierGroup.Feature.maxOverlapTimesThetaHisto, StarCore.OutlierGroup.Feature.nearbyDirectOverlapScore, StarCore.OutlierGroup.Feature.boundingBoxOverlapScore], decisionSplitTypes: [StarCore.DecisionSplitType.median], maxDepth: Optional(-1), pruned: false))

   tree(StarCore.DecisionTreeParams(name: "6156cb5b", inputSequences: ["/qp/star_validated/05_21_2024-4-out-train"], positiveTrainingSize: 13002, negativeTrainingSize: 4051380, decisionTypes: [StarCore.OutlierGroup.Feature.size, StarCore.OutlierGroup.Feature.width, StarCore.OutlierGroup.Feature.height, StarCore.OutlierGroup.Feature.centerX, StarCore.OutlierGroup.Feature.centerY, StarCore.OutlierGroup.Feature.minX, StarCore.OutlierGroup.Feature.minY, StarCore.OutlierGroup.Feature.maxX, StarCore.OutlierGroup.Feature.maxY, StarCore.OutlierGroup.Feature.hypotenuse, StarCore.OutlierGroup.Feature.aspectRatio, StarCore.OutlierGroup.Feature.fillAmount, StarCore.OutlierGroup.Feature.surfaceAreaRatio, StarCore.OutlierGroup.Feature.averagebrightness, StarCore.OutlierGroup.Feature.medianBrightness, StarCore.OutlierGroup.Feature.maxBrightness, StarCore.OutlierGroup.Feature.avgCountOfFirst10HoughLines, StarCore.OutlierGroup.Feature.maxThetaDiffOfFirst10HoughLines, StarCore.OutlierGroup.Feature.maxRhoDiffOfFirst10HoughLines, StarCore.OutlierGroup.Feature.avgCountOfAllHoughLines, StarCore.OutlierGroup.Feature.maxThetaDiffOfAllHoughLines, StarCore.OutlierGroup.Feature.maxRhoDiffOfAllHoughLines, StarCore.OutlierGroup.Feature.numberOfNearbyOutliersInSameFrame, StarCore.OutlierGroup.Feature.adjecentFrameNeighboringOutliersBestTheta, StarCore.OutlierGroup.Feature.maxHoughTransformCount, StarCore.OutlierGroup.Feature.maxHoughTheta, StarCore.OutlierGroup.Feature.maxOverlap, StarCore.OutlierGroup.Feature.pixelBorderAmount, StarCore.OutlierGroup.Feature.averageLineVariance, StarCore.OutlierGroup.Feature.lineLength, StarCore.OutlierGroup.Feature.histogramStreakDetection, StarCore.OutlierGroup.Feature.longerHistogramStreakDetection, StarCore.OutlierGroup.Feature.neighboringInterFrameOutlierThetaScore, StarCore.OutlierGroup.Feature.maxOverlapTimesThetaHisto, StarCore.OutlierGroup.Feature.nearbyDirectOverlapScore, StarCore.OutlierGroup.Feature.boundingBoxOverlapScore], decisionSplitTypes: [StarCore.DecisionSplitType.median], maxDepth: Optional(-1), pruned: false))

   tree(StarCore.DecisionTreeParams(name: "133c5ea4", inputSequences: ["/qp/star_validated/05_21_2024-4-out-train"], positiveTrainingSize: 13002, negativeTrainingSize: 4051380, decisionTypes: [StarCore.OutlierGroup.Feature.size, StarCore.OutlierGroup.Feature.width, StarCore.OutlierGroup.Feature.height, StarCore.OutlierGroup.Feature.centerX, StarCore.OutlierGroup.Feature.centerY, StarCore.OutlierGroup.Feature.minX, StarCore.OutlierGroup.Feature.minY, StarCore.OutlierGroup.Feature.maxX, StarCore.OutlierGroup.Feature.maxY, StarCore.OutlierGroup.Feature.hypotenuse, StarCore.OutlierGroup.Feature.aspectRatio, StarCore.OutlierGroup.Feature.fillAmount, StarCore.OutlierGroup.Feature.surfaceAreaRatio, StarCore.OutlierGroup.Feature.averagebrightness, StarCore.OutlierGroup.Feature.medianBrightness, StarCore.OutlierGroup.Feature.maxBrightness, StarCore.OutlierGroup.Feature.avgCountOfFirst10HoughLines, StarCore.OutlierGroup.Feature.maxThetaDiffOfFirst10HoughLines, StarCore.OutlierGroup.Feature.maxRhoDiffOfFirst10HoughLines, StarCore.OutlierGroup.Feature.avgCountOfAllHoughLines, StarCore.OutlierGroup.Feature.maxThetaDiffOfAllHoughLines, StarCore.OutlierGroup.Feature.maxRhoDiffOfAllHoughLines, StarCore.OutlierGroup.Feature.numberOfNearbyOutliersInSameFrame, StarCore.OutlierGroup.Feature.adjecentFrameNeighboringOutliersBestTheta, StarCore.OutlierGroup.Feature.maxHoughTransformCount, StarCore.OutlierGroup.Feature.maxHoughTheta, StarCore.OutlierGroup.Feature.maxOverlap, StarCore.OutlierGroup.Feature.pixelBorderAmount, StarCore.OutlierGroup.Feature.averageLineVariance, StarCore.OutlierGroup.Feature.lineLength, StarCore.OutlierGroup.Feature.histogramStreakDetection, StarCore.OutlierGroup.Feature.longerHistogramStreakDetection, StarCore.OutlierGroup.Feature.neighboringInterFrameOutlierThetaScore, StarCore.OutlierGroup.Feature.maxOverlapTimesThetaHisto, StarCore.OutlierGroup.Feature.nearbyDirectOverlapScore, StarCore.OutlierGroup.Feature.boundingBoxOverlapScore], decisionSplitTypes: [StarCore.DecisionSplitType.median], maxDepth: Optional(-1), pruned: false))


 */

import Foundation
import StarCore

// DO NOT EDIT THIS FILE
// DO NOT EDIT THIS FILE
// DO NOT EDIT THIS FILE

public final class OutlierGroupForestClassifier_51e2c553: NamedOutlierGroupClassifier {

    public init() { }

    public let name = "51e2c553"
    
    public let type: ClassifierType = .forest(DecisionForestParams(name: "51e2c553",
                                                                   treeCount: 4,
                                                                   treeNames: [ "9e7f4b1a", "5be539cb", "6156cb5b", "133c5ea4"]))

    let tree_9e7f4b1a = OutlierGroupDecisionTreeForest_9e7f4b1a()
    let tree_5be539cb = OutlierGroupDecisionTreeForest_5be539cb()
    let tree_6156cb5b = OutlierGroupDecisionTreeForest_6156cb5b()
    let tree_133c5ea4 = OutlierGroupDecisionTreeForest_133c5ea4()

    // returns -1 for negative, +1 for positive
    public func classification(of group: ClassifiableOutlierGroup) -> Double {
        var total: Double = 0.0

        total += self.tree_9e7f4b1a.classification(of: group) * 0.9969342168634681
        total += self.tree_5be539cb.classification(of: group) * 0.9968561606297643
        total += self.tree_6156cb5b.classification(of: group) * 0.9968860545065019
        total += self.tree_133c5ea4.classification(of: group) * 0.9968827329646421

        return total / 4
    }

    // returns -1 for negative, +1 for positive
    public func classification (
       of features: [OutlierGroup.Feature],   // parallel
       and values: [Double]                   // arrays
    ) -> Double
    {
        var total: Double = 0.0
        
        let featureData = OutlierGroupFeatureData(features: features, values: values)

        total += self.tree_9e7f4b1a.classification(of: featureData) * 0.9969342168634681
        total += self.tree_5be539cb.classification(of: featureData) * 0.9968561606297643
        total += self.tree_6156cb5b.classification(of: featureData) * 0.9968860545065019
        total += self.tree_133c5ea4.classification(of: featureData) * 0.9968827329646421

        return total / 4
    }
}
