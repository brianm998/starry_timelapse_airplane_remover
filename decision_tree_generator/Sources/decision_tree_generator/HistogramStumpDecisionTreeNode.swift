
import Foundation
import StarCore
import logging
    
    /*

     calculate a score based upon how var it is from the central value
     if the given value is the central value, return 0
     calculate a histogram of some size (10, more?),
     bracketed by the points where the data is all positive or negative.
     use a quick method to calculate what bucket the source fills into,
     and return that value

     */


// a stumped node that uses a histogram of the training data to classify
class HistogramStumpDecisionTreeNode: SwiftDecisionTree, @unchecked Sendable {

    let result: DecisionResult
    
    let minValue: Double

    let bucketSize: Double      // the width of each histo bucket
    
    let histogramValues: [Double]
    
    // indentention is levels of recursion, not spaces directly
    let indent: Int

    // how far do we recurse before starting a new method?
    let newMethodLevel: Int
    
    public init(result: DecisionResult,
                indent: Int,            // really recursion level
                newMethodLevel: Int,    // how far we recurse before making a new method
                bucketCount: Int)       // how many buckets does the histogram have?
    {
        self.result = result
        self.indent = indent
        self.newMethodLevel = newMethodLevel

        var maxValue = -10000000000.0
        var _minValue = 10000000000.0

        var positiveValues: [Double] = [] // values for this result.type that are positive test data
        var negativeValues: [Double] = [] // values for this result.type that are negative test data

        for featureData in result.lessThanPositive {
            let value = featureData.decisionTreeValue(for: result.type)
            positiveValues.append(value)
            if value < _minValue { _minValue = value }
            if value > maxValue { maxValue = value }
        }
        for featureData in result.greaterThanPositive {
            let value = featureData.decisionTreeValue(for: result.type)
            positiveValues.append(value)
            if value < _minValue { _minValue = value }
            if value > maxValue { maxValue = value }
        }
        for featureData in result.lessThanNegative {
            let value = featureData.decisionTreeValue(for: result.type)
            negativeValues.append(value)
            if value < _minValue { _minValue = value }
            if value > maxValue { maxValue = value }
        }
        for featureData in result.greaterThanNegative {
            let value = featureData.decisionTreeValue(for: result.type)
            negativeValues.append(value)
            if value < _minValue { _minValue = value }
            if value > maxValue { maxValue = value }
        }

        Log.d("for \(result.type) have \(positiveValues.count) \(negativeValues.count) minValue \(_minValue) maxValue \(maxValue) result.greaterThanPositive \(result.greaterThanPositive.count) result.greaterThanNegative \(result.greaterThanNegative.count) result.lessThanPositive \(result.lessThanPositive.count) result.lessThanNegative \(result.lessThanNegative.count)")
       
        // calculate the size of each histogram bucket

        self.bucketSize = (maxValue - _minValue)/Double(bucketCount)

        var _histogramValues = [Double](repeating: 0, count: bucketCount)

        var largestValue: Double = 0
        
        for i in 0..<bucketCount {
            let bucketStart = _minValue + Double(i)*bucketSize
            let bucketEnd = bucketStart+bucketSize
            var positiveBucketValueCount = 0 
            var negativeBucketValueCount = 0 
            
            for positiveValue in positiveValues {
                if positiveValue >= bucketStart,
                   positiveValue <= bucketEnd
                {
                    positiveBucketValueCount += 1
                }
            }

            for negativeValue in negativeValues {
                if negativeValue >= bucketStart,
                   negativeValue <= bucketEnd
                {
                    negativeBucketValueCount += 1
                }
            }

            var fractionPositive: Double = 0
            if positiveValues.count != 0 {
                fractionPositive = Double(positiveBucketValueCount)/Double(positiveValues.count)
            }            
            var fractionNegative: Double = 0
            if negativeValues.count != 0 {
                fractionNegative = Double(negativeBucketValueCount)/Double(negativeValues.count)
            }
            
            //  1 if all positive values were in this bucket, and no negative
            // -1 if all negative values were in this bucket, and no positive
            //  0 if the same fraction of postiive and negative (wheighted by total count) are equal

            let bucketValue = fractionPositive - fractionNegative
            
            _histogramValues[i] = bucketValue

            Log.d("for \(result.type)[\(i)] = \(bucketValue) - positiveValues.count \(positiveValues.count) negativeValues.count \(negativeValues.count) fractionPositive \(fractionPositive) fractionNegative \(fractionNegative) positiveBucketValueCount \(positiveBucketValueCount) negativeBucketValueCount \(negativeBucketValueCount)")

            let absBucketValue = abs(bucketValue)
              
            if absBucketValue > largestValue { largestValue = absBucketValue }
        }

        // normalize values so the largest value is at -1 or 1
        if largestValue != 0 {
            self.histogramValues = _histogramValues.map { $0 * 1/largestValue }
        } else {
            self.histogramValues = _histogramValues
        }
        self.minValue = _minValue
    }

    // runtime execution

    private func histogramResult(for value: Double) -> Double {
        let start = value - minValue
        if start < 0 { return histogramValues[0] }
        let index = Int(floor(start/bucketSize))
        if index >= histogramValues.count { return histogramValues[histogramValues.count-1] }
        return histogramValues[index]
    }
    
    func classification(of group: ClassifiableOutlierGroup) async -> Double {
        histogramResult(for: group.decisionTreeValue(for: result.type))
    }

    func classification
      (
        of features: [OutlierGroupFeature], // parallel
        and values: [Double]                 // arrays
      ) async -> Double
    {
        for i in 0 ..< features.count {
            if features[i] == result.type {
                return histogramResult(for: values[i])
            }
        }
        return 0
    }

    // write swift code to do the same thing
    var swiftCode: (String, [SwiftDecisionSubtree]) {
        var indentation = ""
        for _ in 0..<initialIndent+(indent % newMethodLevel) { indentation += "    " }
        
        var specialIndentation = ""
        for _ in 0..<initialIndent+newMethodLevel { specialIndentation += "    " }
        
        var methodCallString = "group.decisionTreeValue"
        
        if result.type.isAsync {
            methodCallString = "await group.decisionTreeValueAsync"
        }

        var histogramString = "let histogramValues = ["

        for i in 0..<histogramValues.count-1 {
            histogramString += "\(histogramValues[i]), "
        }
        histogramString += "\(histogramValues[histogramValues.count-1])]"
        
        let swift = """
          \(indentation)// Stumped with Histogram of \(result.type) values in \(histogramValues.count) buckets
          \(indentation)let value = \(methodCallString)(for: .\(result.type))
          \(indentation)let minValue = \(self.minValue)
          \(indentation)let bucketSize = \(self.bucketSize)
          \(indentation)\(histogramString)

          \(indentation)let start = value - minValue
          \(indentation)if start < 0 { return histogramValues[0] }
          \(indentation)let index = Int(floor(start/bucketSize))
          \(indentation)if index >= histogramValues.count { return histogramValues[histogramValues.count-1] }
          \(indentation)return histogramValues[index]
          """
        return (swift, [])
    }
}



