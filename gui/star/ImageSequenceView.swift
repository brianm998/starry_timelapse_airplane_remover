import SwiftUI
import StarCore

// XXX Fing global :(
fileprivate var video_play_timer: Timer?

fileprivate var current_video_frame = 0

enum VideoPlayMode: String, Equatable, CaseIterable {
    case forward
    case reverse
}

enum FrameViewMode: String, Equatable, CaseIterable {
    case original
    case processed

    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}

enum SelectionMode: String, Equatable, CaseIterable {
    case paint
    case clear
    case details
    
    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}

enum InteractionMode: String, Equatable, CaseIterable {
    case edit
    case scrub

    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}


// the main view of an image sequence 
// user can scrub, play, edit frames, etc

struct ImageSequenceView: View {
    @ObservedObject var viewModel: ViewModel

    @State private var interactionMode: InteractionMode = .scrub

    @State private var sliderValue = 0.0

    @State private var previousInteractionMode: InteractionMode = .scrub

    // enum for how we show each frame
    @State private var frameViewMode = FrameViewMode.processed

    // should we show full resolution images on the main frame?
    // faster low res previews otherwise
    @State private var showFullResolution = false

    @State private var showFilmstrip = true

    @State private var background_brightness: Double = 0.33
    @State private var background_color: Color = .gray

    @State private var rendering_current_frame = false
    @State private var rendering_all_frames = false
    @State private var updating_frame_batch = false

    @State private var video_playback_framerate = 30

    @State private var settings_sheet_showing = false
    @State private var paint_sheet_showing = false

    var body: some View {
        GeometryReader { top_geometry in
            ScrollViewReader { scroller in
                VStack {
                    let should_show_progress =
                      rendering_current_frame            ||
                      updating_frame_batch               ||
                      rendering_all_frames

                    // selected frame 
                    ZStack {
                        FrameView(viewModel: viewModel,
                                  interactionMode: self.$interactionMode,
                                  showFullResolution: self.$showFullResolution)
                          .frame(maxWidth: .infinity, alignment: .center)
                          .overlay(
                            ProgressView() // XXX this overlay sucks, change it
                              .scaleEffect(8, anchor: .center) // this is blocky scaled up 
                              .progressViewStyle(CircularProgressViewStyle(tint: .yellow))
                              .frame(maxWidth: 200, maxHeight: 200)
                              .opacity(should_show_progress ? 0.8 : 0)
                          )

                        // show progress bars on top of the image at the bottom
                        ProgressBars(viewModel: viewModel)
                    }
                    // buttons below the selected frame 
                    bottomControls(withScroll: scroller)
                    
                    if interactionMode == .edit,
                       showFilmstrip
                    {
                        Spacer().frame(maxHeight: 30)
                        // the filmstrip at the bottom
                        FilmstripView(viewModel: viewModel,
                                      imageSequenceView: self,
                                      scroller: scroller)
                          .frame(maxWidth: .infinity/*, alignment: .bottom*/)
                        Spacer().frame(maxHeight: 10/*, alignment: .bottom*/)
                    }

                    // scub slider at the bottom
                    if viewModel.image_sequence_size > 0 {
                        scrubSlider(withScroll: scroller)
                    }
                }
            }
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
              .padding()
              .background(background_color)
        }

          .alert(isPresented: $viewModel.showErrorAlert) {
              Alert(title: Text("Error"),
                    message: Text(viewModel.errorMessage),
                    primaryButton: .default(Text("Ok")) { viewModel.sequenceLoaded = false },
                    secondaryButton: .default(Text("Sure")) { viewModel.sequenceLoaded = false } )
              
          }
    }

    // slider at the bottom that scrubs the frame position
    func scrubSlider(withScroll scroller: ScrollViewProxy) -> some View {
        if interactionMode == .edit {
            Spacer().frame(maxHeight: 20)
        }
        let start = 0.0
        let end = Double(viewModel.image_sequence_size)
        return Slider(value: $sliderValue, in : start...end)
          .frame(maxWidth: .infinity, alignment: .bottom)
          .disabled(viewModel.video_playing)
          .onChange(of: sliderValue) { value in
              let frame_index = Int(sliderValue)
              Log.i("transition to \(frame_index)")
              // XXX do more than just this
              var new_frame_index = Int(value)
              //viewModel.current_index = Int(value)
              if new_frame_index < 0 { new_frame_index = 0 }
              if new_frame_index >= viewModel.frames.count {
                  new_frame_index = viewModel.frames.count - 1
              }
              let new_frame_view = viewModel.frames[new_frame_index]
              let current_frame = viewModel.currentFrame
              self.transition(toFrame: new_frame_view,
                              from: current_frame,
                              withScroll: scroller)
          }
    }

