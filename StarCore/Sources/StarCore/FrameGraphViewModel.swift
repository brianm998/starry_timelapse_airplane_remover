import Foundation
#if canImport(Observation)
import Observation
#endif

@MainActor
public let frameGraphViewModel = FrameGraphViewModel()

@MainActor
#if canImport(Observation)
@Observable
#endif
public final class FrameGraphViewModel {

    public var operations: [OperationType: [OperationState: UInt]] = [:]

    /// How many frame graphs have finished being assembled since the sequence was opened.
    ///
    /// `operations` below is filled in as `FrameGraphBuilder` constructs each op, one type
    /// at a time in dependency order, so a type with no operations yet may simply not have
    /// been reached — which is a different thing from a type with nothing to do, and the
    /// two are indistinguishable from the counts alone.  A caller that snapshots this when
    /// its run starts can tell them apart: until the number moves, the plan is still being
    /// worked out.
    ///
    /// Bumped by `build` only, not by `enqueueHorizonRefinement`: a refinement assembles
    /// its own small graph, and letting that count would tell a run in progress that its
    /// plan was final when it was not.
    public private(set) var graphBuildsCompleted: Int = 0

    public func finishedBuildingGraph() {
        graphBuildsCompleted += 1
    }

    public var numberOfFramesProcessingNow: Int {
        var ret = 0
        for type in OperationType.allCases {
          ret += Int(self.numberOfOperations(ofType: type, in: .running))
        }
        return ret
    }
    
    public func numberOfOperations(
      ofType type: OperationType,
      in state: OperationState
    ) -> UInt {
        if let states = operations[type],
           let count = states[state]
        {
            count
        } else {
            0
        }
    }

    public func hasOperations(ofType type: OperationType, atMax max: Int? = nil) -> Bool {
        if let states = operations[type] {
            if let max {
                if let numberDone = states[.done],
                   numberDone == max
                {
                    return false
                } else if let numberQueued = states[.queued],
                          numberQueued == max
                {
                    return false
                }
            } 
            var number: UInt = 0
            for count in states.values {
                number += count
            }
            return number != 0
        } else {
            return false
        }
    }
    
    public func reset() {
        operations = [:]
        graphBuildsCompleted = 0
    }

    public func queuedOperation(ofType type: OperationType) {
        addition(ofType: type, to: .queued)
    }
    
    public func runningOperation(ofType type: OperationType) {
        removal(ofType: type, from: .queued)
        addition(ofType: type, to: .running)
    }
    
    public func doneWithOperation(ofType type: OperationType) {
        removal(ofType: type, from: .running)
        addition(ofType: type, to: .done)
    }

    private func addition(ofType type: OperationType, to state: OperationState) {
        if var states = operations[type] {
            if let numQueued = states[state] {
                states[state] = numQueued+1
            } else {
                states[state] = 1
            }
            operations[type] = states
        } else {
            // make new empty list
            operations[type] = [state: 1]
        }
    }
    
    private func removal(ofType type: OperationType, from state: OperationState) {
        if var states = operations[type] {
            if let numQueued = states[state],
               numQueued > 0
            {
                states[state] = numQueued-1
            } else {
                states[state] = 0
            }
            operations[type] = states
        } else {
            // make new empty list
            operations[type] = [state: 0]
        }
    }
}

