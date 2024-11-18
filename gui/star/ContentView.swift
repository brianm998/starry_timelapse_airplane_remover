//
//  ContentView.swift
//  star
//
//  Created by Brian Martin on 2/1/23.
//

import SwiftUI

// the overall view of the app
@available(macOS 13.0, *) 
struct ContentView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    
    var body: some View {
        ZStack {
            if viewModel.isLoadingImageSequence {
                ImageSequenceLoadingView()
            } else if let imageSequenceViewModel = viewModel.imageSequence {
                ImageSequenceView()
                  .environment(imageSequenceViewModel)
                  .navigationTitle(imageSequenceViewModel.windowTitle)
            } else {
                InitialView()
            }
            // these may show on top
            if viewModel.showInfoDialog { self.infoDialog }
            if viewModel.showErrorAlert { self.errorAlert }
        }
    }

    var infoDialog: some View {
        @Bindable var viewModel = viewModel
        return ZStack {
            Rectangle()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(.gray)
              .opacity(0.5)


            VStack {
                Spacer()
                  .frame(maxHeight: 200)
                HStack {
                    Spacer()
                      .frame(maxWidth: 200)
                    VStack {
                        Text("Information about Star")
                          .font(.largeTitle)
                          .foregroundColor(.white)
                        
                        HStack(alignment: .top) {
                            VerticalStarPicker("",
                                               selection: $viewModel.currentInfoType) { value, _ in
                                Text(value.shortName).tag(value)
                                  .font(.title)
                                //.foregroundColor(.white)
                            }
                              .font(.title)

                            ScrollView {
                                Text(viewModel.currentInfoType.infoText)
                                  .font(.title)
                                  .foregroundColor(.white)
                            }
                        }

                        Button() {
                            viewModel.showInfoDialog = false
                        } label: {
                            Text("Close")
                        }
                    }
                      .padding(20)
                    //.frame(maxWidth: 500)
                      .background(.gray)
                      .cornerRadius(20)

                    Spacer()
                      .frame(maxWidth: 200)
                }
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
                Spacer()
                  .frame(maxHeight: 200)
            }
              .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    var errorAlert: some View {
        ZStack {
            Rectangle()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(.gray)
              .opacity(0.5)

            VStack {
                Text("ERROR")
                
                Spacer()
                  .frame(maxHeight: 40)
                Text(viewModel.errorMessage)
                Spacer()
                  .frame(maxHeight: 40)
                Button() {
                    viewModel.showErrorAlert = false
                } label: {
                    Text("Close")
                }
            }
              .padding(40)
              .frame(maxWidth: 500)
              .background(.red)
              .cornerRadius(20)
        }
    }
}

public enum InfoType: CaseIterable {
    case about
    case howTo
    case detailed

    var shortName: String {
        switch self {
        case .about:
            return "About"
        case .howTo:
            return "How To"
        case .detailed:
            return "Detailed"
        }
    }

    var infoText: String {
        switch self {
        case .about:
            return """
              Star is the Starry Timelapse Airplane Remover.

              This is software designed to post process timelapse image sequences from timelapses, with the intent of treating visual signals from airplanes and satellites as noise that should be removed.

              It is free software, both free to use and free to see and use the source code, under the GPL v3 license.

              LINK to source code here

              At a high level, Star takes as input an image sequence from a timelapse video.
              It does a bunch of processing on this, and then outputs a processed image sequence which has modifications made to it to hide streaks in the sky.
              Currently Star does not operate on video files directly, only image sequences which are separated by folder, and only 16 bit tiff images.
              """
        case .howTo:
            return """
              To get started with Star, you need to first have an image sequence containing images from the night sky.

              The fastest way to get started is to drop this folder into Star's starting screen, and then Star will load the sequence and let you view the sequence or start processing.

              After first loading a new image sequence, Star will first generate previews for the original images.  After preview generation, the original video can be played or scrubbed.
              
              Before telling Start to start processing your image sequence, it can be helpful to desribe an area at the bottom to ignore.  Unless you video has no ground in it at all, it is helpful to go into edit mode, and turn on the 'Show Ignore Bar' switch on the right panel.
              You can then drag up the orange arrows you see at the bottom of the screen to expose the are of the video to not process.   This can speed Star up.
              If you video is stationary, you can use a single frame to determine the cutoff for the ground.
              If your video was taking on moving tripod head, then it's best to scrub through the video to find the lowest place that the sky shows up, and use that frame for the cutoff.

              Next, you can tell Star to start processing your image sequence.
              Be aware that this can take some time.  The Star interface remains active when processing, and you can look at each individual frame if you want to see what happens to it as it gets processed.

              After processing, you will have a folder sitting alongside your original image sequence which contains the processed images.
              These can then be renedred into the video format of your choice in the same workflow you usually use.
              """
        case .detailed:
            return """
              Star processes each frame of a sequence in this manner:

              Identify a neighbor frame.
              Either the proceeding, or following frame can be used for this, mostly it doesn't matter.

              Align the neighbor frame.
              Star uses Hugin's align_image_stack utility to attempt to align the neighbor frame with the frame being processed.  If the sky is showing at least some stars, and the frame has more sky than ground, then align_image_stack is really good at aligning the stars between the frames.
              What this means is that the frame being processed stays static, and the neighbor frame is then modified with complex math to account for changes between the frames.  This works for both timelapses taken on a static tripod (not moving), and also for timelapses taken on a moving head.
              The reason to align the neighbor frame is that we can then overwrite the parts of the frame we are processing that are considered undesirable with data from the aligned frame.  In this case, the stars are close to the same spot, and the earth has moved.
              If the star alignment fails, either because Hugin isn't installed, or because align_image_stack failed to properly align the frames, Star will fall back to simply using the un-aligned neighbor frame.  This does work, but results in more noise during processing, and the overwritten data is going to be slightly off.
              You can see the neighbor for each frame and how well is is aligned in edit mode.

              Subtract the aligned neighbor frame
              Next, Star will subtract the aligned neighbor frame from the frame being processed.
              This results in a new grayscale image which indicates where, and by how much, the original frame was brighter than the neighbor frame.
              You can see the subtraction image for each frame in edit mode.
              While a lot of things do show up in this image, you will see any airplanes or satellites as lines.

              Detect Blobs
              Next Star detects what are called Blobs of brighter pixels, using an algorithm that sorts all of the pixels in an image by brightness, and then processing them in order of brighest first, stopping on dimmer pixels.
              Each bright pixel is then looked at, and any neighbors that aren't too dark are added to the 'Blob'
              You can see the initial blobs for each frame in edit mode.

              Blob Processing
              After initial Blob detection, a lot of processing is done to make the signal cleaner.
              Numerous rounds of line detection and removal based upon different criteria end up giving a final set of blobs.
              You can see how the many different blob processing steps work for each frame in edit mode.

              Outlier Group classification.
              After Blob processing is complete, the Blobs are promoted into Outlier Groups.
              Both Blobs and Outlier Groups contain a list of pixels in the frame being processed that may contain 'noise' that should be removed.
              Outlier Groups add a layer of classification features on top of Blobs, which are used to tell which ones are really noise that should be removed.
              These classification features can be as simple as number of pixels, or more complex, involving neighboring frames and other neighboring outlier groups in the same frame.
              To classify the outlier groups, Star uses a decision tree based upon validated sequences.
              To validate a sequence means processing it through Star and then manually playing the video and correcting bad classifications by hand on each frame.  This can take while.

              Paint Mask Creation.
              After classifying all of the Outlier Groups for a frame, we now know which pixels are considered noise and which ones are ok to keep.
              With this data, Star then creates a paint mask, similar to a layer mask in Photoshop or the GIMP.  This mask is used to 'paint' over the noisy pixels with data from the aligned neighbor frame.

              Final Noise Removal
              At this final step, Star simply composts the frame being processed with the aligned neighor frame, using the paint mask as a layer mask, to only overwrite a small number of pixels in the frame we are processing.

              After Star has finished processing your image sequence, you can then watch a video of the sequence at preview resolution.  This can be helpful to allow you to make any corrections.

              Star is still a work in progress.
              """
        }
    }
}

@available(macOS 13.0, *) 
struct ContentView_Previews: PreviewProvider {
    @Environment(ViewModel.self) var viewModel: ViewModel

    static var previews: some View {
        ContentView()
    }
}
