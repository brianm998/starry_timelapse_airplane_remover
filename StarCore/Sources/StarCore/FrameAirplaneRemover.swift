import Foundation
import CoreGraphics
import Cocoa

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// this class holds the logic for removing airplanes from a single frame

// the first pass is done upon init, finding and pruning outlier groups

public enum LoopReturn {
    case `continue`
    case `break`
}

public enum FrameProcessingState: Int, CaseIterable, Codable {
    case unprocessed
    case loadingImages    
    case detectingOutliers
    case readyForInterFrameProcessing
    case interFrameProcessing
    case outlierProcessingComplete
    // XXX add gui check step?
    case reloadingImages
    case painting
    case writingOutputFile
    case complete
}

public class FrameAirplaneRemover: Equatable, Hashable {

    private var state: FrameProcessingState = .unprocessed {
        willSet {
            if let frameStateChangeCallback = self.callbacks.frameStateChangeCallback {
                frameStateChangeCallback(self, newValue)
            }
        }
    }

    public func processingState() -> FrameProcessingState { return state }
    
    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(frameIndex)
    }
    
    func set(state: FrameProcessingState) { self.state = state }
    
    nonisolated public let width: Int
    nonisolated public let height: Int
    public let bytesPerPixel: Int
    public let bytesPerRow: Int
    public let otherFrameIndexes: [Int] // used in found outliers and paint only
    nonisolated public let frameIndex: Int

    public let outlierOutputDirname: String?
    public let previewOutputDirname: String?
    public let processedPreviewOutputDirname: String?
    public let thumbnailOutputDirname: String?

    // populated by pruning
    public var outlierGroups: OutlierGroups?

    private var didChange = false

    public func changesHandled() { didChange = false }
    
    public func markAsChanged() { didChange = true }

    public func hasChanges() -> Bool { return didChange }
    
    public func outlierGroupList() -> [OutlierGroup]? {
        if let outlierGroups = outlierGroups {
            let groups = outlierGroups.members
            return groups.map {$0.value}
        }
        return nil
    }

    public func outlierGroups(within distance: Double, of boundingBox: BoundingBox) -> [OutlierGroup]? {
        if let outlierGroups = outlierGroups {
            let groups = outlierGroups.members
            var ret: [OutlierGroup] = []
            for (_, group) in groups {
                if group.bounds.centerDistance(to: boundingBox) < distance {
                    ret.append(group)
                }
            }
            return ret
        }
        return nil
    }
    
    var previewSize: NSSize {
        let previewWidth = config.previewWidth
        let previewHeight = config.previewHeight
        return NSSize(width: previewWidth, height: previewHeight)
    }
    
    public func writePreviewFile(_ image: NSImage) {
        Log.d("frame \(self.frameIndex) doing preview")
        if config.writeFramePreviewFiles,
           let filename = self.previewFilename
        {
            if file_manager.fileExists(atPath: filename) {
                Log.i("not overwriting already existing preview \(filename)")
                return
            }
            
            Log.d("frame \(self.frameIndex) doing preview")

            if let scaledImage = image.resized(to: self.previewSize),
               let imageData = scaledImage.jpegData
            {
                // write to file
                file_manager.createFile(atPath: filename,
                                     contents: imageData,
                                     attributes: nil)
                Log.i("frame \(self.frameIndex) wrote preview to \(filename)")
            } else {
                Log.w("frame \(self.frameIndex) WTF")
            }
        } else {
            Log.d("frame \(self.frameIndex) no config")
        }
    }

    public func writeThumbnailFile(_ image: NSImage) {
        Log.d("frame \(self.frameIndex) doing preview")
        if config.writeFrameThumbnailFiles,
           let filename = self.thumbnailFilename
        {
            if file_manager.fileExists(atPath: filename) {
                Log.i("not overwriting already existing thumbnail filename \(filename)")
                return
            }

            Log.d("frame \(self.frameIndex) doing thumbnail")
            let thumbnailWidth = config.thumbnailWidth
            let thumbnailHeight = config.thumbnailHeight
            let thumbnailSize = NSSize(width: thumbnailWidth, height: thumbnailHeight)
            
            if let scaledImage = image.resized(to: thumbnailSize),
               let imageData = scaledImage.jpegData
            {
                // write to file
                file_manager.createFile(atPath: filename,
                                     contents: imageData,
                                     attributes: nil)
                Log.i("frame \(self.frameIndex) wrote thumbnail to \(filename)")
            } else {
                Log.w("frame \(self.frameIndex) WTF")
            }
        } else {
            Log.d("frame \(self.frameIndex) no config")
        }
    }

    // write out just the OutlierGroupValueMatrix, which just what
    // the decision tree needs, and not very large
    public func writeOutlierValuesCSV() async throws {
        if config.writeOutlierGroupFiles,
           let outputDirname = self.outlierOutputDirname
        {
            // write out the decision tree value matrix too

            let valueMatrix = OutlierGroupValueMatrix()

            if let outliers = self.outlierGroupList() {
                for outlier in outliers {
                    await valueMatrix.append(outlierGroup: outlier)
                }
            }

            try valueMatrix.writeCSV(to: "\(outputDirname)/\(self.frameIndex)")
        }
    }

    // write out a directory of individual OutlierGroup binaries
    // for each outlier in this frame
    // large, still not fast, but lots of data
    public func writeOutliersBinary() async {
        if config.writeOutlierGroupFiles,
           let outputDirname = self.outlierOutputDirname
        {
            do {
                try await self.outlierGroups?.write(to: outputDirname)
            } catch {
                Log.e("error \(error)")
            }                
        }
    }
    
    public func userSelectAllOutliers(toShouldPaint shouldPaint: Bool,
                                  between startLocation: CGPoint,
                                  and endLocation: CGPoint) async
    {
        await foreachOutlierGroup(between: startLocation, and: endLocation) { group in
            await group.shouldPaint(.userSelected(shouldPaint))
            return .continue
        }
    }

    public func applyDecisionTreeToAutoSelectedOutliers() async {
        if let classifier = currentClassifier {
            await withLimitedTaskGroup(of: Void.self) { taskGroup in
                await foreachOutlierGroup() { group in
                    await taskGroup.addTask() {
                        var apply = true
                        if let shouldPaint = group.shouldPaint {
                            switch shouldPaint {
                            case .userSelected(_):
                                // leave user selected ones in place
                                apply = false
                            default:
                                break
                            }
                        }
                        if apply {
                            Log.d("applying decision tree")
                            let score = await classifier.classification(of: group)
                            await group.shouldPaint(.fromClassifier(score))
                        }
                    }
                    return .continue
                }
                await taskGroup.waitForAll()
            }
        } else {
            Log.w("no classifier")
        }
    }

    public func clearOutlierGroupValueCaches() async {
        await foreachOutlierGroup() { group in
            group.clearFeatureValueCache()
            return .continue
        }
    }

    public func applyDecisionTreeToAllOutliers() async {
        Log.d("frame \(self.frameIndex) applyDecisionTreeToAllOutliers")
        if let classifier = currentClassifier {
            let startTime = NSDate().timeIntervalSince1970
            await withLimitedTaskGroup(of: Void.self) { taskGroup in
                await foreachOutlierGroup() { group in
                    await taskGroup.addTask() {
                        let score = await classifier.classification(of: group)
                        //Log.d("frame \(self.frameIndex) applying classifier shouldPaint \(score)")
                        await group.shouldPaint(.fromClassifier(score))
                    }
                    return .continue
                }
                await taskGroup.waitForAll()
            }
            let endTime = NSDate().timeIntervalSince1970
            Log.i("frame \(self.frameIndex) spent \(endTime - startTime) seconds classifing outlier groups");
        } else {
            Log.w("no classifier")
        }
        Log.d("frame \(self.frameIndex) DONE applyDecisionTreeToAllOutliers")
    }
    
    public func userSelectAllOutliers(toShouldPaint shouldPaint: Bool) async {
        await foreachOutlierGroup() { group in
            await group.shouldPaint(.userSelected(shouldPaint))
            return .continue
        }
    }
    
    var outlierGroupCount: Int { return outlierGroups?.members.count ?? 0 }
    
    public let outputFilename: String

    public let imageSequence: ImageSequence

    public let config: Config
    public let callbacks: Callbacks

    public let base_name: String

    // did we load our outliers from a file?
    private var outliersLoadedFromFile = false

    public func maybeApplyOutlierGroupClassifier() async {
        if !self.outliersLoadedFromFile {
            self.set(state: .interFrameProcessing)
            await self.applyDecisionTreeToAllOutliers()
        }
    }
    
    public func didLoadOutliersFromFile() -> Bool { outliersLoadedFromFile }
    
    nonisolated public var previewFilename: String? {
        if let previewOutputDirname = previewOutputDirname {
            return "\(previewOutputDirname)/\(base_name).jpg" // XXX this makes it .tif.jpg
        }
        return nil
    }
    
    nonisolated public var processedPreviewFilename: String? {
        if let processedPreviewOutputDirname = processedPreviewOutputDirname {
            return "\(processedPreviewOutputDirname)/\(base_name).jpg"
        }
        return nil
    }
    
    nonisolated public var thumbnailFilename: String? {
        if let thumbnailOutputDirname = thumbnailOutputDirname {
            return "\(thumbnailOutputDirname)/\(base_name).jpg"
        }
        return nil
    }

    let outlierGroupLoader: () async -> OutlierGroups?

    // doubly linked list
    var previousFrame: FrameAirplaneRemover?
    var nextFrame: FrameAirplaneRemover?

    func setPreviousFrame(_ frame: FrameAirplaneRemover) {
        previousFrame = frame
    }
    
    func setNextFrame(_ frame: FrameAirplaneRemover) {
        nextFrame = frame
    }
    
    let fully_process: Bool

    // if this is false, just write out outlier data
    let writeOutputFiles: Bool
    
    init(with config: Config,
         width: Int,
         height: Int,
         bytesPerPixel: Int,
         callbacks: Callbacks,
         imageSequence: ImageSequence,
         atIndex frameIndex: Int,
         otherFrameIndexes: [Int],
         outputFilename: String,
         baseName: String,       // source filename without path
         outlierOutputDirname: String?,
         previewOutputDirname: String?,
         processedPreviewOutputDirname: String?,
         thumbnailOutputDirname: String?,
         outlierGroupLoader: @escaping () async -> OutlierGroups?,
         fullyProcess: Bool = true,
         writeOutputFiles: Bool = true) async throws
    {
        self.fully_process = fullyProcess
        self.writeOutputFiles = writeOutputFiles
        self.config = config
        self.base_name = baseName
        self.callbacks = callbacks
        self.outlierGroupLoader = outlierGroupLoader
        
        // XXX this is now only used here for getting the image width, height and bpp
        // XXX this is a waste time
        //let image = try await imageSequence.getImage(withName: imageSequence.filenames[frameIndex]).image()
        self.imageSequence = imageSequence
        self.frameIndex = frameIndex // frame index in the image sequence
        self.otherFrameIndexes = otherFrameIndexes
        self.outputFilename = outputFilename

        self.outlierOutputDirname = outlierOutputDirname
        self.previewOutputDirname = previewOutputDirname
        self.processedPreviewOutputDirname = processedPreviewOutputDirname
        self.thumbnailOutputDirname = thumbnailOutputDirname
        self.width = width
        self.height = height

        if ImageSequence.image_width == 0 {
            ImageSequence.image_width = width
        }
        if ImageSequence.image_height == 0 {
            ImageSequence.image_height = height
        }
        
        self.bytesPerPixel = bytesPerPixel
        self.bytesPerRow = width*bytesPerPixel

        // this takes a long time, and the gui does it later
        if fullyProcess {
            try await loadOutliers()
            Log.d("frame \(frameIndex) done detecting outlier groups")
            await self.writeOutliersBinary()
            Log.d("frame \(frameIndex) done writing outlier binaries")
        } else {
            Log.d("frame \(frameIndex) loaded without outlier groups")
        }

    }
    
    public func loadOutliers() async throws {
        if self.outlierGroups == nil {
            Log.d("frame \(frameIndex) loading outliers")
            if let outlierGroups = await outlierGroupLoader() {
                for outlier in outlierGroups.members.values {
                    outlier.setFrame(self) 
                }
                                                                  
                self.outlierGroups = outlierGroups
                // while these have already decided outlier groups,
                // we still need to inter frame process them so that
                // frames are linked with their neighbors and outlier
                // groups can use these links for decision tree values
                self.state = .readyForInterFrameProcessing
                self.outliersLoadedFromFile = true
                Log.i("loaded \(String(describing: self.outlierGroups?.members.count)) outlier groups for frame \(frameIndex)")
            } else {
                self.outlierGroups = OutlierGroups(frameIndex: frameIndex,
                                                    members: [:])

                Log.i("calculating outlier groups for frame \(frameIndex)")
                // find outlying bright pixels between frames,
                // and group neighboring outlying pixels into groups
                // this can take a long time
                try await self.findOutliers()
            }
        }
    }

    public func outlierGroup(named outlier_name: String) -> OutlierGroup? {
        return outlierGroups?.members[outlier_name]
    }
    
    public func foreachOutlierGroup(between startLocation: CGPoint,
                                    and endLocation: CGPoint,
                                    _ closure: (OutlierGroup)async->LoopReturn) async
    {
        // first get bounding box from start and end location
        var min_x: CGFloat = CGFLOAT_MAX
        var max_x: CGFloat = 0
        var min_y: CGFloat = CGFLOAT_MAX
        var max_y: CGFloat = 0

        if startLocation.x < min_x { min_x = startLocation.x }
        if startLocation.x > max_x { max_x = startLocation.x }
        if startLocation.y < min_y { min_y = startLocation.y }
        if startLocation.y > max_y { max_y = startLocation.y }
        
        if endLocation.x < min_x { min_x = endLocation.x }
        if endLocation.x > max_x { max_x = endLocation.x }
        if endLocation.y < min_y { min_y = endLocation.y }
        if endLocation.y > max_y { max_y = endLocation.y }

        let gesture_bounds = BoundingBox(min: Coord(x: Int(min_x), y: Int(min_y)),
                                         max: Coord(x: Int(max_x), y: Int(max_y)))

        await foreachOutlierGroup() { group in
            if gesture_bounds.contains(other: group.bounds) {
                // check to make sure this outlier's bounding box is fully contained
                // otherwise don't change paint status
                return await closure(group)
            } else {
                return .continue
            }
        }
    }

    public func foreachOutlierGroup(_ closure: (OutlierGroup)async->LoopReturn) async {
        if let outlierGroups = self.outlierGroups {
            for (_, group) in outlierGroups.members {
                let result = await closure(group)
                if result == .break { break }
            }
        } 
    }
    
    // this is still a slow part of the process, but is now about 10x faster than before
    func findOutliers() async throws {

        Log.d("frame \(frameIndex) finding outliers)")
        
        self.state = .loadingImages
        
        let image = try await imageSequence.getImage(withName: imageSequence.filenames[frameIndex]).image()

        var otherFrames: [PixelatedImage] = []

        for otherFrameIndex in otherFrameIndexes {
            let otherFrame = try await imageSequence.getImage(withName: imageSequence.filenames[otherFrameIndex]).image()
            otherFrames.append(otherFrame)
        }

        self.state = .detectingOutliers
        
        
        // need to have the OutlierGroup class contain a mini version of this for each one
        
        // one dimentional array mirroring pixels indexed by y*width + x
        var outlier_group_list = [String?](repeating: nil, count: width*height)
        
        Log.i("frame \(frameIndex) finding outliers")
        var outlier_amount_list = [UInt](repeating: 0, count: width*height)
        // compare pixels at the same image location in adjecent frames
        // detect Outliers which are much more brighter than the adject frames
        let orig_data = image.raw_image_data

        let other_data_1 = otherFrames[0].raw_image_data
        var other_data_2 = Data() // dummy backup 
        var have_two_other_frames = false
        if otherFrames.count > 1 {
            other_data_2 = otherFrames[1].raw_image_data
            have_two_other_frames = true
        }

        // most of the time is in this loop, although it's a lot faster now
        // ugly, but a lot faster
        orig_data.withUnsafeBytes { unsafeRawPointer in 
            let orig_image_pixels: UnsafeBufferPointer<UInt16> =
                unsafeRawPointer.bindMemory(to: UInt16.self)

            other_data_1.withUnsafeBytes { unsafeRawPointer_1  in 
                let other_image_1_pixels: UnsafeBufferPointer<UInt16> =
                    unsafeRawPointer_1.bindMemory(to: UInt16.self)

                other_data_2.withUnsafeBytes { unsafeRawPointer_2 in 
                    let other_image_2_pixels: UnsafeBufferPointer<UInt16> =
                        unsafeRawPointer_2.bindMemory(to: UInt16.self)

                    for y in 0 ..< height {
                        if y != 0 && y % 1000 == 0 {
                            Log.d("frame \(frameIndex) detected outliers in \(y) rows")
                        }
                        for x in 0 ..< width {
                            let cpp = 3 // number of components per pixel
                            let offset = (y * width*cpp) + (x * cpp)

                            // rgb values of the image we're modifying at this x,y
                            let orig_red = orig_image_pixels[offset]
                            let orig_green = orig_image_pixels[offset+1]
                            let orig_blue = orig_image_pixels[offset+2]
            
                            // rgb values of an adjecent image at this x,y
                            let other_1_red = other_image_1_pixels[offset]
                            let other_1_green = other_image_1_pixels[offset+1]
                            let other_1_blue = other_image_1_pixels[offset+2]

                            // how much brighter in each channel was the image we're modifying?
                            let other_1_red_diff = (Int(orig_red) - Int(other_1_red))
                            let other_1_green_diff = (Int(orig_green) - Int(other_1_green))
                            let other_1_blue_diff = (Int(orig_blue) - Int(other_1_blue))

                            // take a max based upon overal brightness, or just one channel
                            let other_1_max = max(other_1_red_diff +
                                                    other_1_green_diff +
                                                    other_1_blue_diff / 3,
                                                  max(other_1_red_diff,
                                                      max(other_1_green_diff,
                                                          other_1_blue_diff)))
                            
                            var total_difference: Int = Int(other_1_max)
                            
                            if have_two_other_frames {
                                // rgb values of another adjecent image at this x,y
                                let other_2_red = other_image_2_pixels[offset]
                                let other_2_green = other_image_2_pixels[offset+1]
                                let other_2_blue = other_image_2_pixels[offset+2]
                                
                                // how much brighter in each channel was the image we're modifying?
                                let other_2_red_diff = (Int(orig_red) - Int(other_2_red))
                                let other_2_green_diff = (Int(orig_green) - Int(other_2_green))
                                let other_2_blue_diff = (Int(orig_blue) - Int(other_2_blue))
            
                                // take a max based upon overal brightness, or just one channel
                                let other_2_max = max(other_2_red_diff +
                                                        other_2_green_diff +
                                                        other_2_blue_diff / 3,
                                                      max(other_2_red_diff,
                                                          max(other_2_green_diff,
                                                              other_2_blue_diff)))

                                // average the two differences of the two adjecent frames
                                total_difference += other_2_max
                                total_difference /= 2
                            }

                            let amount_index = Int(y*width+x)
                            // record the brightness change if it is brighter
                            if total_difference > 0  {
                                outlier_amount_list[amount_index] = UInt(total_difference)
                            }
                        }
                    }
                }
            }
        }

        // XXX was a boundary
        
        Log.i("frame \(frameIndex) pruning outliers")
        
        // go through the outliers and link together all the outliers that are adject to eachother,
        // outputting a mapping of group name to size
        
        var individual_group_counts: [String: UInt] = [:]

        var pending_outliers: [Int]
        var pending_outlier_insert_index = 0;
        var pending_outlier_access_index = 0;
       
        let array = [Int](repeating: -1, count: width*height) 
        pending_outliers = array

        Log.d("frame \(frameIndex) labeling adjecent outliers")

        // then label all adject outliers
        for (index, outlier_amount) in outlier_amount_list.enumerated() {
            
            if outlier_amount <= config.maxPixelDistance { continue }
            
            let outlier_groupname = outlier_group_list[index]
            if outlier_groupname != nil { continue }
            
            // not part of a group yet
            var groupSize: UInt = 0
            // tag this virgin outlier with its own key
            
            let outlier_key = "\(index % width),\(index / width)"; // arbitrary but needs to be unique
            //Log.d("initial index = \(index)")
            outlier_group_list[index] = outlier_key
            pending_outliers[pending_outlier_insert_index] = index;
            pending_outlier_insert_index += 1
            
            var loop_count: UInt64 = 0
                
            while pending_outlier_insert_index != pending_outlier_access_index {
                //Log.d("pending_outlier_insert_index \(pending_outlier_insert_index) pending_outlier_access_index \(pending_outlier_access_index)")
                loop_count += 1
                if loop_count % 1000 == 0 {
                    Log.v("frame \(frameIndex) looping \(loop_count) times groupSize \(groupSize)")
                }
                
                let next_outlier_index = pending_outliers[pending_outlier_access_index]
                //Log.d("next_outlier_index \(next_outlier_index)")
                
                pending_outlier_access_index += 1
               if let _ = outlier_group_list[next_outlier_index] {
                    groupSize += 1
                    
                    let outlier_x = next_outlier_index % width;
                    let outlier_y = next_outlier_index / width;

                    //Log.e("minPixelDistance \(minPixelDistance) maxPixelDistance \(maxPixelDistance)")
                    
                    if outlier_x > 0 { // add left neighbor
                        let left_neighbor_index = outlier_y * width + outlier_x - 1
                        let left_neighbor_amount = outlier_amount_list[left_neighbor_index]
                        if left_neighbor_amount > config.minPixelDistance,
                           outlier_group_list[left_neighbor_index] == nil
                        {
                            pending_outliers[pending_outlier_insert_index] = left_neighbor_index
                            outlier_group_list[left_neighbor_index] = outlier_key
                            pending_outlier_insert_index += 1
                        }
                    }
                    
                    if outlier_x < width - 1 { // add right neighbor
                        let right_neighbor_index = outlier_y * width + outlier_x + 1
                        let right_neighbor_amount = outlier_amount_list[right_neighbor_index]
                        if right_neighbor_amount > config.minPixelDistance,
                           outlier_group_list[right_neighbor_index] == nil
                        {
                            pending_outliers[pending_outlier_insert_index] = right_neighbor_index
                            outlier_group_list[right_neighbor_index] = outlier_key
                            pending_outlier_insert_index += 1
                        }
                    }
                    
                    if outlier_y > 0 { // add top neighbor
                        let top_neighbor_index = (outlier_y - 1) * width + outlier_x
                        let top_neighbor_amount = outlier_amount_list[top_neighbor_index]
                        if top_neighbor_amount > config.minPixelDistance,
                           outlier_group_list[top_neighbor_index] == nil
                        {
                            pending_outliers[pending_outlier_insert_index] = top_neighbor_index
                            outlier_group_list[top_neighbor_index] = outlier_key
                            pending_outlier_insert_index += 1
                        }
                    }
                    
                    if outlier_y < height - 1 { // add bottom neighbor
                        let bottom_neighbor_index = (outlier_y + 1) * width + outlier_x
                        let bottom_neighbor_amount = outlier_amount_list[bottom_neighbor_index]
                        if bottom_neighbor_amount > config.minPixelDistance,
                           outlier_group_list[bottom_neighbor_index] == nil
                        {
                            pending_outliers[pending_outlier_insert_index] = bottom_neighbor_index
                            outlier_group_list[bottom_neighbor_index] = outlier_key
                            pending_outlier_insert_index += 1
                        }
                    }
                } else {
                    //Log.w("next outlier has groupName \(String(describing: next_outlier.groupName))")
                    // shouldn't end up here with a group named outlier
                    fatalError("FUCK")
                }
            }
            //Log.d("group \(outlier_key) has \(groupSize) members")
            if groupSize > config.minGroupSize { 
                individual_group_counts[outlier_key] = groupSize
            }
        }

        var group_amounts: [String: UInt] = [:] // keyed by group name, average brightness of each group

        Log.i("frame \(frameIndex) calculating outlier group bounds")
        var groupMinX: [String:Int] = [:]   // keyed by group name, image bounds of each group
        var groupMinY: [String:Int] = [:]
        var groupMaxX: [String:Int] = [:]
        var groupMaxY: [String:Int] = [:]
        
        // calculate the outer bounds of each outlier group
        for x in 0 ..< width {
            for y in 0 ..< height {
                let index = y*width+x
                if let group = outlier_group_list[index]
                {
                    let amount = outlier_amount_list[index]
                    if let group_amount = group_amounts[group] {
                        group_amounts[group] = group_amount + amount
                    } else {
                        group_amounts[group] = amount
                    }
                    if let minX = groupMinX[group] {
                        if(x < minX) {
                            groupMinX[group] = x
                        }
                    } else {
                        groupMinX[group] = x
                    }
                    if let minY = groupMinY[group] {
                        if(y < minY) {
                            groupMinY[group] = y
                        }
                    } else {
                        groupMinY[group] = y
                    }
                    if let maxX = groupMaxX[group] {
                        if(x > maxX) {
                            groupMaxX[group] = x
                        }
                    } else {
                        groupMaxX[group] = x
                    }
                    if let maxY = groupMaxY[group] {
                        if(y > maxY) {
                            groupMaxY[group] = y
                        }
                    } else {
                        groupMaxY[group] = y
                    }
                }
            }
        }

        // populate the outlierGroups
        for (groupName, groupSize) in individual_group_counts {
            if let minX = groupMinX[groupName],
               let minY = groupMinY[groupName],
               let maxX = groupMaxX[groupName],
               let maxY = groupMaxY[groupName],
               let group_amount = group_amounts[groupName]
            {
                let boundingBox = BoundingBox(min: Coord(x: minX, y: minY),
                                               max: Coord(x: maxX, y: maxY))
                let groupBrightness = UInt(group_amount) / groupSize

                // first apply a height based distinction on the group size,
                // to allow smaller groups lower in the sky, and not higher up.
                // can greatly reduce the outlier group count
                
                // don't do if this bounding box borders an edge
                if minY != 0,
                   minX != 0,
                   maxX < width - 1,
                   maxY < height - 1
                {
                    let group_centerY = boundingBox.center.y

                    let upper_area_size = Double(height)*config.upperSkyPercentage/100

                    if group_centerY < Int(upper_area_size) {
                        // 1 if at top, 0 if at bottom of the upper area
                        let how_close_to_top = (upper_area_size - Double(group_centerY)) / upper_area_size
                        let min_size_for_this_group = config.minGroupSize + Int(Double(config.minGroupSizeAtTop - config.minGroupSize) * how_close_to_top)
                        Log.v("min_size_for_this_group \(min_size_for_this_group) how_close_to_top \(how_close_to_top) group_centerY \(group_centerY) height \(height)")
                        if groupSize < min_size_for_this_group {
                            Log.v("frame \(frameIndex) skipping group of size \(groupSize) < \(min_size_for_this_group) @ centerY \(group_centerY)")
                            continue
                        }
                    }

                }

                // next collect the amounts
                
                var outlierAmounts = [UInt32](repeating: 0, count: boundingBox.width*boundingBox.height)
                for x in minX ... maxX {
                    for y in minY ... maxY {
                        let index = y * self.width + x
                        if let pixelGroupName = outlier_group_list[index],
                           pixelGroupName == groupName
                        {
                            let pixel_amount = outlier_amount_list[index]
                            let idx = (y-minY) * boundingBox.width + (x-minX)
                            outlierAmounts[idx] = UInt32(pixel_amount)
                        }
                    }
                }
                
                let newOutlier = await OutlierGroup(name: groupName,
                                                size: groupSize,
                                                brightness: groupBrightness,
                                                bounds: boundingBox,
                                                frame: self,
                                                pixels: outlierAmounts,
                                                maxPixelDistance: config.maxPixelDistance)
                outlierGroups?.members[groupName] = newOutlier
            }
        }
        self.state = .readyForInterFrameProcessing
        Log.i("frame \(frameIndex) has found \(String(describing: outlierGroups?.members.count)) outlier groups to consider")
    }

    public func pixelatedImage() async throws -> PixelatedImage? {
        let name = imageSequence.filenames[frameIndex]
        return try await imageSequence.getImage(withName: name).image()
    }

    public func baseImage() async throws -> NSImage? {
        let name = imageSequence.filenames[frameIndex]
        return try await imageSequence.getImage(withName: name).image().baseImage
    }
    
    public func baseOutputImage() async throws -> NSImage? {
        let name = self.outputFilename
        return try await imageSequence.getImage(withName: name).image().baseImage
    }
    
    public func baseImage(ofSize size: NSSize) async throws -> NSImage? {
        let name = imageSequence.filenames[frameIndex]
        return try await imageSequence.getImage(withName: name).image().baseImage(ofSize: size)
    }

    public func purgeCachedOutputFiles() async {
        Log.d("frame \(frameIndex) purging output files")
//        let dispatchGroup = DispatchGroup()
//        dispatchGroup.enter()
        Task {
            await imageSequence.removeValue(forKey: self.outputFilename)
//            dispatchGroup.leave()
        }
//        dispatchGroup.wait()
        Log.d("frame \(frameIndex) purged output files")
    }
    
    // actually paint over outlier groups that have been selected as airplane tracks
    private func paintOverAirplanes(toData data: inout Data,
                                    otherFrames: [PixelatedImage]) async throws
    {
        Log.i("frame \(frameIndex) painting airplane outlier groups")

        let image = try await imageSequence.getImage(withName: imageSequence.filenames[frameIndex]).image()

        // paint over every outlier in the paint list with pixels from the adjecent frames
        guard let outlierGroups = outlierGroups else {
            Log.e("cannot paint without outlier groups")
            return
        }

        for (_, group) in outlierGroups.members {
            if let reason = group.shouldPaint {
                if reason.willPaint {
                    Log.d("frame \(frameIndex) painting over group \(group) for reason \(reason)")
                    //let x = index % width;
                    //let y = index / width;
                    for x in group.bounds.min.x ... group.bounds.max.x {
                        for y in group.bounds.min.y ... group.bounds.max.y {
                            let pixel_index = (y - group.bounds.min.y)*group.bounds.width + (x - group.bounds.min.x)
                            if group.pixels[pixel_index] != 0 {
                                
                                let pixel_amount = group.pixels[pixel_index]
                                
                                var alpha: Double = 0
                                
                                if pixel_amount > config.maxPixelDistance {
                                    alpha = 1
                                } else if pixel_amount < config.minPixelDistance {
                                    alpha = 0
                                } else {
                                    alpha = Double(UInt16(pixel_amount) - config.minPixelDistance) /
                                      Double(config.maxPixelDistance - config.minPixelDistance)
                                }
                                
                                if alpha > 0 {
                                    paint(x: x, y: y, why: reason, alpha: alpha,
                                          toData: &data,
                                          image: image,
                                          otherFrames: otherFrames)
                                }
                            }
                        }
                    }
                } else {
                    Log.v("frame \(frameIndex) NOT painting over group \(group) for reason \(reason)")
                }
            }
        }
    }

    // paint over a selected outlier pixel with data from pixels from adjecent frames
    private func paint(x: Int, y: Int,
                       why: PaintReason,
                       alpha: Double,
                       toData data: inout Data,
                       image: PixelatedImage,
                       otherFrames: [PixelatedImage])
    {
        var pixels_to_paint_with: [Pixel] = []
        
        // grab the pixels from the same image spot from adject frames
//        for i in 0 ..< otherFrames.count {
//            pixels_to_paint_with.append(otherFrames[i].readPixel(atX: x, andY: y))
//        }

        // XXX blending both adjecent frames can make the painted airlane streak darker
        // then it was before because the bright stars are dimmed 50% due to them moving across
        // two frames.  try just using one frame and see how that works.  maybe make it an option?

        
        pixels_to_paint_with.append(otherFrames[0].readPixel(atX: x, andY: y))
        
        // blend the pixels from the adjecent frames
        var paint_pixel = Pixel(merging: pixels_to_paint_with)

        if alpha < 1 {
            let op = image.readPixel(atX: x, andY: y)
            paint_pixel = Pixel(merging: paint_pixel, with: op, atAlpha: alpha)
        }

        // this is the numeric value we need to write out to paint over the airplane
        var paint_value = paint_pixel.value
        
        // the is the place in the image data to write to
        let offset = (Int(y) * bytesPerRow) + (Int(x) * bytesPerPixel)
        
        // actually paint over that airplane like thing in the image data
        data.replaceSubrange(offset ..< offset+self.bytesPerPixel,
                             with: &paint_value, count: self.bytesPerPixel)
        
    }

    private func writeUprocessedPreviews(_ image: PixelatedImage) {
        if config.writeFramePreviewFiles ||
           config.writeFrameThumbnailFiles
        {
            Log.d("frame \(self.frameIndex) doing preview")
            if let baseImage = image.baseImage {
                // maybe write previews
                // these are not overwritten as the original
                // is assumed to be not change
                self.writePreviewFile(baseImage)
                self.writeThumbnailFile(baseImage)
            } else {
                Log.w("frame \(self.frameIndex) NO BASE IMAGE")
            }
        }
    }

    private func writeProcssedPreview(_ image: PixelatedImage, with output_data: Data) {
        // write out a preview of the processed file
        if config.writeFrameProcessedPreviewFiles {
            if let processed_preview_image = image.baseImage(ofSize: self.previewSize,
                                                             fromData: output_data),
               let imageData = processed_preview_image.jpegData,
               let filename = self.processedPreviewFilename
            {
                do {
                    if file_manager.fileExists(atPath: filename) {
                        Log.i("overwriting already existing processed preview \(filename)")
                        try file_manager.removeItem(atPath: filename)
                    }

                    // write to file
                    file_manager.createFile(atPath: filename,
                                            contents: imageData,
                                            attributes: nil)
                    Log.i("frame \(self.frameIndex) wrote preview to \(filename)")
                } catch {
                    Log.e("\(error)")
                }
            } else {
                Log.w("frame \(self.frameIndex) WTF")
            }
        }
    }

    // run after shouldPaint has been set for each group, 
    // does the final painting and then writes out the output files
    public func finish() async throws {

        try await withLimitedThrowingTaskGroup(of: Void.self) { taskGroup in 

            try await taskGroup.addTask() {
                // write out the outliers binary if it is not there
                // only overwrite the paint reason if it is there
                await self.writeOutliersBinary()
            }

            try await taskGroup.addTask() {
                // write out the classifier feature data for this data point
                try await self.writeOutlierValuesCSV()
            }

            if !self.writeOutputFiles {
                self.state = .complete
                return
            }
        
            self.state = .reloadingImages
        
            Log.i("frame \(self.frameIndex) finishing")
            let image = try await imageSequence.getImage(withName: imageSequence.filenames[frameIndex]).image()

            try await taskGroup.addTask() {
                self.writeUprocessedPreviews(image)
            }
        
            var otherFrames: [PixelatedImage] = []

            // only load the first other frame for painting
            let otherFrameIndex = otherFrameIndexes[0]
            let otherFrame = try await imageSequence.getImage(withName: imageSequence.filenames[otherFrameIndex]).image()
            otherFrames.append(otherFrame)
        
            let _data = image.raw_image_data
        
            // copy the original image data as adjecent frames need
            // to access the original unmodified version
            guard let _mut_data = CFDataCreateMutableCopy(kCFAllocatorDefault,
                                                      CFDataGetLength(_data as CFData),
                                                      _data as CFData) as? Data
            else {
                Log.e("couldn't copy image data")
                fatalError("couldn't copy image data")
            }
            var output_data = _mut_data

            self.state = .painting
                  
            Log.d("frame \(self.frameIndex) painting over airplanes")
                  
            try await self.paintOverAirplanes(toData: &output_data,
                                          otherFrames: otherFrames)
        
            Log.d("frame \(self.frameIndex) writing output files")
            self.state = .writingOutputFile

            try await taskGroup.addTask() {
                self.writeProcssedPreview(image, with: output_data)
            }

            do {
                // write frame out as a tiff file after processing it
                try image.writeTIFFEncoding(ofData: output_data,  toFilename: self.outputFilename)
                self.state = .complete
            } catch {
                Log.e("\(error)")
            }

            try await taskGroup.waitForAll()

            Log.i("frame \(self.frameIndex) complete")
        }
    }
    
    public static func == (lhs: FrameAirplaneRemover, rhs: FrameAirplaneRemover) -> Bool {
        return lhs.frameIndex == rhs.frameIndex
    }    
}


fileprivate let file_manager = FileManager.default
