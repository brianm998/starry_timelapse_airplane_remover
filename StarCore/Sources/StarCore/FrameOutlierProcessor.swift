import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession, URLRequest live here on Linux
#endif
import StarCppBridge
import logging

// FrameOutlierProcessor owns all outlier-related state and logic for one frame.
// It back-references its parent FrameAirplaneRemover via a weak `frame` var.

final public actor FrameOutlierProcessor {

    nonisolated public let frameIndex: Int
    nonisolated public let imageAccessor: ImageAccessor
    nonisolated public let width: Int
    nonisolated public let height: Int
    nonisolated public let componentsPerPixel: Int
    let configManager: ConfigManager
    let callbacks: Callbacks
    private weak var imageSequence: ImageSequence?
    weak var frame: FrameAirplaneRemover?

    // Outlier state (moved from FrameAirplaneRemover)
    public var outlierGroups: OutlierGroups?
    internal var outliersLoadedFromFile = false
    internal var isLoadingOutliers = false

    init(
        frameIndex: Int,
        imageAccessor: ImageAccessor,
        configManager: ConfigManager,
        callbacks: Callbacks,
        imageSequence: ImageSequence?,
        width: Int,
        height: Int,
        componentsPerPixel: Int
    ) {
        self.frameIndex = frameIndex
        self.imageAccessor = imageAccessor
        self.configManager = configManager
        self.callbacks = callbacks
        self.imageSequence = imageSequence
        self.width = width
        self.height = height
        self.componentsPerPixel = componentsPerPixel
    }

    func setFrame(_ frame: FrameAirplaneRemover) {
        self.frame = frame
    }

    /// Convenience accessor so external callers can read outlierGroups via await.
    public func getOutlierGroups() -> OutlierGroups? { outlierGroups }

    /// Drop the cached outlier-id image, which rebuilds on demand. See
    /// `OutlierGroups.releaseOutlierImageData()`.
    public func releaseOutlierImageData() async {
        await outlierGroups?.releaseOutlierImageData()
    }

    // Private duplicate of FAR's outputSizes — avoids a cross-actor hop.
    private var outputSizes: [ImageDisplaySize] {
        get async {
            var sizes: [ImageDisplaySize] = [.original]
            let config = await configManager.config()
            if config.writeFramePreviewFiles {
                sizes.append(.preview)
            }
            return sizes
        }
    }

    internal var userSlices: [BoundingBox]? = nil

    public func getUserSlices() async -> [BoundingBox] {
        if let userSlices { return userSlices }

        await loadUserSlices()

        if let userSlices { return userSlices }

        return []               // doh!
        
    }

    public var userSliceDirname: String {
        get async {
            let config = await configManager.config()
            return "\(config.tempOutputPath)/\(config.imageSequenceDirname)-star-user-slices"
        }
    }

    public var userSliceFilename: String {
        get async {
            let dirname = await userSliceDirname
            return "\(dirname)/slices_\(frameIndex).json"
        }
    }

    // called from the CLI only, not the GUI
    public func setupOutliers() async throws {
        // this takes a long time, and the gui does it later
        try await loadOutliers()
    }
    // Mark - Outliers
    

    // loads outliers from a combination of the outliers.tiff image and the subtraction image,
    // if they are present
    public func loadOutliersFromFile() async -> OutlierGroups? {
        try? await outliersFileSystemMonitor.load() {
            do {
                // newer file format, default to this
                return try await loadOutliersFromBinaryFile()
            } catch {
                //Log.i("frame \(frameIndex) failed to load outliers: \(error)")
                // XXX log here
            }

            return nil
        }
    }

    public var blobBinaryFilename: String { 
        get async {
            let config = await configManager.config()
            return "\(config.outlierOutputDirname)/\(frameIndex)/\(BlobBinarySaver.outlierBinaryFilename)"
        }
    }
    
    public var trashBinaryFilename: String { 
        get async {
            let config = await configManager.config()
            return "\(config.outlierOutputDirname)/\(frameIndex)/\(BlobBinarySaver.trashBinaryFilename)"
        }
    }
    
    public func loadOutliersFromBinaryFile() async throws -> OutlierGroups? {
        let config = await configManager.config()
        let dirname = "\(config.outlierOutputDirname)/\(frameIndex)"

        return try await OutlierGroups(
          at: frameIndex,
          fromOutlierDir: dirname,
          config: config
        )
    }
    
    // re-runs outlier detection within bounds with current settings
    public func findOutliers(within bounds: BoundingBox) async throws {
        Log.d("shovel frame \(frameIndex) finding outliers within bounds \(bounds)")

        if outlierGroups == nil {
            outlierGroups = OutlierGroups(
              frameIndex: frameIndex,
              config: await configManager.config()
            )
        }
        
        guard let outlierGroups else {
            Log.e("cannot find outliers without outlier groups")
            return
        }
        
        mkdir(await outliersDirname)

        let blobProcessor = await constants.getDetectionType().blobProcessor

        let currentMaxID = await outlierGroups.maxID

        Log.i("frame \(frameIndex) found currentMaxID \(currentMaxID)")
        
        guard let frame else { return }
        let newBlobMap = try await blobProcessor.process(
          frame: frame,
          within: bounds,
          startingBlobID: currentMaxID + 1
        )

        // add new blobs to outlier groups, fore-going any classification for now
        await outlierGroups.add(blobs: newBlobMap, within: bounds)

        try await outlierGroups.writeOutliersBinary(to: await outliersDirname)
        Log.d("shovel frame \(frameIndex) done finding outliers within bounds \(bounds)")
    }
    
    public func findOutliers() async throws {
        
        mkdir(await outliersDirname)

        let blobProcessor = await constants.getDetectionType().blobProcessor
        
        guard let frame else { return }
        let blobMap = try await blobProcessor.process(frame: frame)

        // blobs to promote to outlier groups
        let blobs = Array(blobMap.values)

        Log.i("frame \(frameIndex) has \(blobs.count) blobs")
        await frame.set(state: .firstClassification)

        let classifier = OutlierClassifier(frame: frame)

        let trashLevel = await constants.getTrashLevel()

        // this changes based upon Y value
        let smallTrashMax = await constants.getSmallTrashMax()
        
        let (good, bad, featureTime, classificationTime, outlierCount) =
          await classifier.promoteAndClassify(blobs,
                                              trashLevel: trashLevel,
                                              smallTrashMax: smallTrashMax)
        Task {
            await classificationTimingDataHolder.set(featureTime: featureTime,
                                                     classificationTime: classificationTime,
                                                     outlierCount: outlierCount)
        }
        
        // XXX promote featureTime and classificationTime to the gui
        
        await outlierGroups?.add(good)
        await outlierGroups?.dumpInTrash(bad)
        
        // here we write the outlier binaries through the outlierGroups
        try await outlierGroups?.writeOutliersBinary(to: await outliersDirname)

        // XXX update UI

        await frame.set(state: .readyForInterFrameProcessing)
    }

    public func loadOutliers(loadOnly: Bool = false) async throws {
        if isLoadingOutliers {
            Log.w("Not loading twice")
            return
        }

        isLoadingOutliers = true
        if outlierGroups == nil {
            // nil outlier groups means that we haven't tried to get outliers for this frame yet
            Log.d("frame \(frameIndex) loading outliers")
            if let outlierGroups = await loadOutliersFromFile() {
                callbacks.frameOutliersLoadedCallback?(frameIndex, .loading)
                Log.d("frame \(frameIndex) loading outliers from file")
                for outlier in await outlierGroups.getMembers().values {
                    await outlier.set(frame: frame!)
                }

                self.outlierGroups = outlierGroups
                // while these have already decided outlier groups,
                // we still need to inter frame process them so that
                // frames are linked with their neighbors and outlier
                // groups can use these links for decision tree values
                outliersLoadedFromFile = true
                Log.i("loaded \(String(describing: await outlierGroups.getMembers().count)) outlier groups for frame \(frameIndex)")
                await frame?.updateCombineSubjects()
                
                callbacks.frameOutliersLoadedCallback?(frameIndex, .loaded)
            } else if !loadOnly {
                callbacks.frameOutliersLoadedCallback?(frameIndex, .loading)
                Log.d("frame \(frameIndex) calculating outliers")
                await initializeEmptyOutlierGroups()

                Log.i("calculating outlier groups for frame \(frameIndex)")
                // find outlying bright pixels between frames,
                // and group neighboring outlying pixels into groups
                // this can take a long time
                try await findOutliers()

                await frame?.updateCombineSubjects()
                
                // perhaps apply validation image to outliers here if possible
                callbacks.frameOutliersLoadedCallback?(frameIndex, .loaded)
            }
        }
        isLoadingOutliers = false
    }

    public func initializeEmptyOutlierGroups() async {
        outlierGroups = OutlierGroups(
          frameIndex: frameIndex,
          config: await configManager.config()
        )
    }
    
    public func foreachOutlierGroup(
      includingTrash: Bool,
      _ closure: @Sendable (OutlierGroup, Bool) async -> Bool
    ) async -> Bool {
        var didChange = false
        if let outlierGroups {
            for (_, group) in await outlierGroups.getMembers() {
                if await closure(group, false) { didChange = true }
            }
            if includingTrash {
                for (_, group) in await outlierGroups.getTrash() {
                    if await closure(group, true) { didChange = true }
                }
            }
        }
        return didChange
    }

    // returns true if any outlier group was changed
    public func foreachOutlierGroupMulti(
      includingTrash: Bool,
      _ closure: @Sendable @escaping (OutlierGroup, Bool) async -> Bool
    ) async -> Bool {
        var didChange = false
        if let outlierGroups {
            didChange = await Task.detached(priority: .userInitiated) {

                let outliers = await Array(outlierGroups.getMembers().values)
                var trash: [OutlierGroup] = []

                if includingTrash {
                    trash = await Array(outlierGroups.getTrash().values)
                }
                return await foreachOutlier(in: outliers, with: trash, closure)
            }.value
        }
        return didChange
    }

    public func outlierGroup(named outlierName: UInt16) async -> OutlierGroup? {
        await outlierGroups?.getMembers()[outlierName]
    }

    // returns true if anything changed 
    public func foreachOutlierGroupMulti(
      between startLocation: CGPoint,
      and endLocation: CGPoint,
      includingTrash: Bool, 
      _ closure: @Sendable @escaping (OutlierGroup, Bool) async -> Bool
    ) async -> Bool {
        // first get bounding box from start and end location
        var minX: CGFloat = CGFloat.greatestFiniteMagnitude
        var maxX: CGFloat = 0
        var minY: CGFloat = CGFloat.greatestFiniteMagnitude
        var maxY: CGFloat = 0

        if startLocation.x < minX { minX = startLocation.x }
        if startLocation.x > maxX { maxX = startLocation.x }
        if startLocation.y < minY { minY = startLocation.y }
        if startLocation.y > maxY { maxY = startLocation.y }
        
        if endLocation.x < minX { minX = endLocation.x }
        if endLocation.x > maxX { maxX = endLocation.x }
        if endLocation.y < minY { minY = endLocation.y }
        if endLocation.y > maxY { maxY = endLocation.y }

        let gestureBounds = BoundingBox(min: Coord(x: Int(minX), y: Int(minY)),
                                        max: Coord(x: Int(maxX), y: Int(maxY)))
        
        return await foreachOutlierGroupMulti(includingTrash: includingTrash) { group, isInTrash in
            var didChange = false
            if gestureBounds.contains(other: group.bounds) {
                // check to make sure this outlier's bounding box is fully contained
                // otherwise don't change removal status
                if !isInTrash || (includingTrash && isInTrash) {
                    if await closure(group, isInTrash) { didChange = true }
                }
            }
            return didChange
        }
    }

    public func maybeApplyOutlierGroupClassifier() async throws {

        var shouldUseDecisionTree = true
        /*
         logic here to do validation instead of decision tree

         if:
           - we calculated the outlier groups here, not loaded from file
           - and a validation image already exists for this frame
         then:
           - load the validation image
           - don't apply decision tree, use the validation image instead
         */

        if let image = try await imageAccessor.load(frameIndex: frameIndex,
                                                    type: .validation,
                                                    atSize: .original)
        {
            switch image.imageData {
            case .thirtyTwoBit(_):
                fatalError("frame \(frameIndex) cannot load 32 bit validation image")
                
            case .eightBit(let validationArr):
                await classifyOutliers(with: validationArr)
                shouldUseDecisionTree = false
                await frame?.markAsChanged()
                
            case .sixteenBit(_):
                Log.e("frame \(frameIndex) cannot load 16 bit validation image")
            }
        } else {
            Log.i("frame \(frameIndex) couldn't load validation image from")
        }
/*
        if config.writeOutlierGroupFiles,
           let outlierGroups
        {
            // calculate decision tree values first 
            for group in outlierGroups.members.values {
                let _ = group.decisionTreeValues
            }
        }
  */      
        if shouldUseDecisionTree {
            Log.i("frame \(frameIndex) classifying outliers with decision tree")
            await frame?.set(state: .secondClassification)
            await self.applyDecisionTreeToAllOutliers()
        }
    }

    // used to classify outliers given a validation image.
    // this validation image contains a non zero pixel for each outlier
    // that should be removed.
    // any outlier that matches any pixels is classified to remove here.
    private func classifyOutliers(with validationData: UnsafeBufferPointer<UInt8>) async {
        Log.d("frame \(frameIndex) classifying outliers with validation image data")

        if let outlierGroups {

            for group in await outlierGroups.getMembers().values {
                var groupIsValid = false
                for x in 0 ..< group.bounds.width {
                    for y in 0 ..< group.bounds.height {
                        if group.pixels[y*group.bounds.width+x] != 0 {
                            // test this non zero group pixel against the validation image

                            let validationX = group.bounds.min.x + x
                            let validationY = group.bounds.min.y + y
                            let validationIdx = validationY * width + validationX

                            if validationData[validationIdx] != 0 {
                                //Log.d("frame \(frameIndex) group \(group.id) is valid based upon validation image data")
                                groupIsValid = true
                                break
                            }
                        }
                    }
                    if groupIsValid { break }
                }
                //Log.d("group \(group) shouldRemove \(String(describing: group.shouldRemove))")
                _ = await group.shouldRemove(.userSelected(groupIsValid))
            }
        } else {
            Log.w("cannot classify nil outlier groups")
        }
    }

    public func outlierGroupList() async -> [OutlierGroup]? {
        if let outlierGroups {
            let groups = await outlierGroups.getMembers()
            return groups.map {$0.value}
        }
        return nil
    }

    public func outlierGroupTrashList() async -> [OutlierGroup]? {
        if let outlierGroups {
            let groups = await outlierGroups.getTrash()
            return groups.map {$0.value}
        } else {
            try? await loadOutliers()
            if let outlierGroups {
                let groups = await outlierGroups.getTrash()
                return groups.map {$0.value}
            } else {
                Log.w("NO GROUPS")
            }
        }
        return nil
    }

    // used for saving different images of blobs
    public func saveImages(for blobs: [Blob], as frameImageType: FrameViewMode) async throws {
        var blobImageData = ImageBuffer<UInt8>(width: width, height: height)
        for blob in blobs {
            for pixel in await blob.getPixels() {
                let imageIntensity = pixel.uInt16Value >> 8
                blobImageData[pixel.y*width+pixel.x] = UInt8(imageIntensity)//0xFF // make different per blob?
            }
        }
        let fuck = frameImageType
        if let blobImage = blobImageData.image {

            let (_) = await (/*try imageAccessor.save(blobImage, as: fuck,
                               atSize: .original, overwrite: true),*/
              try imageAccessor.save(blobImage,
                                     frameIndex: frameIndex,
                                     as: fuck,
                                     atSize: .preview, overwrite: true))
        } else {
            Log.w("frame \(frameIndex) unable to get blob image to save")
        }
        
    }

    public func applyRazor(in boundingBox: BoundingBox, includingTrash: Bool) async throws {
        /*
         - find all outliers that have some match with this bounding box
         - remove them from outlier groups list
         - convert them to blobs
         - do intersection with bounding box to create new blob
         - convert all of them back to outlier groups
         */

        if await outlierGroups?.applyRazor(in: boundingBox,
                                           includingTrash: includingTrash) ?? false
        {
            await frame?.markAsChanged()

            try await outlierGroups?.writeOutliersBinary(to: await outliersDirname)

            await updateUserSlices(with: boundingBox)

            await frame?.updateCombineSubjects()            
        }
    }

    private func updateUserSlices(with newSlice: BoundingBox) async {

        if userSlices == nil { await loadUserSlices() }

        guard let userSlices else { return }
        
        // XXX update this to load them first if not present
        
        var newSlices: [BoundingBox] = [newSlice]

        // append bounding box to this frame's razor list
        // if any overlap, keep the latest
            
        for slice in userSlices {
            if slice.overlap(with: newSlice) == nil {
                newSlices.append(slice)
            }
        }

        self.userSlices = newSlices
        await saveUserSlices()
    }
    
    public func saveUserSlices() async {
        guard let userSlices else { return }
        let encoder = JSONEncoder()
        do {
            let jsonData = try encoder.encode(userSlices)

            let fullPath = await userSliceFilename
            if FileManager.default.fileExists(atPath: fullPath) {
                try FileManager.default.removeItem(atPath: fullPath)
            } 
            Log.i("creating \(fullPath)")                      
            _ = FileManager.default.createFile(atPath: fullPath, contents: jsonData, attributes: nil)
        } catch {
            Log.e("\(error)")
        }
    }
    
    public func loadUserSlices() async {
        do {
            let slices_url = NSURL(fileURLWithPath: await userSliceFilename,
                                   isDirectory: false) as URL
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: slices_url))
            let decoder = JSONDecoder()
            userSlices = try decoder.decode([BoundingBox].self, from: data)
        } catch {
            //Log.e("cannot load user slices: \(error)")

            mkdir(await userSliceDirname)
        }
    }

    public var outliersDirname: String {
        get async {
            let config = await configManager.config()
            return "\(config.outlierOutputDirname)/\(frameIndex)"
        }
    }

    public func promoteDust(in boundingBox: BoundingBox) async throws -> [OutlierGroup] {
        if outlierGroups == nil {
            outlierGroups = OutlierGroups(
              frameIndex: frameIndex,
              config: await configManager.config()
            )
        }
        
        guard let outlierGroups else { return [] }
        let ret = await outlierGroups.promoteDust(in: boundingBox)

        await frame?.markAsChanged()
        await frame?.updateCombineSubjects()

        try await outlierGroups.writeOutliersBinary(to: await outliersDirname)

        return ret
    }

    
    public func deleteOutliers() async throws {
        // Through the type rather than through `outlierGroups?`: whether this frame's
        // groups happen to be loaded in memory has nothing to do with whether there is a
        // file to delete, and going through the optional meant a frame that had never been
        // looked at kept its stale binary — which the next run loaded.
        try OutlierGroups.removeOutliersBinary(from: await self.outliersDirname)
        outlierGroups = nil
    }
    
    public func deleteOutliers(in boundingBox: BoundingBox) async throws {
        await outlierGroups?.deleteOutliers(in: boundingBox)

        await frame?.markAsChanged()
        
        try await outlierGroups?.writeOutliersBinary(to: await outliersDirname)
        // XXX add y-axis here too
    }

    // Mark - UI

    /*
     UI related methods
     */
    
    public func applyDecisionTreeToAutoSelectedOutliers(includingTrash: Bool,
                                                        overwrite: Bool = false,
                                                        minimumSize: Int? = nil) async {
        if let classifier = await currentClassifier.get(for: .all) {
            _ = await foreachOutlierGroupMulti(includingTrash: includingTrash) { group, isInTrash in
                if let minimumSize,
                   group.size < minimumSize { return false }
                
                var apply = true
                if !overwrite,
                   let shouldRemove = await group.shouldRemove() {
                    switch shouldRemove {
                    case .userSelected(_):
                        // leave user selected ones in place
                        apply = false
                    default:
                        break
                    }
                }
                var didChange = false
                if apply {
                    Log.d("applying decision tree")
                    if isInTrash {
                        await self.outlierGroups?.promoteFromTrash(group)
                        didChange = true
                    }
                    if await group.shouldRemove(.fromClassifier(await classifier.classification(of: group))) { didChange = true }
                }
                return didChange
            }
        } else {
            Log.w("no classifier")
        }
    }

    public func clearOutlierGroupValueCaches(includingTrash: Bool) async {
        _ = await foreachOutlierGroupMulti(includingTrash: includingTrash) { group, _ in
            await group.clearFeatureValueCache()
            return false
        }
    }

    public func applyDecisionTreeToAllOutliers(
      overwrite: Bool = true,
      minimumSize: Int? = nil
    ) async {
      Log.d("frame \(frameIndex) applyDecisionTreeToAll \(await outlierGroups?.members.count ?? 0) Outliers")
        let startTime = Date().timeIntervalSince1970
        if let outlierGroups {
            let groups = await outlierGroups.getMembers()
            let classifierFrame = frame
            await Task.detached(priority: .userInitiated) {
                guard let classifierFrame else { return }
                let classifier = OutlierClassifier(frame: classifierFrame)

                var values = Array(groups.values)

                if let minimumSize {
                    values = values.filter { $0.size > minimumSize }
                }

                await classifier.classifyAll(values, overwrite: overwrite)
                let endTime = Date().timeIntervalSince1970
                Task { @MainActor in
                    await classifierFrame.updateCombineSubjects()
                }

                Log.i("frame \(classifierFrame.frameIndex) spent \(endTime - startTime) seconds classifing outlier groups");
            }.value
        } else {
            Log.w("no classifier")
        }
        Log.d("frame \(frameIndex) DONE applyDecisionTreeToAllOutliers")
    }
    
    public func userSelectAllOutliers(toShouldRemove shouldRemove: Bool,
                                      includingTrash: Bool) async -> Bool
    {
        let didChange = await Task.detached(priority: .userInitiated) {
            await self.foreachOutlierGroupMulti(includingTrash: includingTrash) { group, isInTrash in
                var didChange = false
                if isInTrash {
                    await self.outlierGroups?.promoteFromTrash(group)
                    didChange = true
                }
                if await group.shouldRemove(.userSelected(shouldRemove)) { didChange = true }
                return didChange
            }
        }.value
        Task { @MainActor in
            if didChange {
                await frame?.markAsChanged() // only mark as changed if we have changed something
            }
            await frame?.updateCombineSubjects()
        }
        return didChange
    }

    public func userSelectUndecidedOutliers(toShouldRemove shouldRemove: Bool,
                                            includingTrash: Bool) async -> Bool
    {
        let didChange = await Task.detached(priority: .userInitiated) {
            await self.foreachOutlierGroupMulti(includingTrash: includingTrash) { group, isInTrash in
                var didChange = false
                if await group.shouldRemove() == nil {
                    if isInTrash {
                        await self.outlierGroups?.promoteFromTrash(group)
                        didChange = true
                    }
                    if await group.shouldRemove(.userSelected(shouldRemove)) { didChange = true }
                }
                return didChange
            }
        }.value
        Task { @MainActor in
            if didChange {
                await frame?.markAsChanged()
            }
            await frame?.updateCombineSubjects()
        }
        return didChange
    }

    public func userSelectAllOutliers(toShouldRemove shouldRemove: Bool,
                                      overlapping group: OutlierGroup) async -> Bool
    {
        if outlierGroups == nil {
            outlierGroups = OutlierGroups(
              frameIndex: frameIndex,
              config: await configManager.config()
            )
        }
        
        guard let outlierGroups else { return false }

        var didChange = false
        for group in await outlierGroups.groups(overlapping: group) {
            if await group.shouldRemove(.userSelected(shouldRemove)) { didChange = true }
        }
        Task { @MainActor in
            if didChange {
                await frame?.markAsChanged()
            }
            await frame?.updateCombineSubjects()
        }
        return didChange
    }
    
    public func userSelectAllOutliers(toShouldRemove shouldRemove: Bool,
                                      between startLocation: CGPoint,
                                      and endLocation: CGPoint,
                                      includingTrash: Bool) async
    {
        let didChange = await foreachOutlierGroupMulti(
          between: startLocation,
          and: endLocation,
          includingTrash: includingTrash)
        { group, isInTrash in
            var didChange = false
            if isInTrash {
                await self.outlierGroups?.promoteFromTrash(group)
                didChange = true
            }
            if await group.shouldRemove(.userSelected(shouldRemove)) { didChange = true }
            return didChange
        }
        Task { @MainActor in
            if didChange {
                await frame?.markAsChanged()
            }
            await frame?.updateCombineSubjects()
        }
    }
    // Mark - File output

    // write out just the OutlierGroupValueMatrix, which just what
    // the decision tree needs, and not very large
    public func writeOutlierValuesCSV() async throws {
        try await fileSystemMonitor.save() { try await self.writeOutlierValuesCSVInt() }
    }
    
    private func writeOutlierValuesCSVInt() async throws {

        Log.d("frame \(frameIndex) writeOutlierValuesCSV")
        let config = await configManager.config()
        
        if config.writeOutlierGroupFiles {
            // write out the decision tree value matrix too
            Log.d("frame \(frameIndex) writeOutlierValuesCSV 1")

            let frameOutlierDir = "\(config.outlierOutputDirname)/\(frameIndex)"
            let csvFilename = "\(frameOutlierDir)/\(CondensedOutlierGroupValueMatrix.outlierDataFilename)"

            let csvFrame = frame
            await Task.detached(priority: .userInitiated) {
                guard let csvFrame else { return }
                do {
                    try await writeOutlierValuesCSVPrivate(to: csvFilename,
                                                           frameOutlierDir: frameOutlierDir,
                                                           frame: csvFrame)
                } catch {
                    Log.e("frame \(csvFrame.frameIndex) unable to write outlier values csv to \(csvFilename)")
                }
            }.value
        }
        Log.d("frame \(frameIndex) DONE writeOutlierValuesCSV")
    }

    public func writeOutliersRemoveReasons() async {
        let config = await configManager.config()
        if config.writeOutlierGroupFiles {
            do {
                try await fileSystemMonitor.save() {
                    try await outlierGroups?.write(to: config.outlierOutputDirname)
                }
            } catch {
                Log.e("error \(error)")
            }                
        }
    }

}