    // controls below the selected frame and above the filmstrip
    // XXX this is a mess, clean it up
    func bottomControls(withScroll scroller: ScrollViewProxy) -> some View {
        HStack {
            ZStack {
                VideoPlaybackButtons(viewModel: viewModel,
                                     imageSequenceView: self,
                                     scroller: scroller)
                  .frame(maxWidth: .infinity, alignment: .center)

                HStack {
                    VStack {
                        ZStack {
                            Button("") {
                                self.interactionMode = .edit
                            }
                              .opacity(0)
                              .keyboardShortcut("e", modifiers: [])

                            Button("") {
                                self.interactionMode = .scrub
                            }
                              .opacity(0)
                              .keyboardShortcut("s", modifiers: [])
                            
                        Picker("I will", selection: $interactionMode) {
                            ForEach(InteractionMode.allCases, id: \.self) { value in
                                Text(value.localizedName).tag(value)
                            }
                        }
                          .help("""
                                  Choose between quickly scrubbing around the video
                                  and editing an individual frame.
                                """)
                          .disabled(viewModel.video_playing)
                          .onChange(of: interactionMode) { mode in
                              Log.d("interactionMode change \(mode)")
                              switch mode {
                              case .edit:
                                  refreshCurrentFrame()
                                  
                              case .scrub:
                                  break
                              }
                          }
                          .frame(maxWidth: 220)
                          .pickerStyle(.segmented)
                        }
                        Picker("I will see", selection: $frameViewMode) {
                            ForEach(FrameViewMode.allCases, id: \.self) { value in
                                Text(value.localizedName).tag(value)
                            }
                        }
                          .disabled(viewModel.video_playing)
                          .help("""
                                  Show each frame as either the original   
                                  or with star processing applied.
                                """)
                          .frame(maxWidth: 220)
                          .help("show original or processed frame")
                          .onChange(of: frameViewMode) { pick in
                              Log.d("pick \(pick)")
                              refreshCurrentFrame()
                          }
                          .pickerStyle(.segmented)
                    }
                    
                    // outlier opacity slider
                    if self.interactionMode == .edit {
                        VStack {
                            Text("Outlier Group Opacity")
                            
                            Slider(value: $viewModel.outlierOpacitySliderValue, in : 0...1) { _ in
                                viewModel.update()
                            }
                              .frame(maxWidth: 140, alignment: .bottom)
                        }
                    }
                }
                  .frame(maxWidth: .infinity, alignment: .leading)

                if interactionMode == .edit {
                    HStack {
                        let frameView = viewModel.currentFrameView
                        VStack {
                            let num_purgatory = viewModel.frameSaveQueue?.purgatory.count ?? -1
                            if num_purgatory > 0 {
                                Text("\(num_purgatory) frames in purgatory")
                                  .foregroundColor(.yellow)
                            }
                            let num_saving = viewModel.frameSaveQueue?.saving.count ?? -1
                            if num_saving > 0 {
                                Text("saving \(num_saving) frames")
                                  .foregroundColor(.green)
                            }
                        }
                          .frame(alignment: .trailing)
                        VStack {
                            Text("frame \(viewModel.current_index)")
                            if let _ = frameView.outlierViews {
                                if let num_positive = frameView.numberOfPositiveOutliers {
                                    Text("\(num_positive) will paint")
                                      .foregroundColor(num_positive == 0 ? .white : .red)
                                }
                                if let num_negative = frameView.numberOfNegativeOutliers {
                                    Text("\(num_negative) will not paint")
                                      .foregroundColor(num_negative == 0 ? .white : .green)
                                }
                                if let num_undecided = frameView.numberOfUndecidedOutliers,
                                   num_undecided > 0
                                {
                                    Text("\(num_undecided) undecided")
                                      .foregroundColor(.orange)
                                }
                            }
                        }.frame(alignment: .trailing)
                          .id(frameView.numberOfPositiveOutliers)
                          .id(frameView.numberOfNegativeOutliers)
                          //.id(frameView.outlierViews)

                        let paint_action = {
                            Log.d("PAINT")
                            paint_sheet_showing = !paint_sheet_showing
                        }
                        Button(action: paint_action) {
                            buttonImage("square.stack.3d.forward.dottedline", size: 44)
                            
                        }
                          .buttonStyle(PlainButtonStyle())           
                          .frame(alignment: .trailing)
                          .help("effect multiple frames")
                        
                        let gear_action = {
                            Log.d("GEAR")
                            settings_sheet_showing = !settings_sheet_showing
                        }
                        Button(action: gear_action) {
                            buttonImage("gearshape.fill", size: 44)
                            
                        }
                          .buttonStyle(PlainButtonStyle())           
                          .frame(alignment: .trailing)
                          .help("settings")
                        
                        toggleViews()
                    }
                      .frame(maxWidth: .infinity, alignment: .trailing)
                      .sheet(isPresented: $settings_sheet_showing) {
                          SettingsSheetView(isVisible: self.$settings_sheet_showing,
                                            fast_skip_amount: $viewModel.fast_skip_amount,
                                            video_playback_framerate: self.$video_playback_framerate,
                                            fastAdvancementType: $viewModel.fastAdvancementType)
                      }
                      .sheet(isPresented: $paint_sheet_showing) {
                          MassivePaintSheetView(isVisible: self.$paint_sheet_showing,
                                                viewModel: viewModel)
                          { should_paint, start_index, end_index in
                              
                              updating_frame_batch = true
                              
                              for idx in start_index ... end_index {
                                  // XXX use a task group?
                                  setAllFrameOutliers(in: viewModel.frames[idx], to: should_paint)
                              }
                              updating_frame_batch = false
                              
                              Log.d("should_paint \(should_paint), start_index \(start_index), end_index \(end_index)")
                          }
                      }
                }
            }
        }
    }

