import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/*

 problems:

  - line split on real lines can split them when it shoudln't
 
 */

// load and process all blobs for a frame, using a defined sequence of steps
public class CustomBlobProcessor: AbstractBlobProcessor {

    public func copySteps(from other: AbstractBlobProcessor) {
        self.steps = other.steps
    }

    public func doubleUpdate<T>(_ argsToUpdate: any Argable<T>, _ argType: T, _ value: Double, _ stepIndex: Int) {
        print("doubleUpdate args \(argsToUpdate) argType \(argType) value \(value) index \(index)")
        let currentStep = steps[stepIndex]
        switch currentStep {
        case .findBlobs(let args):
            if let argsToUpdate = argsToUpdate as? BlobFinder.Args,
               let argType = argType as? BlobFinder.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .findBlobs(updatedArgs)
            }
            
        case .process(let functionType):
            break
            
        case .smallBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? SmallBlobRemover.Args,
               let argType = argType as? SmallBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .smallBlobRemover(updatedArgs)
            }
    
        case .smallDimBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? SmallDimBlobRemover.Args,
               let argType = argType as? SmallDimBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .smallDimBlobRemover(updatedArgs)
            }
  
        case .blobDupeCheck(let step):
            break

        case .lineSplit(let args):
            if let argsToUpdate = argsToUpdate as? BlobLineSplitter.Args,
               let argType = argType as? BlobLineSplitter.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .lineSplit(updatedArgs)
            }

        case .borderBrightnessBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? BorderBrightnessBlobRemover.Args,
               let argType = argType as? BorderBrightnessBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .borderBrightnessBlobRemover(updatedArgs)
            }

        case .linearBlobConnector(let args):
            if let argsToUpdate = argsToUpdate as? LinearBlobConnector.Args,
               let argType = argType as? LinearBlobConnector.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .linearBlobConnector(updatedArgs)
            }

        case .blobLineTrim(let args):
            if let argsToUpdate = argsToUpdate as? BlobLineTrim.Args,
               let argType = argType as? BlobLineTrim.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .blobLineTrim(updatedArgs)
            }

        case .isolatedBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? IsolatedBlobRemover.Args,
               let argType = argType as? IsolatedBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .isolatedBlobRemover(updatedArgs)
            }

        case .disconnectedBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? DisconnectedBlobRemover.Args,
               let argType = argType as? DisconnectedBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .disconnectedBlobRemover(updatedArgs)
            }

        case .dimIsolatedBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? DimIsolatedBlobRemover.Args,
               let argType = argType as? DimIsolatedBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .dimIsolatedBlobRemover(updatedArgs)
            }
            
        case .save(let imageType):
            break

        case .frameState(let processingState):
            break

        case .removeReallyBigBlobsWithSmallDimBunches(let args):
            if let argsToUpdate = argsToUpdate as? RemoveReallyBigBlobsWithSmallDimBunches.Args,
               let argType = argType as? RemoveReallyBigBlobsWithSmallDimBunches.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .removeReallyBigBlobsWithSmallDimBunches(updatedArgs)
            }

        case .trimWithConstants(let args):
            if let argsToUpdate = argsToUpdate as? BlobTrimmerWithConstants.Args,
               let argType = argType as? BlobTrimmerWithConstants.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .trimWithConstants(updatedArgs)
            }
        }
    }

    public func intUpdate<T>(_ argsToUpdate: any Argable<T>, _ argType: T, _ value: Int, _ stepIndex: Int) {
        print("intUpdate args \(argsToUpdate) argType \(argType) value \(value) index \(index)")
        let currentStep = steps[stepIndex]
        switch currentStep {
        case .findBlobs(let args):
            if let argsToUpdate = argsToUpdate as? BlobFinder.Args,
               let argType = argType as? BlobFinder.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .findBlobs(updatedArgs)
            }
            
        case .process(let functionType):
            break
            
        case .smallBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? SmallBlobRemover.Args,
               let argType = argType as? SmallBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .smallBlobRemover(updatedArgs)
            }
    
        case .smallDimBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? SmallDimBlobRemover.Args,
               let argType = argType as? SmallDimBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .smallDimBlobRemover(updatedArgs)
            }
  
        case .blobDupeCheck(let step):
            break

        case .lineSplit(let args):
            if let argsToUpdate = argsToUpdate as? BlobLineSplitter.Args,
               let argType = argType as? BlobLineSplitter.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .lineSplit(updatedArgs)
            }

        case .borderBrightnessBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? BorderBrightnessBlobRemover.Args,
               let argType = argType as? BorderBrightnessBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .borderBrightnessBlobRemover(updatedArgs)
            }

        case .linearBlobConnector(let args):
            if let argsToUpdate = argsToUpdate as? LinearBlobConnector.Args,
               let argType = argType as? LinearBlobConnector.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .linearBlobConnector(updatedArgs)
            }

        case .blobLineTrim(let args):
            if let argsToUpdate = argsToUpdate as? BlobLineTrim.Args,
               let argType = argType as? BlobLineTrim.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .blobLineTrim(updatedArgs)
            }

        case .isolatedBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? IsolatedBlobRemover.Args,
               let argType = argType as? IsolatedBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .isolatedBlobRemover(updatedArgs)
            }

        case .disconnectedBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? DisconnectedBlobRemover.Args,
               let argType = argType as? DisconnectedBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .disconnectedBlobRemover(updatedArgs)
            }

        case .dimIsolatedBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? DimIsolatedBlobRemover.Args,
               let argType = argType as? DimIsolatedBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .dimIsolatedBlobRemover(updatedArgs)
            }
            
        case .save(let imageType):
            break

        case .frameState(let processingState):
            break

        case .removeReallyBigBlobsWithSmallDimBunches(let args):
            if let argsToUpdate = argsToUpdate as? RemoveReallyBigBlobsWithSmallDimBunches.Args,
               let argType = argType as? RemoveReallyBigBlobsWithSmallDimBunches.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .removeReallyBigBlobsWithSmallDimBunches(updatedArgs)
            }

        case .trimWithConstants(let args):
            if let argsToUpdate = argsToUpdate as? BlobTrimmerWithConstants.Args,
               let argType = argType as? BlobTrimmerWithConstants.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .trimWithConstants(updatedArgs)
            }
        }
    }
}
