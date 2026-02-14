import SwiftUI
import StarCore
import logging

struct LeftPanel: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    @Environment(FrameGraphViewModel.self) var frameGraphViewModel: FrameGraphViewModel
    
    let foobar = 134.0/255.0 // XXX make a custom color from these
    let foobar2 = 138.0/255.0

    @State private var isVisible: Bool = false
    @State private var imageCacheHits: UInt = 0
    @State private var imageCacheMisses: UInt = 0
    @State private var imageCacheMap: [Int: Int] = [:]

    var basicImageStats: (Int, Int) { // memory usage, number of images
        var totalImageCount: Int = 0
        var totalByteCount: Int = 0
        for (size, count) in imageCacheMap {
            totalByteCount += size * count
            totalImageCount += count
        }
        return (totalByteCount, totalImageCount)
    }

    func string(for byteCount: Int) -> String {
        //Log.d("string(for: byteCount \(byteCount))")
        if byteCount < 0 {
            return "0 bytes"    // can go negative because of temporarily mismatched data
        } else if byteCount < 1024 {
            return "\(byteCount) bytes"
        } else if byteCount < (1024*1024) {
            return "\(byteCount/1024) kb"
        } else if byteCount < (1024*1024*1024) {
            return "\(byteCount/(1024*1024)) mb"
        } else if byteCount < (1024*1024*1024*1024) {
            let str = String(format: "%.1f", Double(byteCount)/(1024*1024*1024))
            return "\(str) gb"
        } else {// if byteCount < 1024^5 {
            let str = String(format: "%.2f", Double(byteCount)/(1024*1024*1024*1024))
            return "\(str) tb"
        }
    }
    
    var body: some View {
        Group {
            if viewModel.leftPanelShowing {
                self.openView
            } else {
                self.closedView
            }
        }
    }

    var openView: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .trailing) {

            ScrollView() {
                VStack(alignment: .leading) {

                    self.processingButtons

                    ProcessingProgressBarView()
                      .frame(maxWidth: 200, alignment: .leading)
                     //.frame(maxWidth: .none)
                    
                    Space(height: 10)

                    AlignmentDeviationChart(
                      frames: viewModel.starAlignmentInfo,
                      foregroundColor: .white
                    )
                      .frame(width: 200, height: 200)
                    

                    Space(height: 10)
                    
                    self.processingStateView

                    Space(height: 10)

                    self.imageCacheView

                    Space(height: 10)

                    self.operationQueueView
                    
                    Space(height: 10)
                    /*

                     add

                     imageCache.receiveUpdates() { hits, misses, map
                     }

                     in didAppear

                     and 

                     imageCache.receiveUpdates(nil)

                     on disappear

                     then show a collapsable view here that shows only number and
                     size when collapsed, and full details when opened.

                     */
                    
                    self.frameModeView
                    
                }
                //                          .frame(maxWidth: 200)
            }
              .defaultScrollAnchor(.bottom)
           //   .frame(maxHeight: .infinity, alignment: .bottom)

              .onAppear {
                  isVisible = true
                  self.updateImageCacheStats()
              }
              .onDisappear() {
                  isVisible = false
              }
            Spacer()
            
            Button() {
                viewModel.leftPanelShowing = false
            } label: {
                Image(systemName: "chevron.left.2")
                  .foregroundColor(.gray)
            }
              .buttonStyle(PlainButtonStyle())
              .cursor(.resizeLeft)
        }
          .padding(10)
          .background(Color(white: 0.22).zIndex(0))
          .frame(maxHeight: .infinity, alignment: .bottom)
        
    }

    func updateImageCacheStats() {
        guard self.isVisible else { return }
        Task.detached {
            let (hits, misses, map) = await imageCache.prepareUpdate()
            Task { @MainActor in
                // update values
                self.imageCacheHits = hits
                self.imageCacheMisses = misses
                self.imageCacheMap = map
                
                try? await Task.sleep(nanoseconds: 2_000_000_000) // XXX make a param
                self.updateImageCacheStats()
            }
        }
    }
    
    var processButtonDisabled: Bool {
        let unprocessed = viewModel.frameStateMap[.unprocessed]?.count ?? 0
        let horizon = viewModel.frameStateMap[.horizonDetected]?.count ?? 0

        return (unprocessed == 0 && horizon != viewModel.frames.count) || viewModel.isProcessingFrames || viewModel.isRenderingVideo
    }

    var updateButtonDisabled: Bool {
        let userModified = viewModel.frameStateMap[.userModified]?.count ?? 0
        return userModified == 0 || viewModel.isProcessingFrames || viewModel.isRenderingVideo 
    }

    var renderButtonDisabled: Bool {
        let complete = viewModel.frameStateMap[.complete]?.count ?? 0
        return complete != viewModel.frames.count || viewModel.isProcessingFrames || viewModel.isRenderingVideo
    }
    
    var processingButtons: some View {
        VStack(alignment: .leading) {
            let unprocessed = viewModel.frameStateMap[.unprocessed]?.count ?? 0
            let horizonCount = viewModel.frameStateMap[.horizonDetected]?.count ?? 0

            Button() {
                viewModel.shouldShowProcessingSettings = true
            } label: {
                Text("Process frames")
            }
              .disabled(processButtonDisabled)
              .if(!processButtonDisabled) { 
                  $0.buttonStyle(.borderedProminent)
                    .tint(.blue)
              }
            
            
            let userModified = viewModel.frameStateMap[.userModified]?.count ?? 0
            /*
            Button() {
                // XXX this has no max number of processes :(
                Task {
                  await viewModel.processAll()
                }
            } label: {
                Text("Update \(userModified) frames")
            }
              .disabled(updateButtonDisabled)
              .if(!updateButtonDisabled) { view in
                  view
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
              }
*/
            let complete = viewModel.frameStateMap[.complete]?.count ?? 0

            Button() {
                Log.d("render video")
                viewModel.renderVideoSheetShowing = true
                /*

                 need to keep track of ffmpeg parameters when we load a video
                 (get rid of script to render)

                 default ffmpeg parameters to prores high quailty in config

                 have ui that allows users to change codec and frame rate, etc.

                 show render progress in UI somehow
                 
                 */

                viewModel.isRenderingVideo = false
                
            } label: {
                Text("render video from \(viewModel.frames.count) frames")
            }
              .disabled(renderButtonDisabled)
              .if(!renderButtonDisabled) { view in
                  view
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
              }
        }
    }

    var operationQueueView: some View {
        VStack(alignment: .leading) {
            let hasHorizonOps = frameGraphViewModel.hasOperations(
              ofType: .horizon,
              atMax: viewModel.frames.count
            )
            let hasStarKeypointOps = frameGraphViewModel.hasOperations(
              ofType: .starKeypoints,
              atMax: viewModel.frames.count
            )
            let hasEarthKeypointOps = frameGraphViewModel.hasOperations(
              ofType: .earthKeypoints,
              atMax: viewModel.frames.count
            )
            let hasStarHomographyOps = frameGraphViewModel.hasOperations(
              ofType: .starHomography,
              atMax: viewModel.frames.count
            )
            let hasEarthHomographyOps = frameGraphViewModel.hasOperations(
              ofType: .earthHomography,
              atMax: viewModel.frames.count
            )

            let hasOutlierOps = frameGraphViewModel.hasOperations(
              ofType: .outliers,
              atMax: viewModel.frames.count
            )
            let hasMergeOps = frameGraphViewModel.hasOperations(
              ofType: .merge,
              atMax: viewModel.frames.count
            )

            if hasHorizonOps ||
               hasStarKeypointOps ||
               hasEarthKeypointOps ||
               hasEarthKeypointOps ||
               hasStarHomographyOps ||
               hasEarthHomographyOps ||
               hasOutlierOps ||
               hasMergeOps
            {
                Grid(alignment: .trailing) {
                    GridRow {
                        HStack {
                            Text("step")
                              .foregroundColor(.white)
                            Spacer()
                        }
                        ForEach(OperationState.allCases, id: \.self) { state in
                            Text(state.rawValue)
                              .foregroundColor(.white)
                        }
                    }
                    Divider()
                      .foregroundColor(.white)
                      .frame(maxWidth: .infinity)

                    if hasHorizonOps {
                        operationView(of: .horizon)
                    }
                    if hasStarKeypointOps {
                        operationView(of: .starKeypoints)
                    }
                    if hasEarthKeypointOps {
                        operationView(of: .earthKeypoints)
                    }

                    if hasStarHomographyOps {
                        operationView(of: .starHomography)
                    }
                    if hasEarthHomographyOps {
                        operationView(of: .earthHomography)
                    }
                    if hasOutlierOps {
                        operationView(of: .outliers)
                    }
                    if hasMergeOps {
                        operationView(of: .merge)
                    }
                }
            }
        }
          .fixedSize(horizontal: true, vertical: false)
    }

    func operationView(of type: OperationType) -> some View {
        GridRow {
            HStack {
                Text(type.rawValue)
                  .foregroundColor(.white)
                Spacer()
            }  
            ForEach(OperationState.allCases, id: \.self) { state in
                let num = frameGraphViewModel.numberOfOperations(
                  ofType: type,
                  in: state
                )
                Text("\(num)")
                  .foregroundColor(.white)
                  .opacity(num == 0 ? 0 : 1)
            }
        }
    }
    
    var imageCacheView: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading) {
            Text("Non Cached Image stats")
              .foregroundColor(.white)
            Space(height: 4)

            let (memoryBytesUsed, imageCount) = self.basicImageStats

            let memoryString = string(for: memoryBytesUsed)
            
            Text("\(string(for: viewModel.totalMatBytes-memoryBytesUsed)) used by \(viewModel.totalMatInstances - imageCount) images")
              .foregroundColor(viewModel.totalMatInstances == 0 ? .gray : .green)
            Space(height: 6)
            
            Text("Cached Image stats")
              .foregroundColor(.white)
            Space(height: 4)

            if viewModel.showAllImageCacheStats {
                // show all image cache stats
                Text("\(memoryString) used by \(imageCount) images")
                  .foregroundColor(imageCount == 0 ? .gray : .green)

                Text("\(imageCacheHits) cache hits")
                  .foregroundColor(imageCacheHits == 0 ? .gray : .green)
                Text("\(imageCacheMisses) cache misses")
                  .foregroundColor(imageCacheMisses == 0 ? .gray : .red)
                ForEach(imageCacheMap.keys.sorted { $0 > $1 }, id: \.self) { key in
                    let sizeString = string(for: key)
                    if let count = imageCacheMap[key] {
                        Text("\(count) \(sizeString) images")
                          .foregroundColor(.yellow)
                    }
                }
                
                // XXX add more here
            } else {
                // not all stats, just basics
                Text("\(memoryString) used by \(imageCount) images")
                  .foregroundColor(.gray)
            }
            
            Spacer()
              .frame(maxHeight: 10)
            
            ExpandUpButton($viewModel.showAllImageCacheStats)
        }
    }
    
    var processingStateView: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading) {
            Text("Processing stats")
              .foregroundColor(.white)
            Spacer()
              .frame(maxHeight: 4)
            Grid(alignment: .leading) {
                if viewModel.showAllFrameProcessingStates {
                    // show all the detailed processing states
                    ForEach(FrameProcessingState.allCases, id: \.self) { state in
                        GridRow {
                            let count = viewModel.frameStateMap[state]?.count ?? 0
                            let color: Color = count == 0 ? .gray : .white
                            Text("\(count)")
                              .foregroundColor(color)
                            Text(state.message)
                              .foregroundColor(color)
                        }
                    }
                } else {
                    // just show unprocessed, processing, and complete
                    GridRow {
                        let count = viewModel.frameStateMap[.unprocessed]?.count ?? 0
                        let color: Color = count == 0 ? .gray : .white
                        Text("\(count)")
                          .foregroundColor(color)
                        Text(FrameProcessingState.unprocessed.message)
                          .foregroundColor(color)
                    }

                    GridRow {
                        let color: Color = viewModel.numberOfFramesProcessingNow == 0 ? .gray : .white
                        Text("\(viewModel.numberOfFramesProcessingNow)")
                          .foregroundColor(color)
                        Text("processing")
                          .foregroundColor(color)
                    }

                    GridRow {
                        let count = viewModel.frameStateMap[.complete]?.count ?? 0
                        let color: Color = count == 0 ? .gray : .white
                        Text("\(count)")
                          .foregroundColor(color)
                        Text(FrameProcessingState.complete.message)
                          .foregroundColor(color)
                    }
                }
            }

            Spacer()
              .frame(maxHeight: 10)
            
            ExpandUpButton($viewModel.showAllFrameProcessingStates)
        }
    }
    
    var frameModeView: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading) {
            Text("Show:")
              .foregroundColor(.white)
            
            VerticalLimitedSelectionPicker(selection: $viewModel.frameViewMode) { value, isEnabled in
                let shouldShow = (!viewModel.showAllFrameViewModes && (value == .original || value == .final)) || viewModel.showAllFrameViewModes
                if shouldShow {
                    let hasImage = viewModel.currentFrameView.hasImage(type: value)
                    let color: Color =
                      hasImage ?
                      isEnabled ? .black : .yellow :
                      .gray

                    HStack {
                        Text(value.longName)
                          .foregroundColor(color)
                          .padding(4)
                          .onTapGesture { _ in
                              if hasImage {
                                  viewModel.frameViewMode = value
                              }
                          }
                        Spacer()
                    }
                }
            }
              .fixedSize(horizontal: true, vertical: false)
              .background(Color(red: foobar, green: foobar, blue: foobar2))
              .opacity(1.0)
              .disabled(viewModel.videoPlaying)
              .help("""
                      Show each frame as either the original   
                      or with star processing applied.
                      """) // XXX does this work anymore?
              .cornerRadius(5)

            Spacer()
              .frame(maxHeight: 10)

            ExpandUpButton($viewModel.showAllFrameViewModes)
              .cursor(.resizeUp)
        }
    }
    
    var closedView: some View {
        VStack(alignment: .leading) {
            // hidden with arrow to allow showing it
            Button() {
                viewModel.leftPanelShowing = true 
            } label: {
                Image(systemName: "chevron.right.2")
                  .foregroundColor(.gray)
            }
              .buttonStyle(PlainButtonStyle())
              .cursor(.resizeRight)
        }
          .padding(10)
          .background(Color(white: 0.22))
          .frame(maxHeight: .infinity, alignment: .bottomTrailing)
        
    }
}