    // used when advancing between frames
    func saveToFile(frame frame_to_save: FrameAirplaneRemover, completionClosure: @escaping () -> Void) {
        Log.d("saveToFile frame \(frame_to_save.frame_index)")
        if let frameSaveQueue = viewModel.frameSaveQueue {
            frameSaveQueue.readyToSave(frame: frame_to_save, completionClosure: completionClosure)
        } else {
            Log.e("FUCK")
            fatalError("SETUP WRONG")
        }
    }
    
    func renderAllFramesButton() -> some View {
        let action: () -> Void = {
            Task {
                await withLimitedTaskGroup(of: Void.self) { taskGroup in
                    var number_to_save = 0
                    self.rendering_all_frames = true
                    for frameView in viewModel.frames {
                        if let frame = frameView.frame,
                           let frameSaveQueue = viewModel.frameSaveQueue
                        {
                            await taskGroup.addTask() {
                                number_to_save += 1
                                frameSaveQueue.saveNow(frame: frame) {
                                    await viewModel.refresh(frame: frame)
                                    /*
                                     if frame.frame_index == viewModel.current_index {
                                     refreshCurrentFrame()
                                     }
                                     */
                                    number_to_save -= 1
                                    if number_to_save == 0 {
                                        self.rendering_all_frames = false
                                    }
                                }
                            }
                        }
                    }
                    await taskGroup.waitForAll()
                }
            }
        }
        
        return Button(action: action) {
            Text("Render All Frames")
        }
          .help("Render all frames of this sequence with current settings")
    }


    func renderCurrentFrame(_ closure: (() -> Void)? = nil) async {
        if let frame = viewModel.currentFrame {
            await render(frame: frame, closure: closure)
        }
    }
    
    func renderCurrentFrameButton() -> some View {
        let action: () -> Void = {
            Task { await self.renderCurrentFrame() }
        }
        
        return Button(action: action) {
            Text("Render This Frame")
        }
          .help("Render the active frame with current settings")
    }
    
    func applyDecisionTreeButton() -> some View {
        let action: () -> Void = {
            Task {
                do {
                    if let frame = viewModel.currentFrame {
                        await frame.applyDecisionTreeToAutoSelectedOutliers()
                        await render(frame: frame) {
                            Task {
                                await viewModel.refresh(frame: frame)
                                if frame.frame_index == viewModel.current_index {
                                    refreshCurrentFrame() // XXX not always still current
                                }
                                await viewModel.setOutlierGroups(forFrame: frame)
                                viewModel.update()
                            }
                        }
                    }
                }
            }
        }
        return Button(action: action) {
            Text("DT Auto Only")
        }
          .help("apply the outlier group decision tree to all selected outlier groups in this frame")
    }

