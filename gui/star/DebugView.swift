import SwiftUI
import logging

struct DebugView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    @Environment(LoggingViewModel.self) var loggingViewModel: LoggingViewModel

    var body: some View {
        @Bindable var loggingViewModel = loggingViewModel
        return VStack(alignment: .leading) {
            Spacer().frame(height: 10)
            HStack {
                Spacer()

                Picker("Log Level", selection: $loggingViewModel.level) {
                    ForEach(Log.Level.allCases, id: \.self) { level in
                        Text(level.rawValue)
                    }
                }
                  .pickerStyle(.menu)
                  .fixedSize(horizontal: true, vertical: false)

                Button {
                    loggingViewModel.clearLogs()
                } label: {
                    Text("Clear")
                }
                Spacer()
            }
            VStack(alignment: .leading) {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(loggingViewModel.logs, id: \.self) { logline in
                            Text(logline)
                        }
                    }
                }
            }
            // add number of images in cache
            // add switch to enable file logging at separate log level
        }
          .navigationTitle("Star Debug")
    }
}
