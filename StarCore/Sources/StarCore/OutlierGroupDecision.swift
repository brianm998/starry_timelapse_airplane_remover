import Foundation
import logging

/*
 This OutlierGroup extention contains all of the decision tree specific logic.

 Adding a new case to the Feature and giving a value for it in decisionTreeValue
 is all needed to add a new value to the decision tree criteria
 */

// XXX move these 

// different ways we split up data sets that are still overlapping
public enum DecisionSplitType: String {
    case median
    case mean
    // XXX others ???
}

public var currentClassifier: NamedOutlierGroupClassifier? 

public enum StreakDirection {
    case forwards
    case backwards
}