    func outlierInfoButton() -> some View {
        let action: () -> Void = {
            Task {
                var _outlierGroupTableRows: [OutlierGroupTableRow] = []
                if let frame = viewModel.currentFrame {
                    await frame.foreachOutlierGroup() { group in
                        let new_row = await OutlierGroupTableRow(group)
                        _outlierGroupTableRows.append(new_row)
                        return .continue
                    }
                    await MainActor.run {
                        self.viewModel.outlierGroupWindowFrame = frame
                        self.viewModel.outlierGroupTableRows = _outlierGroupTableRows
                        self.viewModel.showOutlierGroupTableWindow()
                    }
                }
            }
            return
        }
        return Button(action: action) {
            Text("Outlier Info")
        }
          .help("Open the outlier info table window for all outlier groups in this frame")
    }

    func applyAllDecisionTreeButton() -> some View {
        Log.d("applyAllDecisionTreeButton")
        let action: () -> Void = {
            Log.d("applyAllDecisionTreeButton action")
            Task {
                Log.d("doh")
                do {
                    //Log.d("doh index \(viewModel.current_index) frame \(viewModel.frames[0].frame) have_all_frames \(viewModel.have_all_frames)")
                    if let frame = viewModel.currentFrame {
                        Log.d("doh")
                        await frame.applyDecisionTreeToAllOutliers()
                        Log.d("doh")
                        await render(frame: frame) {
                            Log.d("doh")
                            Task {
                                await viewModel.refresh(frame: frame)
                                if frame.frame_index == viewModel.current_index {
                                    refreshCurrentFrame() // XXX not always still current
                                }
                                await viewModel.setOutlierGroups(forFrame: frame)
                                viewModel.update()
                            }
                        }
                    } else {
                        Log.w("FUCK")
                    }
                }
            }
        }
        let shortcutKey: KeyEquivalent = "d"
        return Button(action: action) {
            Text("Decision Tree All")
        }
          .keyboardShortcut(shortcutKey, modifiers: [])
          .help("apply the outlier group decision tree to all outlier groups in this frame")
    }

    func goToFirstFrameButtonAction(withScroll scroller: ScrollViewProxy? = nil) {
        self.transition(toFrame: viewModel.frames[0],
                        from: viewModel.currentFrame,
                        withScroll: scroller)

    }

    func goToLastFrameButtonAction(withScroll scroller: ScrollViewProxy? = nil) {
        self.transition(toFrame: viewModel.frames[viewModel.frames.count-1],
                        from: viewModel.currentFrame,
                        withScroll: scroller)

    }

    func fastPreviousButtonAction(withScroll scroller: ScrollViewProxy? = nil) {
        if viewModel.fastAdvancementType == .normal {
            self.transition(numberOfFrames: -viewModel.fast_skip_amount,
                            withScroll: scroller)
        } else if let current_frame = viewModel.currentFrame {
            self.transition(until: viewModel.fastAdvancementType,
                            from: current_frame,
                            forwards: false,
                            withScroll: scroller)
        }
    }

    func fastForwardButtonAction(withScroll scroller: ScrollViewProxy? = nil) {

        if viewModel.fastAdvancementType == .normal {
            self.transition(numberOfFrames: viewModel.fast_skip_amount,
                            withScroll: scroller)
        } else if let current_frame = viewModel.currentFrame {
            self.transition(until: viewModel.fastAdvancementType,
                            from: current_frame,
                            forwards: true,
                            withScroll: scroller)
        }
    }

    func stopVideo(_ scroller: ScrollViewProxy? = nil) {
        video_play_timer?.invalidate()

        self.interactionMode = self.previousInteractionMode
        
        if current_video_frame >= 0,
           current_video_frame < viewModel.frames.count
        {
            viewModel.current_index = current_video_frame
            self.sliderValue = Double(viewModel.current_index)
        } else {
            viewModel.current_index = 0
            self.sliderValue = Double(viewModel.current_index)
        }
        
        viewModel.video_playing = false
        self.background_color = .gray
        
        if let scroller = scroller {
            // delay the scroller a little bit to allow the view to adjust
            // otherwise the call to scrollTo() happens when it's not visible
            // and is ignored, leaving the scroll view unmoved.
            Task {
                await MainActor.run {
                    scroller.scrollTo(viewModel.current_index, anchor: .center)
                }
            }
        }
    }
    
