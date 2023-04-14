import Foundation
import CoreGraphics
import BinaryCodable
import Cocoa

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

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

@available(macOS 10.15, *)
public actor FrameAirplaneRemover: Equatable, Hashable {

    private var state: FrameProcessingState = .unprocessed {
        willSet {
            if let frameStateChangeCallback = self.callbacks.frameStateChangeCallback {
                frameStateChangeCallback(self, newValue)
            }
        }
    }

    public func processingState() -> FrameProcessingState { return state }
    
    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(frame_index)
    }
    
    func set(state: FrameProcessingState) { self.state = state }
    
    nonisolated public let width: Int
    nonisolated public let height: Int
    public let bytesPerPixel: Int
    public let bytesPerRow: Int
    public let otherFrameIndexes: [Int] // used in found outliers and paint only
    nonisolated public let frame_index: Int

    public let outlier_output_dirname: String?
    public let preview_output_dirname: String?
    public let processed_preview_output_dirname: String?
    public let thumbnail_output_dirname: String?

    // populated by pruning
    public var outlier_groups: OutlierGroups?

    public func outlierGroups() -> [OutlierGroup]? {
        if let outlier_groups = outlier_groups,
           let groups = outlier_groups.groups
        {
            return groups.map {$0.value}
        }
        return nil
    }

    public func outlierGroups(within distance: Double, of bounding_box: BoundingBox) -> [OutlierGroup]? {
        if let outlier_groups = outlier_groups,
           let groups = outlier_groups.groups
        {
            var ret: [OutlierGroup] = []
            for (_, group) in groups {
                if group.bounds.centerDistance(to: bounding_box) < distance {
                    ret.append(group)
                }
            }
            return ret
        }
        return nil
    }
    
    var previewSize: NSSize {
        let preview_width = config.preview_width
        let preview_height = config.preview_height
        return NSSize(width: preview_width, height: preview_height)
    }
    
    public func writePreviewFile(_ image: NSImage) {
        Log.d("frame \(self.frame_index) doing preview")
        if config.writeFramePreviewFiles {
            Log.d("frame \(self.frame_index) doing preview")
            let preview_size = self.previewSize
            
            if let scaledImage = image.resized(to: preview_size),
               let imageData = scaledImage.jpegData,
               let filename = self.previewFilename
            {
                do {
                    if file_manager.fileExists(atPath: filename) {
                        Log.i("overwriting already existing filename \(filename)")
                        try file_manager.removeItem(atPath: filename)
                    }

                    // write to file
                    file_manager.createFile(atPath: filename,
                                            contents: imageData,
                                            attributes: nil)
                    Log.i("frame \(self.frame_index) wrote preview to \(filename)")
                } catch {
                    Log.e("\(error)")
                }
            } else {
                Log.w("frame \(self.frame_index) WTF")
            }
        } else {
            Log.d("frame \(self.frame_index) no config")
        }
    }

    public func writeThumbnailFile(_ image: NSImage) {
        Log.d("frame \(self.frame_index) doing preview")
        if config.writeFrameThumbnailFiles {
            Log.d("frame \(self.frame_index) doing thumbnail")
            let thumbnail_width = config.thumbnail_width
            let thumbnail_height = config.thumbnail_height
            let thumbnail_size = NSSize(width: thumbnail_width, height: thumbnail_height)
            
            if let scaledImage = image.resized(to: thumbnail_size),
               let imageData = scaledImage.jpegData,
               let filename = self.thumbnailFilename
            {
                do {
                    if file_manager.fileExists(atPath: filename) {
                        Log.i("overwriting already existing filename \(filename)")
                        try file_manager.removeItem(atPath: filename)
                    }

                    // write to file
                    file_manager.createFile(atPath: filename,
                                            contents: imageData,
                                            attributes: nil)
                    Log.i("frame \(self.frame_index) wrote thumbnail to \(filename)")
                } catch {
                    Log.e("\(error)")
                }
            } else {
                Log.w("frame \(self.frame_index) WTF")
            }
        } else {
            Log.d("frame \(self.frame_index) no config")
        }
    }

    // write out just the OutlierGroupValueMatrix, which just what
    // the decision tree needs, and not very large
    public func writeOutlierValuesBinary() async {
        if config.writeOutlierGroupFiles,
           let output_dirname = self.outlier_output_dirname
        {
            // write out the decision tree value matrix too

            let valueMatrix = OutlierGroupValueMatrix()

            if let outliers = self.outlierGroups() {
                for outlier in outliers {
                    await valueMatrix.append(outlierGroup: outlier)
                }
            }

            let filename = "\(self.frame_index)_outlier_values.bin"
            let full_path = "\(output_dirname)/\(filename)"

            //if let json = valueMatrix.prettyJson { print(json) }
            
            let encoder = BinaryEncoder()
            Log.d("frame \(frame_index) about to encode outlier data")
            do {
                let data = try encoder.encode(valueMatrix)
                if file_manager.fileExists(atPath: full_path) {
                    try file_manager.removeItem(atPath: full_path)
                    // make this overwrite for new user changes to existing data
                    Log.i("overwriting \(full_path)")
                } 
                Log.i("creating \(full_path)")                      
                file_manager.createFile(atPath: full_path, contents: data, attributes: nil)
            } catch {
                Log.e("\(error)")
            }
        }
    }

    // write out full OutlierGroup codable binary
    // large, slow, but lots of data
    public func writeOutliersBinary() {
        if config.writeOutlierGroupFiles,
           let output_dirname = self.outlier_output_dirname
        {
            Log.d("frame \(frame_index) writing outliers to binary")
            // write to binary outlier data
            self.outlier_groups?.prepareForEncoding() {
                if let data = self.outlierBinaryData() {
                    let filename = "\(self.frame_index)_outliers.bin"
                    let full_path = "\(output_dirname)/\(filename)"
                    do {
                        if file_manager.fileExists(atPath: full_path) {
                            try file_manager.removeItem(atPath: full_path)
                            // make this overwrite for new user changes to existing data
                            Log.i("overwriting \(full_path)")
                        } 
                        Log.i("creating \(full_path)")                      
                        file_manager.createFile(atPath: full_path, contents: data, attributes: nil)
                    } catch {
                        Log.e("\(error)")
                    }
                } else {
                    Log.e("frame \(self.frame_index) has no outlier binary data :(")
                }
            }

        }
    }
    
    public func writeOutliersJson() {
        if config.writeOutlierGroupFiles,
           let output_dirname = self.outlier_output_dirname
        {
            // write to outlier json
            let json_data = self.outlierJsonData()
            //Log.e(json_string)
            
            let filename = "\(self.frame_index)_outliers.json"
            let full_path = "\(output_dirname)/\(filename)"
            do {
                if file_manager.fileExists(atPath: full_path) {
                    try file_manager.removeItem(atPath: full_path)
                    // make this overwrite for new user changes to existing json
                    Log.i("overwriting \(full_path)")
                } 
                Log.i("creating \(full_path)")                      
                file_manager.createFile(atPath: full_path, contents: json_data, attributes: nil)
            } catch {
                Log.e("\(error)")
            }
        }
    }

    public func userSelectAllOutliers(toShouldPaint should_paint: Bool,
                                      between startLocation: CGPoint,
                                      and endLocation: CGPoint) async
    {
        await foreachOutlierGroup(between: startLocation, and: endLocation) { group in
            await group.shouldPaint(.userSelected(should_paint))
            return .continue
        }
    }

    public func applyDecisionTreeToAutoSelectedOutliers() async {
        /*
         XXX commented out because of multiple trees now
        await foreachOutlierGroup() { group in
            let should_paint = await group.classification
            var apply = true
            if let shouldPaint = await group.shouldPaint {
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
                await group.shouldPaint(.decisionTree(should_paint))
            }
            return .continue
         }
            
         */
    }

    public func applyDecisionTreeToAllOutliers() async {
        /*
         XXX commented out because of multiple trees now
        await foreachOutlierGroup() { group in
            let should_paint = await group.classification
            Log.d("applying decision tree should_paint \(should_paint)")
            await group.shouldPaint(.decisionTree(should_paint))
            return .continue
            }
            
         */
    }
    
    public func userSelectAllOutliers(toShouldPaint should_paint: Bool) async {
        await foreachOutlierGroup() { group in
            await group.shouldPaint(.userSelected(should_paint))
            return .continue
        }
    }
    
    var outlierGroupCount: Int { return outlier_groups?.groups?.count ?? 0 }
    
    public let output_filename: String

    public let image_sequence: ImageSequence

    public let config: Config
    public let callbacks: Callbacks

    public let base_name: String

    // did we load our outliers from a file?
    private var outliersLoadedFromFile = false

    public func didLoadOutliersFromFile() -> Bool { outliersLoadedFromFile }
    
    nonisolated public var previewFilename: String? {
        if let preview_output_dirname = preview_output_dirname {
            return "\(preview_output_dirname)/\(base_name).jpg" // XXX this makes it .tif.jpg
        }
        return nil
    }
    
    nonisolated public var processedPreviewFilename: String? {
        if let processed_preview_output_dirname = processed_preview_output_dirname {
            return "\(processed_preview_output_dirname)/\(base_name).jpg"
        }
        return nil
    }
    
    nonisolated public var thumbnailFilename: String? {
        if let thumbnail_output_dirname = thumbnail_output_dirname {
            return "\(thumbnail_output_dirname)/\(base_name).jpg"
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

    let overwriteFileLoadedOutlierGroups: Bool

    // if this is false, just write out outlier data
    let writeOutputFiles: Bool
    
    init(with config: Config,
         width: Int,
         height: Int,
         bytesPerPixel: Int,
         callbacks: Callbacks,
         imageSequence image_sequence: ImageSequence,
         atIndex frame_index: Int,
         otherFrameIndexes: [Int],
         outputFilename output_filename: String,
         baseName: String,       // source filename without path
         outlierOutputDirname outlier_output_dirname: String?,
         previewOutputDirname preview_output_dirname: String?,
         processedPreviewOutputDirname processed_preview_output_dirname: String?,
         thumbnailOutputDirname thumbnail_output_dirname: String?,
         outlierGroupLoader: @escaping () async -> OutlierGroups?,
         fullyProcess: Bool = true,
         overwriteFileLoadedOutlierGroups: Bool = false,
         writeOutputFiles: Bool = true) async throws
    {
        self.fully_process = fullyProcess
        self.overwriteFileLoadedOutlierGroups = overwriteFileLoadedOutlierGroups
        self.writeOutputFiles = writeOutputFiles
        self.config = config
        self.base_name = baseName
        self.callbacks = callbacks
        self.outlierGroupLoader = outlierGroupLoader
        
        // XXX this is now only used here for getting the image width, height and bpp
        // XXX this is a waste time
        //let image = try await image_sequence.getImage(withName: image_sequence.filenames[frame_index]).image()
        self.image_sequence = image_sequence
        self.frame_index = frame_index // frame index in the image sequence
        self.otherFrameIndexes = otherFrameIndexes
        self.output_filename = output_filename

        self.outlier_output_dirname = outlier_output_dirname
        self.preview_output_dirname = preview_output_dirname
        self.processed_preview_output_dirname = processed_preview_output_dirname
        self.thumbnail_output_dirname = thumbnail_output_dirname
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
            Log.d("frame \(frame_index) done detecting outlier groups")
        } else {
            Log.d("frame \(frame_index) loaded without outlier groups")
        }

    }
    
    public func loadOutliers() async throws {
        if self.outlier_groups == nil {
            Log.d("frame \(frame_index) loading outliers")
            if let outlierGroups = await outlierGroupLoader() {
                if let groups = outlierGroups.groups {
                    for outlier in groups.values {
                        await outlier.setFrame(self) 
                    }
                }
                                                                  
                self.outlier_groups = outlierGroups
                // while these have already decided outlier groups,
                // we still need to inter frame process them so that
                // frames are linked with their neighbors and outlier
                // groups can use these links for decision tree values
                self.state = .readyForInterFrameProcessing
                self.outliersLoadedFromFile = true
                Log.i("loaded \(self.outlier_groups?.groups?.count) outlier groups for frame \(frame_index)")
            } else {
                self.outlier_groups = OutlierGroups(frame_index: frame_index,
                                                    groups: [:])

                Log.i("calculating outlier groups for frame \(frame_index)")
                // find outlying bright pixels between frames,
                // and group neighboring outlying pixels into groups
                // this can take a long time
                try await self.findOutliers()
            }
        }
    }
    
    func readOutliers(fromJson json: String) throws {
        if let jsonData = json.data(using: .utf8) {
            let decoder = JSONDecoder()
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(
              positiveInfinity: "inf",
              negativeInfinity: "-inf",
              nan: "nan")
            self.outlier_groups = try decoder.decode(OutlierGroups.self, from: jsonData)
        } else {
            Log.e("json erorr: \(json)")
        }
    }
    
    func readOutliers(fromBinary data: Data) throws {
        let decoder = BinaryDecoder()
        self.outlier_groups = try decoder.decode(OutlierGroups.self, from: data)
    }
    
    func outlierBinaryData() -> Data? {
        let encoder = BinaryEncoder()
        Log.d("frame \(frame_index) about to encode outlier data")
        if let outlier_groups = outlier_groups {
            do {
                Log.i("frame \(frame_index) REALLY about to encode outlier data \(outlier_groups.encodable_groups?.count)")
                return try encoder.encode(outlier_groups)
            } catch {
                Log.e("\(error)")
            }
        } else {
            Log.e("no outlier groups to encode to binary data")
        }
        return nil
    }

    func outlierJsonData() -> Data {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf",
                                                                      negativeInfinity: "-inf",
                                                                      nan: "nan")
    //    encoder.outputFormatting = .prettyPrinted

        do {
            let data = try encoder.encode(outlier_groups)
//            if let json_string = String(data: data, encoding: .utf8) {
//                return json_string
//            }
            return data
        } catch {
            Log.e("\(error)")
        }
        return Data()
    }

    public func outlierGroup(named outlier_name: String) -> OutlierGroup? {
        return outlier_groups?.groups?[outlier_name]
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
        if let outlier_groups = self.outlier_groups,
           let groups = outlier_groups.groups 
        {
            for (_, group) in groups {
                let result = await closure(group)
                if result == .break { break }
            }
        } 
    }
    
    // this is still a slow part of the process, but is now about 10x faster than before
    func findOutliers() async throws {

        Log.d("frame \(frame_index) finding outliers)")
        
        self.state = .loadingImages
        
        let image = try await image_sequence.getImage(withName: image_sequence.filenames[frame_index]).image()

        var otherFrames: [PixelatedImage] = []

        for otherFrameIndex in otherFrameIndexes {
            let otherFrame = try await image_sequence.getImage(withName: image_sequence.filenames[otherFrameIndex]).image()
            otherFrames.append(otherFrame)
        }

        self.state = .detectingOutliers
        
        
        // need to have the OutlierGroup class contain a mini version of this for each one
        
        // one dimentional array mirroring pixels indexed by y*width + x
        var outlier_group_list = [String?](repeating: nil, count: width*height)
        
        Log.i("frame \(frame_index) finding outliers")
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
                            Log.d("frame \(frame_index) detected outliers in \(y) rows")
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
        
        Log.i("frame \(frame_index) pruning outliers")
        
        // go through the outliers and link together all the outliers that are adject to eachother,
        // outputting a mapping of group name to size
        
        var individual_group_counts: [String: UInt] = [:]

        var pending_outliers: [Int]
        var pending_outlier_insert_index = 0;
        var pending_outlier_access_index = 0;
       
        let array = [Int](repeating: -1, count: width*height) 
        pending_outliers = array

        Log.d("frame \(frame_index) labeling adjecent outliers")

        // then label all adject outliers
        for (index, outlier_amount) in outlier_amount_list.enumerated() {
            
            if outlier_amount <= config.max_pixel_distance { continue }
            
            let outlier_groupname = outlier_group_list[index]
            if outlier_groupname != nil { continue }
            
            // not part of a group yet
            var group_size: UInt = 0
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
                    Log.v("frame \(frame_index) looping \(loop_count) times group_size \(group_size)")
                }
                
                let next_outlier_index = pending_outliers[pending_outlier_access_index]
                //Log.d("next_outlier_index \(next_outlier_index)")
                
                pending_outlier_access_index += 1
                if let _ = outlier_group_list[next_outlier_index] {
                    group_size += 1
                    
                    let outlier_x = next_outlier_index % width;
                    let outlier_y = next_outlier_index / width;

                    let next_outlier_amount = Double(outlier_amount_list[next_outlier_index])

                    //Log.e("min_pixel_distance \(min_pixel_distance) max_pixel_distance \(max_pixel_distance)")
                    
                    if outlier_x > 0 { // add left neighbor
                        let left_neighbor_index = outlier_y * width + outlier_x - 1
                        let left_neighbor_amount = outlier_amount_list[left_neighbor_index]
                        if left_neighbor_amount > config.min_pixel_distance,
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
                        if right_neighbor_amount > config.min_pixel_distance,
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
                        if top_neighbor_amount > config.min_pixel_distance,
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
                        if bottom_neighbor_amount > config.min_pixel_distance,
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
            //Log.d("group \(outlier_key) has \(group_size) members")
            if group_size > config.minGroupSize { 
                individual_group_counts[outlier_key] = group_size
            }
        }

        var group_amounts: [String: UInt] = [:] // keyed by group name, average brightness of each group

        Log.i("frame \(frame_index) calculating outlier group bounds")
        var group_min_x: [String:Int] = [:]   // keyed by group name, image bounds of each group
        var group_min_y: [String:Int] = [:]
        var group_max_x: [String:Int] = [:]
        var group_max_y: [String:Int] = [:]
        
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
                    if let min_x = group_min_x[group] {
                        if(x < min_x) {
                            group_min_x[group] = x
                        }
                    } else {
                        group_min_x[group] = x
                    }
                    if let min_y = group_min_y[group] {
                        if(y < min_y) {
                            group_min_y[group] = y
                        }
                    } else {
                        group_min_y[group] = y
                    }
                    if let max_x = group_max_x[group] {
                        if(x > max_x) {
                            group_max_x[group] = x
                        }
                    } else {
                        group_max_x[group] = x
                    }
                    if let max_y = group_max_y[group] {
                        if(y > max_y) {
                            group_max_y[group] = y
                        }
                    } else {
                        group_max_y[group] = y
                    }
                }
            }
        }

        // populate the outlier_groups
        for (group_name, group_size) in individual_group_counts {
            if let min_x = group_min_x[group_name],
               let min_y = group_min_y[group_name],
               let max_x = group_max_x[group_name],
               let max_y = group_max_y[group_name],
               let group_amount = group_amounts[group_name]
            {
                let bounding_box = BoundingBox(min: Coord(x: min_x, y: min_y),
                                               max: Coord(x: max_x, y: max_y))
                let group_brightness = UInt(group_amount) / group_size

                // first apply a height based distinction on the group size,
                // to allow smaller groups lower in the sky, and not higher up.
                // can greatly reduce the outlier group count
                
                // don't do if this bounding box borders an edge
                if min_y != 0,
                   min_x != 0,
                   max_x < width - 1,
                   max_y < height - 1
                {
                    let group_center_y = bounding_box.center.y

                    let upper_area_size = Double(height)*config.upper_sky_percentage/100

                    if group_center_y < Int(upper_area_size) {
                        // 1 if at top, 0 if at bottom of the upper area
                        let how_close_to_top = (upper_area_size - Double(group_center_y)) / upper_area_size
                        let min_size_for_this_group = config.minGroupSize + Int(Double(config.min_group_size_at_top - config.minGroupSize) * how_close_to_top)
                        Log.v("min_size_for_this_group \(min_size_for_this_group) how_close_to_top \(how_close_to_top) group_center_y \(group_center_y) height \(height)")
                        if group_size < min_size_for_this_group {
                            Log.v("frame \(frame_index) skipping group of size \(group_size) < \(min_size_for_this_group) @ center_y \(group_center_y)")
                            continue
                        }
                    }

                }

                // next collect the amounts
                
                var outlier_amounts = [UInt32](repeating: 0, count: bounding_box.width*bounding_box.height)
                for x in min_x ... max_x {
                    for y in min_y ... max_y {
                        let index = y * self.width + x
                        if let pixel_group_name = outlier_group_list[index],
                           pixel_group_name == group_name
                        {
                            let pixel_amount = outlier_amount_list[index]
                            let idx = (y-min_y) * bounding_box.width + (x-min_x)
                            outlier_amounts[idx] = UInt32(pixel_amount)
                        }
                    }
                }
                
                let new_outlier = await OutlierGroup(name: group_name,
                                                     size: group_size,
                                                     brightness: group_brightness,
                                                     bounds: bounding_box,
                                                     frame: self,
                                                     pixels: outlier_amounts,
                                                     max_pixel_distance: config.max_pixel_distance)
                let hough_score = await new_outlier.paintScore(from: .houghTransform)
                //let surface_area_score = await new_outlier.paintScore(from: .surfaceAreaRatio)

                if group_size < config.max_must_look_like_line_size,
                   hough_score < config.max_must_look_like_line_score,
                   new_outlier.surfaceAreaToSizeRatio > config.surface_area_to_size_max
                {
                    // ignore small groups that have a bad hough score
                    //Log.e("frame \(frame_index) ignoring outlier \(new_outlier) with hough score \(hough_score) satsr \(satsr) surface_area_score \(surface_area_score)")
                } else {
                    //Log.w("frame \(frame_index) adding outlier \(new_outlier) with hough score \(hough_score) satsr \(satsr) surface_area_score \(surface_area_score)")
                    // add this new outlier to the set to analyize
                    outlier_groups?.groups?[group_name] = new_outlier
                }
                  
            }
        }
        self.state = .readyForInterFrameProcessing
        Log.i("frame \(frame_index) has found \(outlier_groups?.groups?.count) outlier groups to consider")
    }

    public func pixelatedImage() async throws -> PixelatedImage? {
        let name = image_sequence.filenames[frame_index]
        return try await image_sequence.getImage(withName: name).image()
    }

    public func baseImage() async throws -> NSImage? {
        let name = image_sequence.filenames[frame_index]
        return try await image_sequence.getImage(withName: name).image().baseImage
    }
    
    public func baseOutputImage() async throws -> NSImage? {
        let name = self.output_filename
        return try await image_sequence.getImage(withName: name).image().baseImage
    }
    
    public func baseImage(ofSize size: NSSize) async throws -> NSImage? {
        let name = image_sequence.filenames[frame_index]
        return try await image_sequence.getImage(withName: name).image().baseImage(ofSize: size)
    }

    public func purgeCachedOutputFiles() async {
        Log.d("frame \(frame_index) purging output files")
//        let dispatchGroup = DispatchGroup()
//        dispatchGroup.enter()
        Task {
            await image_sequence.removeValue(forKey: self.output_filename)
//            dispatchGroup.leave()
        }
//        dispatchGroup.wait()
        Log.d("frame \(frame_index) purged output files")
    }
    
    // actually paint over outlier groups that have been selected as airplane tracks
    private func paintOverAirplanes(toData data: inout Data,
                                    otherFrames: [PixelatedImage]) async throws
    {
        Log.i("frame \(frame_index) painting airplane outlier groups")

        let image = try await image_sequence.getImage(withName: image_sequence.filenames[frame_index]).image()

        // paint over every outlier in the paint list with pixels from the adjecent frames
        guard let outlier_groups = outlier_groups else {
            Log.e("cannot paint without outlier groups")
            return
        }
        
        guard let groups = outlier_groups.groups else {
            Log.e("cannot paint without outlier groups")
            return
        }
        
        for (group_name, group) in groups {
            if let reason = await group.shouldPaint {
                if reason.willPaint {
                    Log.d("frame \(frame_index) painting over group \(group) for reason \(reason)")
                    //let x = index % width;
                    //let y = index / width;
                    for x in group.bounds.min.x ... group.bounds.max.x {
                        for y in group.bounds.min.y ... group.bounds.max.y {
                            let pixel_index = (y - group.bounds.min.y)*group.bounds.width + (x - group.bounds.min.x)
                            if group.pixels[pixel_index] != 0 {
                                
                                let pixel_amount = group.pixels[pixel_index]
                                
                                var alpha: Double = 0
                                
                                if pixel_amount > config.max_pixel_distance {
                                    alpha = 1
                                } else if pixel_amount < config.min_pixel_distance {
                                    alpha = 0
                                } else {
                                    alpha = Double(UInt16(pixel_amount) - config.min_pixel_distance) /
                                      Double(config.max_pixel_distance - config.min_pixel_distance)
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
                    Log.v("frame \(frame_index) NOT painting over group \(group) for reason \(reason)")
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
    
    // run after should_paint has been set for each group, 
    // does the final painting and then writes out the output files
    public func finish() async throws {

        if self.outliersLoadedFromFile {
            // if we've loaded outliers from a file, only save again if we're in gui mode
            // in GUI mode the user may have made an explicit decision
            if self.overwriteFileLoadedOutlierGroups {
                self.writeOutliersBinary()
            }
        } else {
            self.writeOutliersBinary()
        }

        // these are derived from the outliers binary, and writing them out is ok
        await writeOutlierValuesBinary()

        if !self.writeOutputFiles {
            self.state = .complete
            return
        }
        
        self.state = .reloadingImages
        
        Log.i("frame \(self.frame_index) finishing")
        let image = try await image_sequence.getImage(withName: image_sequence.filenames[frame_index]).image()


        if config.writeFramePreviewFiles ||
           config.writeFrameThumbnailFiles
        {
            Log.d("frame \(self.frame_index) doing preview")
            if let baseImage = image.baseImage {
                self.writePreviewFile(baseImage)
                self.writeThumbnailFile(baseImage)
            } else {
                Log.w("frame \(self.frame_index) NO BASE IMAGE")
            }
        }
        
        // maybe write out pre-updated scaled preview image here?
        
        var otherFrames: [PixelatedImage] = []

        // only load the first other frame for painting
        let otherFrameIndex = otherFrameIndexes[0]
        let otherFrame = try await image_sequence.getImage(withName: image_sequence.filenames[otherFrameIndex]).image()
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
                  
        Log.d("frame \(self.frame_index) painting over airplanes")
                  
        try await self.paintOverAirplanes(toData: &output_data,
                                          otherFrames: otherFrames)
        
        Log.d("frame \(self.frame_index) writing output files")
        self.state = .writingOutputFile

        // write out a preview of the processed file
        if config.writeFrameProcessedPreviewFiles {
            if let processed_preview_image = image.baseImage(ofSize: self.previewSize,
                                                            fromData: output_data),
               let imageData = processed_preview_image.jpegData,
               let filename = self.processedPreviewFilename
            {
                do {
                    if file_manager.fileExists(atPath: filename) {
                        Log.i("overwriting already existing filename \(filename)")
                        try file_manager.removeItem(atPath: filename)
                    }

                    // write to file
                    file_manager.createFile(atPath: filename,
                                            contents: imageData,
                                            attributes: nil)
                    Log.i("frame \(self.frame_index) wrote preview to \(filename)")
                } catch {
                    Log.e("\(error)")
                }
            } else {
                Log.w("frame \(self.frame_index) WTF")
            }
        }

        do {
            // write frame out as a tiff file after processing it
            try image.writeTIFFEncoding(ofData: output_data,  toFilename: self.output_filename)
            self.state = .complete
        } catch {
            Log.e("\(error)")
        }

        Log.i("frame \(self.frame_index) complete")
    }
    
    public static func == (lhs: FrameAirplaneRemover, rhs: FrameAirplaneRemover) -> Bool {
        return lhs.frame_index == rhs.frame_index
    }    
}


fileprivate let file_manager = FileManager.default
