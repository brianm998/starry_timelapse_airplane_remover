import SwiftUI

import StarCore
struct InfoDialogView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    
    var body: some View {
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
                        Text(localized("ui.information_about_star"))
                          .font(.largeTitle)
                          .foregroundColor(.white)
                        
                        HStack(alignment: .top) {
                            VerticalStarPicker("",
                                               selection: $viewModel.currentInfoType) { value, _, _ in
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
                            Text(localized("ui.close"))
                              .buttonStyle(ShrinkingButton())
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
}

public enum InfoType: CaseIterable {
    case about
    case howTo
    case detailed

    var shortName: String {
        switch self {
        case .about:
            return localized("ui.about")
        case .howTo:
            return localized("ui.how_to")
        case .detailed:
            return localized("ui.detailed")
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

              You will also have a json config file written out for your sequence, which can be reloaded at a later time to process the same sequence more.

              The config can be loaded by dropping it onto Star's initial screen.
              """
        case .detailed:
            return """
              Star processes each frame of a sequence in this manner:

              Identify the horizon, if desired.
              
              The first step is to maybe identify the horizon.  This step is optional, as sometimes overnight timelapses don't have a horizon for some or all of the video.  It also is faster to ignore the horizon, as less processing is done later.
              However, knowing the horizon can help in a number of ways:
               - better pixel replacement close to the horizon
               - better pixel replacement below the horizon
               - less noise below the horizon due to earth alignment 
              
              Identify a set of neighbor frames.
              
              It is configurable how many neighbors are best to use, the default is 8.  Using less can still work, but risks being unable to remove bad pixels in some really noisy situations.

              Align the neighbor frames for sky and maybe earth too.
              
              Star uses opencv2 for its SIFT (Scale Invariant Feature Transform) logic to align neibhgoring frames with each frame being processed.
              If horizon detection is enabled, the calculated horizon mask for the frame being procssed is used to only identify keypoints in either the sky or the ground.  Without horizon detection, the whole image is scanned for keypoints, which almost always ends up aligning the sky.
              If the alignment fails to properly align the frames, Star will fall back to simply using the un-aligned neighbor frames.  This does work, but results in more noise during processing, and the overwritten data is going to be slightly off.

              Condense the aligned neighbor frames.
              
              After aligning some set of neighbor frames for the frame being procssed, star will then condense this set of frames into a single frame for the sky, and also the earth, if horizon detection is enabled.
              Each pixel is selected from neighboring frames using statistical analysis to remove pixels that are significally brighter than others in the same x,y location in other frames.
              You can see the star and earth aligned images for each frame and how well is is aligned in edit mode.

              Subtract the aligned neighbor frame.
              
              Next, Star will subtract the aligned neighbor frame from the frame being processed.
              This results in a new grayscale image which indicates where, and by how much, the original frame was brighter than the neighbor frame.
              If horizon detection is enabled, the calculated horizon mask for the frame being processd will be used.  This way, the earth alignment image is used as well as the sky alignment image.
              You can see the subtraction image for each frame in edit mode.
              While a lot of other things will show up in the subtraction image, you will see any airplanes or satellites as lines, ideally without any stars or static lights on the ground.

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

              Removal Mask Creation.
              After classifying all of the Outlier Groups for a frame, we now know which pixels are considered noise and which ones are ok to keep.
              With this data, Star then creates a removal mask, similar to a layer mask in Photoshop or the GIMP.  This mask is used to remove any noisy pixels with data from the aligned neighbor frame.

              Final Bad Pixel Removal
              At this final step, Star simply composts the frame being processed with the aligned neighor frame, using the removal mask as a layer mask, to only overwrite a small number of pixels in the frame we are processing.

              After Star has finished processing your image sequence, you can then watch a video of the sequence at preview resolution.  This can be helpful to allow you to make any corrections.

              Star is still a work in progress.
              """
        }
    }
}