    func togglePlay(_ scroller: ScrollViewProxy? = nil) {
        viewModel.video_playing = !viewModel.video_playing
        if viewModel.video_playing {

            self.previousInteractionMode = self.interactionMode
            self.interactionMode = .scrub

            //self.background_color = .black
            
            Log.d("playing @ \(video_playback_framerate) fps")
            current_video_frame = viewModel.current_index

            switch self.frameViewMode {
            case .original:
                video_play_timer = Timer.scheduledTimer(withTimeInterval: 1/Double(video_playback_framerate),
                                                        repeats: true) { timer in
                    let current_idx = current_video_frame
                    // play each frame of the video in sequence
                    if current_idx >= self.viewModel.frames.count ||
                         current_idx < 0
                    {
                        stopVideo(scroller)
                    } else {

                        // play each frame of the video in sequence
                        viewModel.current_frame_image =
                          self.viewModel.frames[current_idx].preview_image

                        switch self.viewModel.videoPlayMode {
                        case .forward:
                            current_video_frame = current_idx + 1

                        case .reverse:
                            current_video_frame = current_idx - 1
                        }
                        
                        if current_video_frame >= self.viewModel.frames.count {
                            stopVideo(scroller)
                        } else {
                            self.sliderValue = Double(current_idx)
                        }
                    }
                }
            case .processed:
                video_play_timer = Timer.scheduledTimer(withTimeInterval: 1/Double(video_playback_framerate),
                                                        repeats: true) { timer in

                    let current_idx = current_video_frame
                    // play each frame of the video in sequence
                    if current_idx >= self.viewModel.frames.count ||
                       current_idx < 0
                    {
                        stopVideo(scroller)
                    } else {
                        viewModel.current_frame_image =
                          self.viewModel.frames[current_idx].processed_preview_image

                        switch self.viewModel.videoPlayMode {
                        case .forward:
                            current_video_frame = current_idx + 1

                        case .reverse:
                            current_video_frame = current_idx - 1
                        }
                        
                        if current_video_frame >= self.viewModel.frames.count {
                            stopVideo(scroller)
                        } else {
                            self.sliderValue = Double(current_idx)
                        }
                    }
                }
            }
        } else {
            stopVideo(scroller)
        }
    }
    
    func toggleViews() -> some View {
        HStack() {
            VStack(alignment: .leading) {
                Picker("selection mode", selection: $viewModel.selectionMode) {
                    ForEach(SelectionMode.allCases, id: \.self) { value in
                        Text(value.localizedName).tag(value)
                    }
                }
                  .help("""
                          What happens when outlier groups are selected?
                            paint   - they will be marked for painting
                            clear   - they will be marked for not painting
                            details - they will be shown in the info window
                        """)
                 .frame(maxWidth: 280)
                 .pickerStyle(.segmented)

                HStack {
                    Toggle("full resolution", isOn: $showFullResolution)
                      .onChange(of: showFullResolution) { mode_on in
                          refreshCurrentFrame()
                      }
                    Toggle("show filmstip", isOn: $showFilmstrip)
                }
            }
        }
    }


    func transition(numberOfFrames: Int,
                    withScroll scroller: ScrollViewProxy? = nil)
    {
        let current_frame = viewModel.currentFrame

        var new_index = viewModel.current_index + numberOfFrames
        if new_index < 0 { new_index = 0 }
        if new_index >= viewModel.frames.count {
            new_index = viewModel.frames.count-1
        }
        let new_frame_view = viewModel.frames[new_index]
        
        self.transition(toFrame: new_frame_view,
                        from: current_frame,
                        withScroll: scroller)
    }

