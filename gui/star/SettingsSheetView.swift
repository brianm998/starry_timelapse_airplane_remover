import SwiftUI
import StarCore

enum FastAdvancementType: String, Equatable, CaseIterable {
    case normal
    case skipEmpties
    case toNextPositive
    case toNextNegative
    case toNextUnknown
    
    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}

struct SettingsSheetView: View {
    @Binding var isVisible: Bool
    @Binding var fast_skip_amount: Int
    @Binding var video_playback_framerate: Int
    @Binding var fastAdvancementType: FastAdvancementType 
    
    var body: some View {
        VStack {
            Spacer()
            Text("Settings")
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading) {
                    switch fastAdvancementType {
                    case .normal:
                        Text("Fast Forward and Reverse move by \(fast_skip_amount) frames")
                    case .skipEmpties:
                        Text("Skip all frames without outliers")
                    case .toNextPositive:
                        Text("Skip to next frame with a positive outlier")
                    case .toNextNegative:
                        Text("Skip to next frame with a negative outlier")
                    case .toNextUnknown:
                        Text("Skip to next frame with a unknown outlier")
                    }
                    
                    Picker("Fast Advancement Type", selection: $fastAdvancementType) {
                        ForEach(FastAdvancementType.allCases, id: \.self) { value in
                            Text(value.localizedName).tag(value)
                        }
                    }
                      .help("""
                              How the fast forward and fast reverse buttons work:

                              normal         - move by some fixed number of frames
                              skipEmpties    - skip all frames without any outliers
                              toNextPositive - skip to the next frame with positive outliers
                              toNextNegative - skip to the next frame with negative outliers
                              toNextUnknown  - skip to the next frame with unknown outliers
                              """)
                      .frame(maxWidth: 280)

//                    Toggle(skipEmpties ? "change to # of frames" : "change to skip empties",
//                           isOn: $skipEmpties)

                    // XXX add advance to has undecided
                    // XXX add advance to has paintable
                    // XXX add advance to has not paintable
                    
                    if fastAdvancementType == .normal {
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
