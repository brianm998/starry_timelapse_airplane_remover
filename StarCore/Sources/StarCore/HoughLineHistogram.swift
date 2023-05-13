import Foundation

public struct HoughLineHistogram {

    let values: [Double]
    let increment: Int          // degree difference between indexes of values above
        
    init(withDegreeIncrement increment: Int,
         lines: [Line],
         andGroupSize groupSize: UInt) {
        self.increment = increment
        let lines = lines
        var values = Array<Double>(repeating: 0, count: 360/increment)

        for line in lines {
            let index = Int(line.theta/Double(increment))
            values[index] += Double(line.count)/Double(groupSize)
        }

        self.values = values
    }

    func matchScore(with other: HoughLineHistogram) -> Double {
        if self.increment != other.increment { return 0 }

        var ret = 0.0
        
        for (index, value) in values.enumerated() { // died here :(
            let other_value = other.values[index]
            let min = min(value, other_value)
            ret = max(min, ret)
        }
        return ret
    }

    var maxTheta: Double {
        var max_value: Double = 0
        var max_index: Int = 0

        for (index, value) in values.enumerated() {
            if value > max_value {
                max_value = value
                max_index = index
            }
        }
        var ret = Double(max_index*increment)
        if ret > 360 { ret -= 360 }
        return ret
    }
}

