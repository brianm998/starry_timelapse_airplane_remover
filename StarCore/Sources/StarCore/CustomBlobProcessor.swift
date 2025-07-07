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

    private var shouldDisable: [Bool]?
    
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

    override internal func shouldRunStep(atIndex index: Int) -> Bool {
        if let shouldDisable {
            if index >= 0,
               index < shouldDisable.count
            {
                Log.d("shouldRunStep \(index) !\(shouldDisable[index])")
                return !shouldDisable[index]
            } else {
                return true
            }
        } else {
            return true
        }
    }
    
    private func readStepsFromFile() throws {
        let config_url = NSURL(fileURLWithPath: self.jsonFilename, isDirectory: false) as URL
        let config_data = try Data(contentsOf: config_url)
        let decoder = JSONDecoder()
        self.steps = try decoder.decode([BlobProcessingType].self, from: config_data)
    }
    
    private var jsonFilename: String {
        var filename = ".star_custom_processor_steps.json"
        let env = ProcessInfo.processInfo.environment
        if let homedir = env["HOME"] {
            return "\(homedir)/\(filename)"
        } else {
            // with no homedir, put it in tmp?
            return "/tmp/\(filename)"
        }
    }

    public func shouldDisable<T>(_ argsToUpdate: any Argable<T>, _ value: Bool, _ stepIndex: Int) {
        var local: [Bool] = []
        if let shouldDisable {
            local = shouldDisable
        } else {
            local = [Bool](repeating: false, count: self.steps.count)
        }
        if stepIndex >= 0,
           stepIndex < local.count
        {
            local[stepIndex] = value
            shouldDisable = local
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
        case .compactBlobIds:
            break
            
        case .findBlobs(let args):
            if let argType = argType as? BlobFinder.Args.ArgType,
               let updatedArgs = args.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .findBlobs(updatedArgs)
                saveStepsToFile()
            }
            
        case .applyUserSlices:
            break
            
        case .smallBlobRemover(let args):
            if let argType = argType as? SmallBlobRemover.Args.ArgType,
               let updatedArgs = args.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .smallBlobRemover(updatedArgs)
                saveStepsToFile()
            }

        case .blobDupeCheck(_):
            break

        case .linearBlobConnector(let args):
            if let argType = argType as? LinearBlobConnector.Args.ArgType,
               let updatedArgs = args.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .linearBlobConnector(updatedArgs)
                saveStepsToFile()
            }

        case .linearBlobExtender(let args):
            if let argType = argType as? LinearBlobExtender.Args.ArgType,
               let updatedArgs = args.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .linearBlobExtender(updatedArgs)
                saveStepsToFile()
            }

        case .blobLineTrim(let args):
            if let argType = argType as? BlobLineTrim.Args.ArgType,
               let updatedArgs = args.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .blobLineTrim(updatedArgs)
                saveStepsToFile()
            }

        case .save(_):
            break

        case .frameState(_):
            break

        case .houghLineMatrixBlobConnector(let args):
            if let argType = argType as? HoughLineMatrixBlobConnector.Args.ArgType,
               let updatedArgs = args.doubleUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .houghLineMatrixBlobConnector(updatedArgs)
                saveStepsToFile()
            }
        }
    }

    public func intUpdate<T>(_ argsToUpdate: any Argable<T>, _ argType: T, _ value: Int, _ stepIndex: Int) {
        print("intUpdate args \(argsToUpdate) argType \(argType) value \(value) index \(index)")
        let currentStep = steps[stepIndex]
        switch currentStep {
        case .compactBlobIds:
            break
            
        case .findBlobs(let args):
            if let argType = argType as? BlobFinder.Args.ArgType,
               let updatedArgs = args.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .findBlobs(updatedArgs)
                saveStepsToFile()
            }
            
        case .applyUserSlices:
            break
  
        case .smallBlobRemover(let args):
            if let argType = argType as? SmallBlobRemover.Args.ArgType,
               let updatedArgs = args.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .smallBlobRemover(updatedArgs)
                saveStepsToFile()
            }
            
        case .blobDupeCheck(_):
            break

        case .linearBlobConnector(let args):
            if let argType = argType as? LinearBlobConnector.Args.ArgType,
               let updatedArgs = args.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .linearBlobConnector(updatedArgs)
                saveStepsToFile()
            }

        case .linearBlobExtender(let args):
            if let argType = argType as? LinearBlobExtender.Args.ArgType,
               let updatedArgs = args.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .linearBlobExtender(updatedArgs)
                saveStepsToFile()
            }

        case .blobLineTrim(let args):
            if let argType = argType as? BlobLineTrim.Args.ArgType,
               let updatedArgs = args.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .blobLineTrim(updatedArgs)
                saveStepsToFile()
            }

        case .save(_):
            break

        case .frameState(_):
            break

        case .houghLineMatrixBlobConnector(let args):
            if let argType = argType as? HoughLineMatrixBlobConnector.Args.ArgType,
               let updatedArgs = args.intUpdate(for: argType, value: value)
            {
                steps[stepIndex] = .houghLineMatrixBlobConnector(updatedArgs)
                saveStepsToFile()
            }
        }
    }
}
