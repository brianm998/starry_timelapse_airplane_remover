import Foundation

// results for multiple trees indexed by name

class TreeTestResults: @unchecked Sendable {
    var numberGood: [String:Int] = [:]
    var numberBad: [String:Int] = [:]

    public init() { }
    public init(numberGood: [String:Int],
                numberBad: [String:Int])
    {
        self.numberGood = numberGood
        self.numberBad = numberBad
    }
}

