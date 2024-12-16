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

    public override init() {
        super.init()
        do {
            try self.readStepsFromFile()
        } catch {
            Log.e("couldn't read steps from file: \(error)")
        }
    }

    private func readStepsFromFile() throws {
        let config_url = NSURL(fileURLWithPath: self.jsonFilename, isDirectory: false) as URL
        let config_data = try Data(contentsOf: config_url)
        let decoder = JSONDecoder()
        self.steps = try decoder.decode([BlobProcessingType].self, from: config_data)
    }
    
    private var jsonFilename: String {
        var filename = "star_custom_processor_steps.json"
        let env = ProcessInfo.processInfo.environment
        if let homedir = env["HOME"] {
            return "\(homedir)/\(filename)"
        } else {
            // with no homedir, put it in tmp?
            return "/tmp/\(filename)"
        }
    }

    public func saveStepsToFile() {

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]

        let fullPath = self.jsonFilename

        do {
            let jsonData = try encoder.encode(self.steps)

            if FileManager.default.fileExists(atPath: fullPath) {
                try FileManager.default.removeItem(atPath: fullPath)
            }
            
            Log.i("creating \(fullPath)")                      
            FileManager.default.createFile(atPath: fullPath, contents: jsonData, attributes: nil)
            Log.i("created \(fullPath)")                      
            
        } catch {
            Log.e("failed to create \(fullPath): \(error)")
        }
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
                saveStepsToFile()
            }
            
        case .applyUserSlices:
           break
            
        case .smallBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? SmallBlobRemover.Args,
               let argType = argType as? SmallBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .smallBlobRemover(updatedArgs)
                saveStepsToFile()
            }
    
        case .smallDimBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? SmallDimBlobRemover.Args,
               let argType = argType as? SmallDimBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .smallDimBlobRemover(updatedArgs)
                saveStepsToFile()
            }
  
        case .blobDupeCheck(let step):
            break

        case .lineSplit(let args):
            if let argsToUpdate = argsToUpdate as? BlobLineSplitter.Args,
               let argType = argType as? BlobLineSplitter.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .lineSplit(updatedArgs)
                saveStepsToFile()
            }

        case .borderBrightnessBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? BorderBrightnessBlobRemover.Args,
               let argType = argType as? BorderBrightnessBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .borderBrightnessBlobRemover(updatedArgs)
                saveStepsToFile()
            }

        case .linearBlobConnector(let args):
            if let argsToUpdate = argsToUpdate as? LinearBlobConnector.Args,
               let argType = argType as? LinearBlobConnector.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .linearBlobConnector(updatedArgs)
                saveStepsToFile()
            }

        case .blobLineTrim(let args):
            if let argsToUpdate = argsToUpdate as? BlobLineTrim.Args,
               let argType = argType as? BlobLineTrim.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .blobLineTrim(updatedArgs)
                saveStepsToFile()
            }

        case .isolatedBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? IsolatedBlobRemover.Args,
               let argType = argType as? IsolatedBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .isolatedBlobRemover(updatedArgs)
                saveStepsToFile()
            }

        case .disconnectedBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? DisconnectedBlobRemover.Args,
               let argType = argType as? DisconnectedBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .disconnectedBlobRemover(updatedArgs)
                saveStepsToFile()
            }

        case .dimIsolatedBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? DimIsolatedBlobRemover.Args,
               let argType = argType as? DimIsolatedBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .dimIsolatedBlobRemover(updatedArgs)
                saveStepsToFile()
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
                saveStepsToFile()
            }

        case .trimWithConstants(let args):
            if let argsToUpdate = argsToUpdate as? BlobTrimmerWithConstants.Args,
               let argType = argType as? BlobTrimmerWithConstants.Args.ArgType,
               let updatedArgs = argsToUpdate.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .trimWithConstants(updatedArgs)
                saveStepsToFile()
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
                saveStepsToFile()
            }
            
        case .applyUserSlices:
            break
            
        case .smallBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? SmallBlobRemover.Args,
               let argType = argType as? SmallBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .smallBlobRemover(updatedArgs)
                saveStepsToFile()
            }
    
        case .smallDimBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? SmallDimBlobRemover.Args,
               let argType = argType as? SmallDimBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .smallDimBlobRemover(updatedArgs)
                saveStepsToFile()
            }
  
        case .blobDupeCheck(let step):
            break

        case .lineSplit(let args):
            if let argsToUpdate = argsToUpdate as? BlobLineSplitter.Args,
               let argType = argType as? BlobLineSplitter.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .lineSplit(updatedArgs)
                saveStepsToFile()
            }

        case .borderBrightnessBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? BorderBrightnessBlobRemover.Args,
               let argType = argType as? BorderBrightnessBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .borderBrightnessBlobRemover(updatedArgs)
                saveStepsToFile()
            }

        case .linearBlobConnector(let args):
            if let argsToUpdate = argsToUpdate as? LinearBlobConnector.Args,
               let argType = argType as? LinearBlobConnector.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .linearBlobConnector(updatedArgs)
                saveStepsToFile()
            }

        case .blobLineTrim(let args):
            if let argsToUpdate = argsToUpdate as? BlobLineTrim.Args,
               let argType = argType as? BlobLineTrim.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .blobLineTrim(updatedArgs)
                saveStepsToFile()
            }

        case .isolatedBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? IsolatedBlobRemover.Args,
               let argType = argType as? IsolatedBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .isolatedBlobRemover(updatedArgs)
                saveStepsToFile()
            }

        case .disconnectedBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? DisconnectedBlobRemover.Args,
               let argType = argType as? DisconnectedBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .disconnectedBlobRemover(updatedArgs)
                saveStepsToFile()
            }

        case .dimIsolatedBlobRemover(let args):
            if let argsToUpdate = argsToUpdate as? DimIsolatedBlobRemover.Args,
               let argType = argType as? DimIsolatedBlobRemover.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .dimIsolatedBlobRemover(updatedArgs)
                saveStepsToFile()
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
                saveStepsToFile()
            }

        case .trimWithConstants(let args):
            if let argsToUpdate = argsToUpdate as? BlobTrimmerWithConstants.Args,
               let argType = argType as? BlobTrimmerWithConstants.Args.ArgType,
               let updatedArgs = argsToUpdate.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .trimWithConstants(updatedArgs)
                saveStepsToFile()
            }
        }
    }
}
