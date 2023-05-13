import Foundation

// outlier feature data which is classified for structured learning

public class ClassifiedData {
    public init() { }

    public init(positiveData: [OutlierFeatureData],
                negativeData: [OutlierFeatureData])
    {
        self.positiveData = positiveData
        self.negativeData = negativeData
    }

    public var positiveData: [OutlierFeatureData] = []
    public var negativeData: [OutlierFeatureData] = []

    public static func +=(lhs: ClassifiedData, rhs: ClassifiedData) {
        lhs.positiveData += rhs.positiveData
        lhs.negativeData += rhs.negativeData
    }

    public var count: Int { positiveData.count + negativeData.count }

    // splits data into groups splitting part of each set of input group into each output group
    public func shuffleSplit(into number_of_groups: Int) -> [ClassifiedData] {
        var positiveData_arr = [[OutlierFeatureData]](repeating: [], count: number_of_groups)
        var negativeData_arr = [[OutlierFeatureData]](repeating: [], count: number_of_groups)
        var positive_index = 0
        var negative_index = 0
        for i in 0..<positiveData.count {
            positiveData_arr[positive_index].append(positiveData[i])
            positive_index += 1
            if positive_index >= positiveData_arr.count { positive_index = 0 }
        }
        for i in 0..<negativeData.count {
            negativeData_arr[negative_index].append(negativeData[i])
            negative_index += 1
            if negative_index >= negativeData_arr.count { negative_index = 0 }
        }
        var ret: [ClassifiedData] = []
        for i in 0..<number_of_groups {
            ret.append(ClassifiedData(positiveData: positiveData_arr[i],
                                      negativeData: negativeData_arr[i]))
        }
        return ret
    }
    
    public func split(into number_of_groups: Int) -> [ClassifiedData] {
        // chunk the positive and negative data

        var real_number_of_groups = number_of_groups
        
        if positiveData.count < real_number_of_groups {
            real_number_of_groups = positiveData.count
        }
        
        if negativeData.count < real_number_of_groups {
            real_number_of_groups = negativeData.count
        }

        Log.i("splitting into \(real_number_of_groups) groups")
        let positive_chunks = positiveData.chunks(of: positiveData.count/real_number_of_groups)
        let negative_chunks = negativeData.chunks(of: negativeData.count/real_number_of_groups)

        // XXX these need to match up in length
        
        Log.i("got \(positive_chunks.count) positive_chunks and \(negative_chunks.count) negative_chunks")
        
        // assemble them together
        var ret: [ClassifiedData] = []
        for i in 0..<real_number_of_groups-1 {
            ret.append(ClassifiedData(positiveData: positive_chunks[i],
                                      negativeData: negative_chunks[i]))
        }

        // glomb any remaning groups togther in one
        var last_positiveData: [OutlierFeatureData] = []
        var last_negativeData: [OutlierFeatureData] = []
        for i in real_number_of_groups-1..<positive_chunks.count {
            last_positiveData += positive_chunks[i]
        }
        for i in real_number_of_groups-1..<negative_chunks.count {
            last_negativeData += negative_chunks[i]
        }
        let last = ClassifiedData(positiveData: last_positiveData,
                                  negativeData: last_negativeData)
        ret.append(last)
        return ret
    }
}

extension Array {
    // splits array into some number of chunks of the given size
    func chunks(of size: Int) -> [[Element]] {
        if size == 0 { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