fileprivate func writeOutlierValuesCSVPrivate(to csvFilename: String,
                                              frameOutlierDir: String,
                                              frame: FrameAirplaneRemover) async throws
{
    // check to see if both of these files exist already
    if FileManager.default.fileExists(atPath: csvFilename) {
        Log.i("frame \(frame.frameIndex) not recalculating outlier values with existing files")
    } else {
        let valueMatrix = await CondensedOutlierGroupValueMatrix(for: frame)

        if let outliers = await frame.outlierGroupList() {
            Log.d("frame \(frame.frameIndex) writeOutlierValuesCSV 1a \(outliers.count) outliers")
            let startTime = Date().timeIntervalSince1970
            // XXX start time
            
            for (index, outlier) in outliers.enumerated() {
                if index % 100 == 0 {
                    let duration = Date().timeIntervalSince1970 - startTime
                    Log.d("frame \(frame.frameIndex) writeOutlierValuesCSV 1b \(index) after \(duration) seconds")
                }
                await valueMatrix.append(outlierGroup: outlier)
            }
        }
        Log.d("frame \(frame.frameIndex) writeOutlierValuesCSV 2a")
        // append trash values too
        if let trash = await frame.getOutlierGroups()?.getTrash().values {
            Log.d("frame \(frame.frameIndex) writeOutlierValuesCSV appending trash")
            for outlier in trash {
                await valueMatrix.append(outlierGroup: outlier)
            }
        }
        Log.d("frame \(frame.frameIndex) writeOutlierValuesCSV 2")

        try await valueMatrix.writeCSV(to: frameOutlierDir)
        Log.d("frame \(frame.frameIndex) writeOutlierValuesCSV 3")
    }
}


