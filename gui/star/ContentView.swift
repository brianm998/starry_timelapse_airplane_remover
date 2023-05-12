//
//  ContentView.swift
//  star
//
//  Created by Brian Martin on 2/1/23.
//

import Foundation
import SwiftUI
import Cocoa
import StarCore
import Zoomable

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

// the overall level of the app
@available(macOS 13.0, *) 
struct ContentView: View {
    @ObservedObject var viewModel: ViewModel
    @State private var interactionMode: InteractionMode = .scrub

    @State private var sliderValue = 0.0

    @State private var outlierOpacitySliderValue = 1.0

    @State private var savedOutlierOpacitySliderValue = 1.0
    
    @State private var videoPlayMode: VideoPlayMode = .forward
    
    @State private var previousInteractionMode: InteractionMode = .scrub

    // enum for how we show each frame
    @State private var frameViewMode = FrameViewMode.processed

    @State private var selectionMode = SelectionMode.paint
    
    // should we show full resolution images on the main frame?
    // faster low res previews otherwise
    @State private var showFullResolution = false

    @State private var showFilmstrip = true

    @State private var animatePositiveOutliers = true
    @State private var animateNegativeOutliers = true
    
    @State private var drag_start: CGPoint?
    @State private var drag_end: CGPoint?
    @State private var isDragging = false
    @State private var background_brightness: Double = 0.33
    @State private var background_color: Color = .gray

    @State private var loading_outliers = false
    @State private var rendering_current_frame = false
    @State private var rendering_all_frames = false
    @State private var updating_frame_batch = false

    @State private var video_playback_framerate = 30
    @State var video_playing = false

    @State private var skipEmpties = false
    // if not skip empties, fast forward and reverse do a set number of frames
    @State private var fast_skip_amount = 20

    @State private var settings_sheet_showing = false
    @State private var paint_sheet_showing = false

    //@State private var previously_opened_sheet_showing = false
    @State private var previously_opened_sheet_showing_item: String =
      UserPreferences.shared.sortedSequenceList.count > 0 ?
      UserPreferences.shared.sortedSequenceList[0] : ""      

    @Environment(\.openWindow) private var openWindow

    init(viewModel: ViewModel) {
        self.viewModel = viewModel
    }
    
    var body: some View {
        //let scaling_anchor = UnitPoint(x: 0.75, y: 0.75)
        if !viewModel.sequenceLoaded {
            InitialView(viewModel: viewModel,
                        previously_opened_sheet_showing_item: $previously_opened_sheet_showing_item)
        } else {
            sequenceView()
              .alert(isPresented: $viewModel.showErrorAlert) {
                  Alert(title: Text("Error"),
                        message: Text(viewModel.errorMessage),
                        primaryButton: .default(Text("Ok")) { viewModel.sequenceLoaded = false },
                        secondaryButton: .default(Text("F")) { viewModel.sequenceLoaded = false } )

              }
        }
    }
    
