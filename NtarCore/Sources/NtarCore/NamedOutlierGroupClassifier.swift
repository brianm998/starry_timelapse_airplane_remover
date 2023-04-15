import Foundation

// a classifier that has a name and can be instantiated
@available(macOS 10.15, *)
public protocol NamedOutlierGroupClassifier: OutlierGroupClassifier {

    init()
    
    var name: String { get }
}