fileprivate let outliersFileSystemMonitor = FileSystemMonitor(max: 50)

fileprivate struct OutlierSorter: Sendable {
    public let classification: Double
    public let outlier: OutlierGroup
}

// executes the classification of .isolated blobs in parallel
fileprivate class OutlierClassifier {

    let frameIndex: Int
    let frame: FrameAirplaneRemover
    
    public init(frame: FrameAirplaneRemover)
    {
        frameIndex = frame.frameIndex
        self.frame = frame
    }

    // classifies OutlierGroup actors in OutlierGroups, marking them as removable or not
    // uses the .all classifier, which digs into neighboring frames for more data
    func classifyAll(_ outliers: [OutlierGroup], overwrite: Bool = false) async {
//        await Task.detached(priority: .userInitiated) {
        //let dataHarvester = await FrameDataHarvester(for: self.frame)
            await withTaskGroup(of: Void.self) { taskGroup in
                guard let classifier = await currentClassifier.get(for: .all) else { return }

                let max = 10            // XXX hardcoded constant

                if outliers.count > 0 {
                    for chunk in outliers.split(into: max) {
                        taskGroup.addTask {
                            for group in chunk {
                                if await group.shouldRemove() == nil || overwrite {
                                    // only apply classifier when no other classification is otherwise present
                                    //let featureData = await group.featureData(dataHarvester: dataHarvester)
                                    let classification = await classifier.classification(of: group)
                                    _ = await group.shouldRemove(.fromClassifier(classification))
                                }
                            }
                        }
                    }
                }
                await taskGroup.waitForAll()
            }
//        }.value
    }

    // classifies blobs with the .isolated classifier, and promotes them to separate groups
    func promoteAndClassify(_ blobs: [Blob],
                            trashLevel: Double = 0.0,
                            smallTrashMax: Int = 20) async
      -> ([OutlierGroup], [OutlierGroup], TimeInterval, TimeInterval, Int)
    {
        let frame = self.frame
        let frameIndex = frameIndex
        // Captured before detaching, like `frame` above: the work below runs off
        // this actor and cannot reach `self`.
        let imageWidth = Double(frame.width)
        let imageHeight = Double(frame.height)
        
        return await Task.detached(priority: .userInitiated) {
            return await withTaskGroup(of: ([OutlierSorter], TimeInterval, TimeInterval, Int).self) { taskGroup in

                // promote found blobs to outlier groups for further processing
                let classifier = await currentClassifier.get(for: .isolated) 

                //let dataHarvester = await FrameDataHarvester(for: frame, treeType: .isolated)

                let max = 20            // XXX hardcoded constant

                if blobs.count > 0 {
                    
                    for chunk in blobs.split(into: max) {
                        taskGroup.addTask {
                            var featureDataTime: TimeInterval = 0
                            var classificationTime: TimeInterval = 0
                    
                            var ret: [OutlierSorter] = []
                            for blob in chunk {

                                // make outlier group from this blob
                                let outlierGroup = await blob.outlierGroup(at: frameIndex,
                                                                          imageWidth: imageWidth,
                                                                          imageHeight: imageHeight)

                                // vertical position on screen of the center of this outlier group
                                // 0 is top
                                // 1 is bottom
                                let centerY = Double(outlierGroup.bounds.center.y)/imageHeight

                                /*
                                 to speed things up, smaller blobs are discarded.
                                 minimum blob size is relative to the y position on screen of the outlier

                                 min at the top of the screen - 20
                                 min at the middle of the screen - 10
                                 min at the bottom of the screen - 0
                                 
                                 */
                                let minSize = Int(Double(smallTrashMax)*(1.0 - centerY))

                                // don't process smaller blobs any further
                                if outlierGroup.size <= minSize {
                                    ret.append(.init(classification: -1, // classified based on size only
                                                     outlier: outlierGroup))
                                    continue
                                }
                           
                                //Log.i("frame \(frameIndex) promoting \(blob) to outlier group \(outlierGroup.id) line \(String(describing: blob.line))")
                                await outlierGroup.set(frame: frame)

                                // when promoting blobs to outlier groups, we first use the .isolated classifier
                                // and separate blobs into two groups based upon a threshold in this classification.
                                // one group is the trash, which has a very high likelyhood of not being useful
                                // the other group are the outlier groups that will get processed further

                                if let classifier {
                                    let startTime = Date().timeIntervalSince1970

                                    let featureTime = Date().timeIntervalSince1970
                                    let classification = await classifier.classification(of: outlierGroup)
                                    let classTime = Date().timeIntervalSince1970

                                    // -1 classification means bad
                                    //  1 classification means good
                                    //  0 is undecided
                                    ret.append(OutlierSorter(classification: classification,
                                                             outlier: outlierGroup))
                                    featureDataTime += featureTime - startTime
                                    classificationTime += classTime - featureTime
                                } else {
                                    Log.w("No .isolated classifier!!") // assume it's good
                                  ret.append(.init(classification: 1,
                                                   outlier: outlierGroup))
                                }
                            }
                            return (ret,
                                    featureDataTime,
                                    classificationTime,
                                    chunk.count)
                        }
                    }
                }

                var good: [OutlierGroup] = []
                var bad: [OutlierGroup] = []

                var totalFeatureTime: TimeInterval = 0
                var totalClassificationTime: TimeInterval = 0
                var totalOutliers: Int = 0
                
                for await (values, featureTime, classTime, chunkCount) in taskGroup {
                    totalFeatureTime += featureTime
                    totalClassificationTime += classTime
                    totalOutliers += chunkCount
                    for value in values {
                        if value.classification > trashLevel {
                            // it's good
                            good.append(value.outlier)
                        } else {
                            // it's bad
                            bad.append(value.outlier)
                        }
                    }
                }

                return (good, bad, totalFeatureTime, totalClassificationTime, totalOutliers)
            }
        }.value
    }
}

// closure returns true if an outlier was changed
fileprivate func foreachOutlier(in outliers: [OutlierGroup],
                                with trash: [OutlierGroup],
                                _ closure: @Sendable @escaping (OutlierGroup, Bool) async -> Bool) async -> Bool {
    return await withTaskGroup(of: Bool.self) { taskGroup in
        var didChange = false         // did anything change?
        // max number of concurrent tasks (for each outliers and trash)
        let max = 10            // XXX hardcoded constant

        let outlierChunkSize = outliers.count/max
        let trashChunkSize = trash.count/max

        if outliers.count > 0 {
            for chunk in outliers.chunks(of: outlierChunkSize) {
                taskGroup.addTask() {
                    var didChange = false
                    for group in chunk {
                        // false: these are members, not trash.  The trash loop below passes true.
                        if await closure(group, false) { didChange = true }
                    }
                    return didChange
                }
            }
        }
        if trash.count > 0 {
            for chunk in trash.chunks(of: trashChunkSize) {
                taskGroup.addTask() {
                    var didChange = false
                    for group in chunk {
                        if await closure(group, true) { didChange = true }
                    }
                    return didChange
                }
            }
        }
        for await (result) in taskGroup { if result { didChange = true } }
        return didChange
    }
}