extension View {                // XXX move this
    @ViewBuilder func `if`<Content: View>(
        _ condition: Bool,
        transform: (Self) -> Content
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

struct ProcessingProgressBarView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    
    let unprocessedColor: Color = .gray
    let processingColor: Color = .yellow
    let completeColor: Color = .green

    var body: some View {
        return GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let totalFrames = max(1, viewModel.frames.count)
            
            let unprocessed = CGFloat(viewModel.frameStateMap[.unprocessed]?.count ?? 0)
            let processing = CGFloat(viewModel.numberOfFramesProcessingNow)
            let complete = CGFloat(viewModel.frameStateMap[.complete]?.count ?? 0)

            
            let unprocessedWidth = totalWidth * (unprocessed / CGFloat(totalFrames))
            let processingWidth = totalWidth * (processing / CGFloat(totalFrames))
            let completeWidth = totalWidth * (complete / CGFloat(totalFrames))

            HStack(spacing: 0) {
                Rectangle()
                    .fill(completeColor)
                    .frame(width: completeWidth)

                Rectangle()
                    .fill(processingColor)
                    .frame(width: processingWidth)

                Rectangle()
                    .fill(unprocessedColor)
                    .frame(width: unprocessedWidth)

            }
            .cornerRadius(4)
            .frame(height: 10)
        }
        .frame(height: 10)
    }
}

