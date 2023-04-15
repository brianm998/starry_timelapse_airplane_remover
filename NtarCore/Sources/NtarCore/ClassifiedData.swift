import Foundation

// outlier feature data which is classified for structured learning

@available(macOS 10.15, *) 
public class ClassifiedData {
    public init() { }

    public init(positive_data: [OutlierFeatureData],
                negative_data: [OutlierFeatureData])
    {
        self.positive_data = positive_data
        self.negative_data = negative_data
    }

    public var positive_data: [OutlierFeatureData] = []
    public var negative_data: [OutlierFeatureData] = []

    public static func +=(lhs: ClassifiedData, rhs: ClassifiedData) {
        lhs.positive_data += rhs.positive_data
        lhs.negative_data += rhs.negative_data
    }

    public var size: Int { positive_data.count + negative_data.count }

    // splits data into groups splitting part of each set of input group into each output group
    public func shuffleSplit(into number_of_groups: Int) -> [ClassifiedData] {
        var positive_data_arr = [[OutlierFeatureData]](repeating: [], count: number_of_groups)
        var negative_data_arr = [[OutlierFeatureData]](repeating: [], count: number_of_groups)
        var positive_index = 0
        var negative_index = 0
        for i in 0..<positive_data.count {
            positive_data_arr[positive_index].append(positive_data[i])
            positive_index += 1
            if positive_index >= positive_data_arr.count { positive_index = 0 }
        }
        for i in 0..<negative_data.count {
            negative_data_arr[negative_index].append(negative_data[i])
            negative_index += 1
            if negative_index >= negative_data_arr.count { negative_index = 0 }
        }
        var ret: [ClassifiedData] = []
        for i in 0..<number_of_groups {
            ret.append(ClassifiedData(positive_data: positive_data_arr[i],
                                      negative_data: negative_data_arr[i]))
        }
        return ret
    }
    
    public func split(into number_of_groups: Int) -> [ClassifiedData] {
        // chunk the positive and negative data

        var real_number_of_groups = number_of_groups
        
        if positive_data.count < real_number_of_groups {
            real_number_of_groups = positive_data.count
        }
        
        if negative_data.count < real_number_of_groups {
            real_number_of_groups = negative_data.count
        }

        Log.i("splitting into \(real_number_of_groups) groups")
        let positive_chunks = positive_data.chunks(of: positive_data.count/real_number_of_groups)
        let negative_chunks = negative_data.chunks(of: negative_data.count/real_number_of_groups)

        // XXX these need to match up in length
        
        Log.i("got \(positive_chunks.count) positive_chunks and \(negative_chunks.count) negative_chunks")
        
        // assemble them together
        var ret: [ClassifiedData] = []
        for i in 0..<real_number_of_groups-1 {
            ret.append(ClassifiedData(positive_data: positive_chunks[i],
                                      negative_data: negative_chunks[i]))
        }

        // glomb any remaning groups togther in one
        var last_positive_data: [OutlierFeatureData] = []
        var last_negative_data: [OutlierFeatureData] = []
        for i in real_number_of_groups-1..<positive_chunks.count {
            last_positive_data += positive_chunks[i]
        }
        for i in real_number_of_groups-1..<negative_chunks.count {
            last_negative_data += negative_chunks[i]
        }
        let last = ClassifiedData(positive_data: last_positive_data,
                                  negative_data: last_negative_data)
        ret.append(last)
        return ret
    }
}

@available(macOS 10.15, *)
extension Array {
    // splits array into some number of chunks of the given size
    func chunks(of size: Int) -> [[Element]] {
        if size == 0 { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
