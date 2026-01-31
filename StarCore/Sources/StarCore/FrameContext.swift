import Foundation

public struct FrameContext {
    public let index: Int
//    let remover: FrameAirplaneRemover
    public let neighbors: [Int]

    public init(
      index: Int,
      neighbors: [Int]
    ) {
        self.index = index
        self.neighbors = neighbors
    }
}