    func transition(until fastAdvancementType: FastAdvancementType,
                    from frame: FrameAirplaneRemover,
                    forwards: Bool,
                    currentIndex: Int? = nil,
                    withScroll scroller: ScrollViewProxy? = nil)
    {
        var frame_index: Int = 0
        if let currentIndex = currentIndex {
            frame_index = currentIndex
        } else {
            frame_index = frame.frame_index
        }
        
        if (!forwards && frame_index == 0) ||  
           (forwards && frame_index >= viewModel.frames.count - 1)
        {
            if frame_index != frame.frame_index {
                self.transition(toFrame: viewModel.frames[frame_index],
                                from: frame,
                                withScroll: scroller)
            }
            return
        }
        
        var next_frame_index = 0
        if forwards {
            next_frame_index = frame_index + 1
        } else {
            next_frame_index = frame_index - 1
        }
        let next_frame_view = viewModel.frames[next_frame_index]

        var skip = false

        switch fastAdvancementType {
        case .normal:
            skip = false 

        case .skipEmpties:
            if let outlierViews = next_frame_view.outlierViews {
                skip = outlierViews.count == 0
            }

        case .toNextPositive:
            if let num = next_frame_view.numberOfPositiveOutliers {
                skip = num == 0
            }

        case .toNextNegative:
            if let num = next_frame_view.numberOfNegativeOutliers {
                skip = num == 0
            }

        case .toNextUnknown:
            if let num = next_frame_view.numberOfUndecidedOutliers {
                skip = num == 0
            }
        }
        
        // skip this one
        if skip {
            self.transition(until: fastAdvancementType,
                            from: frame,
                            forwards: forwards,
                            currentIndex: next_frame_index,
                            withScroll: scroller)
        } else {
            self.transition(toFrame: next_frame_view,
                            from: frame,
                            withScroll: scroller)
        }
    }
    
    func setAllCurrentFrameOutliers(to shouldPaint: Bool,
                                    renderImmediately: Bool = true)
    {
        let current_frame_view = viewModel.currentFrameView
        setAllFrameOutliers(in: current_frame_view,
                            to: shouldPaint,
                            renderImmediately: renderImmediately)
    }
    
    func setAllFrameOutliers(in frame_view: FrameViewModel,
                             to shouldPaint: Bool,
                             renderImmediately: Bool = true)
    {
        Log.d("setAllFrameOutliers in frame \(frame_view.frame_index) to should paint \(shouldPaint)")
        let reason = PaintReason.userSelected(shouldPaint)
        
        // update the view model first
        if let outlierViews = frame_view.outlierViews {
            outlierViews.forEach { outlierView in
                outlierView.group.shouldPaint = reason
            }
        }

        if let frame = frame_view.frame {
            // update the real actor in the background
            Task {
                await frame.userSelectAllOutliers(toShouldPaint: shouldPaint)

                if renderImmediately {
                    // XXX make render here an option in settings
                    await render(frame: frame) {
                        Task {
                            await viewModel.refresh(frame: frame)
                            if frame.frame_index == viewModel.current_index {
                                refreshCurrentFrame() // XXX not always current
                            }
                            viewModel.update()
                        }
                    }
                } else {
                    if frame.frame_index == viewModel.current_index {
                        refreshCurrentFrame() // XXX not always current
                    }
                    viewModel.update()
                }
            }
        } else {
            Log.w("frame \(frame_view.frame_index) has no frame")
        }
    }

