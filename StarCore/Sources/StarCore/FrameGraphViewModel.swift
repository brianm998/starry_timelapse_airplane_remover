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