    // main view of an image seuqence
    func sequenceView() -> some View {
        GeometryReader { top_geometry in
            ScrollViewReader { scroller in
                VStack {
                    let should_show_progress =
                      rendering_current_frame            ||
                      updating_frame_batch               ||
                      rendering_all_frames

                    // selected frame 
                    ZStack {
                        currentFrameView()
                          .frame(maxWidth: .infinity, alignment: .center)
                          .overlay(
                            ProgressView()
                              .scaleEffect(8, anchor: .center) // this is blocky scaled up 
                              .progressViewStyle(CircularProgressViewStyle(tint: .yellow))
                              .frame(maxWidth: 200, maxHeight: 200)
                              .opacity(should_show_progress ? 0.8 : 0)
                          )
                    }

                    if loading_outliers {
                        HStack {
                            Text("Loading Outliers for this frame")
                            Spacer()
                            ProgressView()
                              .progressViewStyle(.linear)
                              .frame(maxWidth: .infinity)
                        }
                    }

                    if viewModel.initial_load_in_progress {
                        HStack {
                            Text("Loading Image Sequence")
                            Spacer()
                            ProgressView(value: viewModel.frameLoadingProgress)
                        }
                    }

                    if viewModel.loading_all_outliers {
                        HStack {
                            Text("Loading Outlier Groups for all frames")
                            Spacer()
                            ProgressView(value: viewModel.outlierLoadingProgress)
                        }
                    }
                    
                    VStack {
                        // buttons below the selected frame 
                        bottomControls(withScroll: scroller)
                        
                        if interactionMode == .edit,
                           showFilmstrip
                        {
                            Spacer().frame(maxHeight: 30)
                            // the filmstrip at the bottom
                            filmstrip(withScroll: scroller)
                              .frame(maxWidth: .infinity/*, alignment: .bottom*/)
                            Spacer().frame(maxHeight: 10/*, alignment: .bottom*/)
                        }

                        if viewModel.image_sequence_size > 0 {
                            if interactionMode == .edit {
                                Spacer().frame(maxHeight: 20)
                            }
                            let start = 0.0
                            let end = Double(viewModel.image_sequence_size)
                            Slider(value: $sliderValue, in : start...end)
                              .frame(maxWidth: .infinity, alignment: .bottom)
                              .disabled(video_playing)
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
                    }
                }
            }
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
              .padding()
              .background(background_color)
        }
    }

    // controls below the selected frame and above the filmstrip
    func bottomControls(withScroll scroller: ScrollViewProxy) -> some View {
        HStack {
            ZStack {
                videoPlaybackButtons(scroller)
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
                          .disabled(video_playing)
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
                          .disabled(video_playing)
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
                            Slider(value: viewModel.animateOutliers ? $savedOutlierOpacitySliderValue : $outlierOpacitySliderValue, in : 0...1)
                              .frame(maxWidth: 140, alignment: .bottom)
                              .disabled(viewModel.animateOutliers)
                        }
                        VStack {
                        Toggle("Animate Outliers", isOn: $viewModel.animateOutliers)
                          .onChange(of: viewModel.animateOutliers) { mode_on in
                              if let frame = viewModel.currentFrame {
                                  Task {
                                      await viewModel.setOutlierGroups(forFrame: frame)
                                      refreshCurrentFrame()
                                  }
                              }
                          }
                        HStack {
                            Toggle("red", isOn: $animatePositiveOutliers)
                              .disabled(viewModel.animateOutliers)
                            Toggle("green", isOn: $animateNegativeOutliers)
                              .disabled(viewModel.animateOutliers)
                        }
                        }
                    }
                }
                  .frame(maxWidth: .infinity, alignment: .leading)


                
                
                if interactionMode == .edit {
//                if !video_playing {
                    HStack {
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
                                            fast_skip_amount: self.$fast_skip_amount,
                                            video_playback_framerate: self.$video_playback_framerate,
                                            skipEmpties: self.$skipEmpties)
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
    
    // shows either a zoomable view of the current frame
    // just the frame itself for scrubbing and video playback
    // or a place holder when we have no image for it yet
    func currentFrameView() -> some View {
        HStack {
            if let frame_image = self.viewModel.current_frame_image {
                switch self.interactionMode {
                case .scrub:
                    frame_image
                      .resizable()
                      .aspectRatio(contentMode: . fit)

                case .edit: 
                    GeometryReader { geometry in
                        let min = geometry.size.height/viewModel.frame_height
                        let full_max = self.showFullResolution ? 1 : 0.3
                        let max = min < full_max ? full_max : min

                        ZoomableView(size: CGSize(width: viewModel.frame_width,
                                                  height: viewModel.frame_height),
                                     min: min,
                                     max: max,
                                     showsIndicators: true)
                        {
                            // the currently visible frame
                            self.frameView(frame_image)//.aspectRatio(contentMode: .fill)
                        }
                          .transition(.moveAndFade)
                    }
                }
            } else {
                // XXX pre-populate this crap as an image
                ZStack {
                    Rectangle()
                      .foregroundColor(.yellow)
                      .aspectRatio(CGSize(width: 4, height: 3), contentMode: .fit)
                    Text(viewModel.no_image_explaination_text)
                }
                  .transition(.moveAndFade)
            }
        }
    }

    // this is the main frame with outliers on top of it
    func frameView( _ image: Image) -> some View {
        ZStack {
            // the main image shown
            image

            if interactionMode == .edit {
                let current_frame_view = viewModel.currentFrameView
                if let outlierViews = current_frame_view.outlierViews {
                    ForEach(0 ..< outlierViews.count, id: \.self) { idx in
                        if idx < outlierViews.count {
                            let outlierViewModel = outlierViews[idx]
                            
                            let frame_center_x = outlierViewModel.frame_width/2
                            let frame_center_y = outlierViewModel.frame_height/2
                            let outlier_center = outlierViewModel.bounds.center
                            
                            let will_paint = outlierViewModel.group.shouldPaint?.willPaint ?? false

                            // this nested trinary sucks
                            let paint_color: Color = outlierViewModel.isSelected ? .blue : (will_paint ? .red : .green)

                            Image(nsImage: outlierViewModel.image)
                              .renderingMode(.template) // makes this VV color work
                              .foregroundColor(paint_color)
                              .offset(x: CGFloat(outlier_center.x - frame_center_x),
                                      y: CGFloat(outlier_center.y - frame_center_y))
                              .opacity(outlierOpacitySliderValue)
                              .id(viewModel.animateOutliers)
                              .onChange(of: viewModel.animateOutliers) { newValue in
                                  if newValue &&
                                     ((will_paint && animatePositiveOutliers) ||
                                      (!will_paint && animateNegativeOutliers))
                                  {
                                      savedOutlierOpacitySliderValue = outlierOpacitySliderValue
                                       withAnimation(  Animation.easeInOut(duration:0.2)
                                                         .repeatForever(autoreverses:true) 
                                       )
                                       {
                                           outlierOpacitySliderValue = 0.0
                                       }
                                  } else {
                                      outlierOpacitySliderValue = savedOutlierOpacitySliderValue
                                  }
                                  
                                  viewModel.objectWillChange.send()
                                  refreshCurrentFrame()
                                  Log.i("changed")
                              }
                            // tap gesture toggles paintability of the tapped group
                              .onTapGesture {
                                  if let origShouldPaint = outlierViewModel.group.shouldPaint {
                                      // change the paintability of this outlier group
                                      // set it to user selected opposite previous value
                                      Task {
                                          if selectionMode == .details {
                                              // here we want to select just this outlier

                                              if self.viewModel.outlierGroupTableRows.count == 1,
                                                 self.viewModel.outlierGroupTableRows[0].name == outlierViewModel.group.name
                                              {
                                                  // just toggle the selectablility of this one
                                                  // XXX need separate enums for selection does paint and selection does do info
                                              } else {
                                                  // make this row the only selected one
                                                  let frame_view = viewModel.frames[outlierViewModel.group.frame_index]
                                                  if let frame = frame_view.frame,
                                                     let group = await frame.outlierGroup(named: outlierViewModel.group.name)
                                                  {
                                                      if let outlier_views = frame_view.outlierViews {
                                                          for outlier_view in outlier_views {
                                                              if outlier_view.name != outlierViewModel.group.name {
                                                                  outlier_view.isSelected = false
                                                              }
                                                          }
                                                      }
                                                      let new_row = await OutlierGroupTableRow(group)
                                                      outlierViewModel.isSelected = true
                                                      await MainActor.run {
                                                          self.viewModel.outlierGroupWindowFrame = frame
                                                          self.viewModel.outlierGroupTableRows = [new_row]
                                                          self.viewModel.selectedOutliers = [new_row.id]
                                                          showOutlierGroupTableWindow()
                                                          self.viewModel.update()

                                                      }
                                                  } else {
                                                      Log.w("couldn't find frame")
                                                  }
                                              }
                                          
                                          } else {
                                          
                                              let reason = PaintReason.userSelected(!origShouldPaint.willPaint)
                                          
                                              // update the view model to show the change quickly
                                              outlierViewModel.group.shouldPaint = reason
                                              self.viewModel.update()
                                              
                                              Task {
                                                  if let frame = viewModel.currentFrame,
                                                     let outlier_groups = await frame.outlier_groups,
                                                     let outlier_group = outlier_groups.members[outlierViewModel.group.name]
                                                  {
                                                      // update the actor in the background
                                                      await outlier_group.shouldPaint(reason)
                                                      self.viewModel.update()
                                                  } else {
                                                      Log.e("HOLY FUCK")
                                                  }
                                              }
                                          }
                                          // update the view model so it shows up on screen
                                      }
                                  } else {
                                      Log.e("WTF, not already set to paint??")
                                  }
                              }
                        }
                    }
                }
            }

            // this is the selection overlay
            if isDragging,
               let drag_start = drag_start,
               let drag_end = drag_end
            {
                let width = abs(drag_start.x-drag_end.x)
                let height = abs(drag_start.y-drag_end.y)

                let _ = Log.d("drag_start \(drag_start) drag_end \(drag_end) width \(width) height \(height)")

                let drag_x_offset = drag_end.x > drag_start.x ? drag_end.x : drag_start.x
                let drag_y_offset = drag_end.y > drag_start.y ? drag_end.y : drag_start.y

                Rectangle()
                  .fill(selectionColor().opacity(0.2))
                  .overlay(
                    Rectangle()
                      .stroke(style: StrokeStyle(lineWidth: 2))
                      .foregroundColor(selectionColor().opacity(0.8))
                  )                
                  .frame(width: width, height: height)
                  .offset(x: CGFloat(-viewModel.frame_width/2) + drag_x_offset - width/2,
                          y: CGFloat(-viewModel.frame_height/2) + drag_y_offset - height/2)
            }
        }
        // XXX selecting and zooming conflict with eachother
          .gesture(self.selectionDragGesture)
        
    }

    var selectionDragGesture: some Gesture {
        DragGesture()
                   .onChanged { gesture in
                       let _ = Log.d("isDragging")
                       isDragging = true
                       let location = gesture.location
                       if drag_start != nil {
                           // updating during drag is too slow
                           drag_end = location
                       } else {
                           drag_start = gesture.startLocation
                       }
                       //Log.d("location \(location)")
                   }
                   .onEnded { gesture in
                       isDragging = false
                       let end_location = gesture.location
                       if let drag_start = drag_start {
                           Log.d("end location \(end_location) drag start \(drag_start)")

                           let frameView = viewModel.currentFrameView

                           var should_paint = false
                           var paint_choice = true
                           
                           switch selectionMode {
                           case .paint:
                               should_paint = true
                           case .clear:
                               should_paint = false
                           case .details:
                               paint_choice = false
                           }

                           if paint_choice {
                               frameView.userSelectAllOutliers(toShouldPaint: should_paint,
                                                               between: drag_start,
                                                               and: end_location)
                               if let frame = frameView.frame {
                                   Task {
                                       // is view layer updated? (NO)
                                       await frame.userSelectAllOutliers(toShouldPaint: should_paint,
                                                                         between: drag_start,
                                                                         and: end_location)
                                       refreshCurrentFrame()
                                       viewModel.update()
                                   }
                               }
                           } else {
                               let _ = Log.d("DETAILS")

                               if let frame = frameView.frame {
                                   Task {
                                       //var new_outlier_info: [OutlierGroup] = []
                                       var _outlierGroupTableRows: [OutlierGroupTableRow] = []
                                       
                                       await frame.foreachOutlierGroup(between: drag_start,
                                                                       and: end_location) { group in
                                           Log.d("group \(group)")
                                           //new_outlier_info.append(group)

                                           let new_row = await OutlierGroupTableRow(group)
                                           _outlierGroupTableRows.append(new_row)
                                           return .continue
                                       }
                                       await MainActor.run {
                                           self.viewModel.outlierGroupWindowFrame = frame
                                           self.viewModel.outlierGroupTableRows = _outlierGroupTableRows
                                           Log.d("outlierGroupTableRows \(viewModel.outlierGroupTableRows.count)")
                                           showOutlierGroupTableWindow()
                                       }
                                   }
                               } 
                               
                               // XXX show the details here somehow
                           }
                       }
                       drag_start = nil
                       drag_end = nil
                   }
    }

    // the view for each frame in the filmstrip at the bottom
    func filmStripView(forFrame frame_index: Int, withScroll scroller: ScrollViewProxy) -> some View {
        //var bg_color: Color = .yellow
        if let frame = viewModel.frame(atIndex: frame_index) {
            //            if frame.outlierGroupCount() > 0 {
            //                bg_color = .red
            //            } else {
            //bg_color = .green
            //            }
        }
        return VStack(alignment: .leading) {
            Spacer().frame(maxHeight: 8)
            HStack{
                Spacer().frame(maxWidth: 10)
                Text("\(frame_index)").foregroundColor(.white)
            }.frame(maxHeight: 10)
            if frame_index >= 0 && frame_index < viewModel.frames.count {
                let frameView = viewModel.frames[frame_index]
                let stroke_width: CGFloat = 4
                if viewModel.current_index == frame_index {
                    
                    frameView.thumbnail_image
                      .foregroundColor(.orange)
                    
                } else {
                    frameView.thumbnail_image
                }
            }
            Spacer().frame(maxHeight: 8)
        }
          .frame(minWidth: CGFloat((viewModel.config?.thumbnail_width ?? 80) + 8),
                 minHeight: CGFloat((viewModel.config?.thumbnail_height ?? 50) + 30))
        // highlight the selected frame
          .background(viewModel.current_index == frame_index ? Color(white: 0.45) : Color(white: 0.22))
          .onTapGesture {
              // XXX move this out 
              //viewModel.label_text = "loading..."
              // XXX set loading image here
              // grab frame and try to show it
              let frame_view = viewModel.frames[frame_index]
              
              let current_frame = viewModel.currentFrame
              self.transition(toFrame: frame_view,
                              from: current_frame,
                              withScroll: scroller)
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
    
    func setAllCurrentFrameOutliers(to shouldPaint: Bool,
                                    renderImmediately: Bool = true)
    {
        let current_frame_view = viewModel.currentFrameView
        setAllFrameOutliers(in: current_frame_view,
                            to: shouldPaint,
                            renderImmediately: renderImmediately)
    }
    
    func setAllFrameOutliers(in frame_view: FrameView,
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

    func selectionColor() -> Color {
        switch selectionMode {
        case .paint:
            return .red
        case .clear:
            return .green
        case .details:
            return .blue
        }
    }
    
    func rightSideButtons() -> some View {
        VStack {

            paintAllButton()
              .frame(maxWidth: .infinity, alignment: .bottomTrailing)
            clearAllButton()
            .frame(maxWidth: .infinity, alignment: .bottomTrailing)
            outlierInfoButton()
              .frame(maxWidth: .infinity, alignment: .bottomTrailing)
            applyAllDecisionTreeButton()
              .frame(maxWidth: .infinity, alignment: .bottomTrailing)
            applyDecisionTreeButton()
              .frame(maxWidth: .infinity, alignment: .bottomTrailing)
            loadAllOutliersButton()
              .frame(maxWidth: .infinity, alignment: .bottomTrailing)
            renderCurrentFrameButton()
              .frame(maxWidth: .infinity, alignment: .bottomTrailing)
            renderAllFramesButton()
              .frame(maxWidth: .infinity, alignment: .bottomTrailing)
        }.opacity(0.8)
    }
    
    func paintAllButton() -> some View {
        Button(action: {
                   setAllCurrentFrameOutliers(to: true, renderImmediately: false)
        }) {
            Text("Paint All")
        }
          .help("paint all of the outlier groups in the frame")
    }
    
    func clearAllButton() -> some View {
        Button(action: {
            setAllCurrentFrameOutliers(to: false, renderImmediately: false)
        }) {
            Text("Clear All")
        }
          .help("don't paint any of the outlier groups in the frame")
    }

    func filmstrip(withScroll scroller: ScrollViewProxy) -> some View {
        HStack {
            if viewModel.image_sequence_size == 0 {
                Text("Loading Film Strip")
                  .font(.largeTitle)
                  .frame(minHeight: 50)
                  .transition(.moveAndFade)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(0..<viewModel.image_sequence_size, id: \.self) { frame_index in
                            self.filmStripView(forFrame: frame_index, withScroll: scroller)
                              .help("show frame \(frame_index)")
                        }
                    }
                }
                  .frame(minHeight: CGFloat((viewModel.config?.thumbnail_height ?? 50) + 30))
                  .transition(.moveAndFade)
            }
        }
          .frame(maxWidth: .infinity, maxHeight: 50)
          .background(viewModel.image_sequence_size == 0 ? .yellow : .clear)
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
    
    func render(frame: FrameAirplaneRemover, closure: (() -> Void)? = nil) async {
        if let frameSaveQueue = viewModel.frameSaveQueue
        {
            self.rendering_current_frame = true // XXX might not be right anymore
            frameSaveQueue.saveNow(frame: frame) {
                await viewModel.refresh(frame: frame)
                refreshCurrentFrame()
                self.rendering_current_frame = false
                closure?()
            }
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

    func showOutlierGroupTableWindow() {
        let windows = NSApp.windows
        var show = true
        for window in windows {
            Log.d("window.title \(window.title) window.subtitle \(window.subtitle) ")
            if window.title.hasPrefix(OUTLIER_WINDOW_PREFIX) {
                window.makeKey()
                window.orderFrontRegardless()
                //window.objectWillChange.send()
                show = false
            }
        }
        if show {
            openWindow(id: "foobar")
        }
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
                        showOutlierGroupTableWindow()
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
        return Button(action: action) {
            Text("Decision Tree All")
        }
          .help("apply the outlier group decision tree to all outlier groups in this frame")
    }

    func loadAllOutliersButton() -> some View {
        let action: () -> Void = {
            Task {
                do {
                    var current_running = 0
                    let start_time = Date().timeIntervalSinceReferenceDate
                    // XXX move to this:
                    //try await withThrowingLimitedTaskGroup(of: Void.self) { taskGroup in
                    try await withLimitedThrowingTaskGroup(of: Void.self) { taskGroup in
                        let max_concurrent = viewModel.config?.numConcurrentRenders ?? 10
                        // this gets "Too many open files" with more than 2000 images :(
                        viewModel.loading_all_outliers = true
                        Log.d("foobar starting")
                        viewModel.number_of_frames_with_outliers_loaded = 0
                        for frameView in viewModel.frames {
                            Log.d("frame \(frameView.frame_index) attempting to load outliers")
                            var did_load = false
                            while(!did_load) {
                                if current_running < max_concurrent {
                                    Log.d("frame \(frameView.frame_index) attempting to load outliers")
                                    if let frame = frameView.frame {
                                        Log.d("frame \(frameView.frame_index) adding task to load outliers")
                                        current_running += 1
                                        did_load = true
                                        try await taskGroup.addTask(/*priority: .userInitiated*/) {
                                            // XXX style the button during this flow?
                                            Log.d("actually loading outliers for frame \(frame.frame_index)")
                                            try await frame.loadOutliers()
                                            // XXX set this in the view model

                                            Task {
                                                await MainActor.run {
                                                    Task {
                                                        viewModel.number_of_frames_with_outliers_loaded += 1
                                                        await viewModel.setOutlierGroups(forFrame: frame)
                                                    }
                                                }
                                            }
                                        }
                                    } else {
                                        Log.d("frame \(frameView.frame_index) no frame, can't load outliers")
                                    }
                                } else {
                                    Log.d("frame \(frameView.frame_index) waiting \(current_running)")
                                    try await taskGroup.next()
                                    current_running -= 1
                                    Log.d("frame \(frameView.frame_index) done waiting \(current_running)")
                                }
                            }
                        }
                        do {
                            try await taskGroup.waitForAll()
                        } catch {
                            Log.e("\(error)")
                        }
                        
                        let end_time = Date().timeIntervalSinceReferenceDate
                        viewModel.loading_all_outliers = false
                        Log.d("foobar loaded outliers for \(viewModel.frames.count) frames in \(end_time - start_time) seconds")
                    }                                 
                } catch {
                    Log.e("\(error)")
                }
            }
        }
        
        return Button(action: action) {
            Text("Load All Outliers")
        }
          .help("Load all outlier groups for all frames.\nThis can take awhile.")
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
        if skipEmpties {
            if let current_frame = viewModel.currentFrame {
                self.transitionUntilNotEmpty(from: current_frame,
                                             forwards: false,
                                             withScroll: scroller)
            }
        } else {
            self.transition(numberOfFrames: -fast_skip_amount,
                            withScroll: scroller)
        }
    }

    func fastForwardButtonAction(withScroll scroller: ScrollViewProxy? = nil) {
        if skipEmpties {
            if let current_frame = viewModel.currentFrame {
                self.transitionUntilNotEmpty(from: current_frame,
                                             forwards: true,
                                             withScroll: scroller)
            }
        } else {
            self.transition(numberOfFrames: fast_skip_amount,
                            withScroll: scroller)
        }
    }

    // an HStack of buttons to advance backwards and fowards through the sequence
    func videoPlaybackButtons(_ scroller: ScrollViewProxy) -> some View {

        // XXX these should really use modifiers but those don't work :(
        let start_shortcut_key: KeyEquivalent = "b" // make this bottom arror
        let fast_previous_shortut_key: KeyEquivalent = "z"
        let fast_next_shortcut_key: KeyEquivalent = "x"
        let previous_shortut_key: KeyEquivalent = .leftArrow
        let previous_shortcut_key: KeyEquivalent = .leftArrow
        let backwards_shortcut_key: KeyEquivalent = "r"
        let end_button_shortcut_key: KeyEquivalent = "f" // make this top arror

        let button_color = Color(white: 202/256)
        
        return HStack {
            // go to start button

            if !video_playing {
                button(named: "backward.end.fill",
                       shortcutKey: start_shortcut_key,
                       color: button_color,
                       toolTip: """
                         go to start of sequence
                         (keyboard shortcut '\(start_shortcut_key.character)')
                         """)
                {
                    self.goToFirstFrameButtonAction(withScroll: scroller)
                }
                
                // fast previous button
                button(named: "backward.fill",
                       shortcutKey: fast_previous_shortut_key,
                       color: button_color,
                       toolTip: """
                         back \(fast_skip_amount) frames
                         (keyboard shortcut '\(fast_previous_shortut_key.character)')
                         """)
                {
                    self.fastPreviousButtonAction(withScroll: scroller)
                }
                
                // previous button
                button(named: "backward.frame.fill",
                       shortcutKey: previous_shortut_key,
                       color: button_color,
                       toolTip: """
                         back one frame
                         (keyboard shortcut left arrow)
                         """)
                {
                    self.transition(numberOfFrames: -1,
                                    withScroll: scroller)
                }

                // play backwards button
                button(named: "arrowtriangle.backward",
                       shortcutKey: backwards_shortcut_key,
                       color: button_color,
                       size: 40,
                       toolTip: """
                         play in reverse
                         (keyboard shortcut '\(backwards_shortcut_key)')
                         """)
                {
                    self.videoPlayMode = .reverse
                    self.togglePlay(scroller)
                }
            }

            ZStack {
                // backwards button is not shown, so we use this to have shortcut still work
                if video_playing {
                    Button("") {
                        self.togglePlay(scroller)
                    }
                      .opacity(0)
                      .keyboardShortcut(backwards_shortcut_key, modifiers: [])
                } 
            
                // play/pause button
                button(named: video_playing ? "pause.fill" : "play.fill", // pause.fill
                       shortcutKey: " ",
                       color: video_playing ? .blue : button_color,
                       size: 40,
                       toolTip: """
                         Play / Pause
                         """)
                {
                    self.videoPlayMode = .forward
                    self.togglePlay(scroller)
                    //Log.w("play button not yet implemented")
                }
            }
            if !video_playing {
                
                // next button
                button(named: "forward.frame.fill",
                       shortcutKey: .rightArrow,
                       color: button_color,
                       toolTip: """
                         forward one frame
                         (keyboard shortcut right arrow)
                         """)
                {
                    self.transition(numberOfFrames: 1,
                                    withScroll: scroller)
                }
                
                // fast next button
                button(named: "forward.fill",
                       shortcutKey: fast_next_shortcut_key,
                       color: button_color,
                       toolTip: """
                         forward \(fast_skip_amount) frames
                         (keyboard shortcut '\(fast_next_shortcut_key.character)')
                         """)
                {
                    self.fastForwardButtonAction(withScroll: scroller)
                }
                
                
                // end button
                button(named: "forward.end.fill",
                       shortcutKey: end_button_shortcut_key,
                       color: button_color,
                       toolTip: """
                         advance to end of sequence
                         (keyboard shortcut '\(end_button_shortcut_key.character)')
                         """)
                {
                    self.goToLastFrameButtonAction(withScroll: scroller)
                }
            }
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
        
        video_playing = false
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
        self.video_playing = !self.video_playing
        if video_playing {

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

                        switch self.videoPlayMode {
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

                        switch self.videoPlayMode {
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
                Picker("selection mode", selection: $selectionMode) {
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


    func buttonImage(_ name: String, size: CGFloat) -> some View {
        return Image(systemName: name)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: size,
                 maxHeight: size,
                 alignment: .center)
    }
    
    func button(named button_name: String,
                shortcutKey: KeyEquivalent,
                modifiers: EventModifiers = [],
                color: Color,
                size: CGFloat = 30,
                toolTip: String,
                action: @escaping () -> Void) -> some View
    {
        //Log.d("button \(button_name) using modifiers \(modifiers)")
        return ZStack {
            Button("", action: action)
              .opacity(0)
              .keyboardShortcut(shortcutKey, modifiers: modifiers)
            
            Button(action: action) {
                buttonImage(button_name, size: size)
            }
              .buttonStyle(PlainButtonStyle())                            
              .help(toolTip)
              .foregroundColor(color)
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
    
    func transitionUntilNotEmpty(from frame: FrameAirplaneRemover,
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
        if next_frame_view.outlierViews?.count == 0 {
            // skip this one
            self.transitionUntilNotEmpty(from: frame,
                                         forwards: forwards,
                                         currentIndex: next_frame_index,
                                         withScroll: scroller)
        } else {
            self.transition(toFrame: next_frame_view,
                            from: frame,
                            withScroll: scroller)
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
                    Task {
                        loading_outliers = true
                        let _ = try await next_frame.loadOutliers()
                        await viewModel.setOutlierGroups(forFrame: next_frame)
                        frameView.loadingOutlierViews = false
                        loading_outliers = viewModel.loadingOutlierGroups
                        viewModel.update()
                    }
                }
            }
        } else {
            Log.d("WTF for frame \(viewModel.current_index)")
            viewModel.update()
        }
    }
    
    
    func transition(toFrame new_frame_view: FrameView,
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
                    let frame_changed = await frame_to_save.hasChanges()

                    // only save changes to frames that have been changed
                    if frame_changed {
                        self.saveToFile(frame: frame_to_save) {
                            Log.d("completion closure called for frame \(frame_to_save.frame_index)")
                            Task { await viewModel.refresh(frame: frame_to_save) }
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

@available(macOS 13.0, *) 
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(viewModel: ViewModel())
    }
}

extension AnyTransition {
    static var moveAndFade: AnyTransition {
        //AnyTransition.move(edge: .trailing)
        //AnyTransition.slide
        .asymmetric(
          insertion: .move(edge: .trailing).combined(with: .opacity),
          removal: .scale.combined(with: .opacity)
        )         

    }
}
