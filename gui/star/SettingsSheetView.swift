import SwiftUI
import StarCore

struct SettingsSheetView: View {
    @Binding var isVisible: Bool
    @Binding var fast_skip_amount: Int
    @Binding var video_playback_framerate: Int
    @Binding var skipEmpties: Bool
    
    var body: some View {
        VStack {
            Spacer()
            Text("Settings")
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading) {
                    Text(skipEmpties ?
                           "Fast Forward and Reverse skip empties" :
                           "Fast Forward and Reverse move by \(fast_skip_amount) frames")
                    
                    Toggle(skipEmpties ? "change to # of frames" : "change to skip empties",
                           isOn: $skipEmpties)

                    if !skipEmpties {
                        Picker("Fast Skip", selection: $fast_skip_amount) {
                            ForEach(0 ..< 51) {
                                Text("\($0) frames")
                            }
                        }.frame(maxWidth: 200)
                    }
                    let frame_rates = [1, 2, 3, 5, 10, 15, 20, 25, 30]
                    Picker("Frame Rate", selection: $video_playback_framerate) {
                        ForEach(frame_rates, id: \.self) {
                            Text("\($0) fps")
                        }
                    }.frame(maxWidth: 200)
                }
                Spacer()
            }
            
            Button("Done") {
                self.isVisible = false
            }
            Spacer()
        }
        //.frame(width: 300, height: 150)
    }
}