    func refreshCurrentFrame() {
        // XXX maybe don't wait for frame?
        Log.d("refreshCurrentFrame \(viewModel.current_index)")
        let new_frame_view = viewModel.frames[viewModel.current_index]
        if let next_frame = new_frame_view.frame {

            // usually stick the preview image in there first if we have it
            var show_preview = true

            /*
            Log.d("showFullResolution \(showFullResolution)")
            Log.d("viewModel.current_frame_image_index \(viewModel.current_frame_image_index)")
            Log.d("new_frame_view.frame_index \(new_frame_view.frame_index)")
            Log.d("viewModel.current_frame_image_view_mode \(viewModel.current_frame_image_view_mode)")
            Log.d("self.frameViewMode \(self.frameViewMode)")
            Log.d("viewModel.current_frame_image_was_preview \(viewModel.current_frame_image_was_preview)")
             */

            if showFullResolution &&
               viewModel.current_frame_image_index == new_frame_view.frame_index &&
               viewModel.current_frame_image_view_mode == self.frameViewMode &&
               !viewModel.current_frame_image_was_preview
            {
                // showing the preview in this case causes flickering
                show_preview = false
            }
                 
            if show_preview {
                viewModel.current_frame_image_index = new_frame_view.frame_index
                viewModel.current_frame_image_was_preview = true
                viewModel.current_frame_image_view_mode = self.frameViewMode

                switch self.frameViewMode {
                case .original:
                    viewModel.current_frame_image = new_frame_view.preview_image//.resizable()
                case .processed:
                    viewModel.current_frame_image = new_frame_view.processed_preview_image//.resizable()
                }
            }
            if showFullResolution {
                if next_frame.frame_index == viewModel.current_index {
                    Task {
                        do {
                            viewModel.current_frame_image_index = new_frame_view.frame_index
                            viewModel.current_frame_image_was_preview = false
                            viewModel.current_frame_image_view_mode = self.frameViewMode
                            
                            switch self.frameViewMode {
                            case .original:
                                if let baseImage = try await next_frame.baseImage() {
                                    if next_frame.frame_index == viewModel.current_index {
                                        viewModel.current_frame_image = Image(nsImage: baseImage)
                                    }
                                }
                                
                            case .processed:
                                if let baseImage = try await next_frame.baseOutputImage() {
                                    if next_frame.frame_index == viewModel.current_index {
                                        viewModel.current_frame_image = Image(nsImage: baseImage)
                                    }
                                }
                            }
                        } catch {
                            Log.e("error")
                        }
                    }
                }
            }

            if interactionMode == .edit {
                // try loading outliers if there aren't any present
                let frameView = viewModel.frames[next_frame.frame_index]
                if frameView.outlierViews == nil,
                   !frameView.loadingOutlierViews
                {
                    frameView.loadingOutlierViews = true
                    viewModel.loading_outliers = true
                    Task.detached  {
                        let _ = try await next_frame.loadOutliers()
                        await MainActor.run {
                            Task {
                                await viewModel.setOutlierGroups(forFrame: next_frame)
                                frameView.loadingOutlierViews = false
                                viewModel.loading_outliers = viewModel.loadingOutlierGroups
                                viewModel.update()
                            }
                        }
                    }
                }
            }
        } else {
            Log.d("WTF for frame \(viewModel.current_index)")
            viewModel.update()
        }
    }
    
    func render(frame: FrameAirplaneRemover, closure: (() -> Void)? = nil) async {
        if let frameSaveQueue = viewModel.frameSaveQueue
        {
            self.rendering_current_frame = true // XXX might not be right anymore
            await frameSaveQueue.saveNow(frame: frame) {
                await viewModel.refresh(frame: frame)
                refreshCurrentFrame()
                self.rendering_current_frame = false
                closure?()
            }
        }
    }

    func transition(toFrame new_frame_view: FrameViewModel,
                    from old_frame: FrameAirplaneRemover?,
                    withScroll scroller: ScrollViewProxy? = nil)
    {
        Log.d("transition from \(String(describing: viewModel.currentFrame))")
        let start_time = Date().timeIntervalSinceReferenceDate

        if viewModel.current_index >= 0,
           viewModel.current_index < viewModel.frames.count
        {
            viewModel.frames[viewModel.current_index].isCurrentFrame = false
        }
        viewModel.frames[new_frame_view.frame_index].isCurrentFrame = true
        viewModel.current_index = new_frame_view.frame_index
        self.sliderValue = Double(viewModel.current_index)
        
        if interactionMode == .edit,
           let scroller = scroller
        {
            scroller.scrollTo(viewModel.current_index, anchor: .center)

            //viewModel.label_text = "frame \(new_frame_view.frame_index)"

            // only save frame when we are also scrolling (i.e. not scrubbing)
            if let frame_to_save = old_frame {

                Task {
                    let frame_changed = frame_to_save.hasChanges()

                    // only save changes to frames that have been changed
                    if frame_changed {
                        self.saveToFile(frame: frame_to_save) {
                            Log.d("completion closure called for frame \(frame_to_save.frame_index)")
                            Task {
                                await viewModel.refresh(frame: frame_to_save)
                                self.viewModel.update()
                            }
                        }
                    }
                }
            } else {
                Log.w("no old frame to save")
            }
        } else {
            Log.d("no scroller")
        }
        
        refreshCurrentFrame()

        let end_time = Date().timeIntervalSinceReferenceDate
        Log.d("transition to frame \(new_frame_view.frame_index) took \(end_time - start_time) seconds")
    }
}