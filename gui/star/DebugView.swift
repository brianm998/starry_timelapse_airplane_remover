import SwiftUI
import logging

/*
  add number of images in cache
  allow sorting data by time
  allow copying log data to clipboard
  allow searching by text
  keep maximum number of lines in gui logs

 * allow sorting existing data by log level (instead of changing the log level reported at)
 * update gui logging to report structured data
 * filter logs
 * add switch to enable file logging at separate log level (show file name in gui somewhere)


 */
struct DebugView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    @Environment(LoggingViewModel.self) var loggingViewModel: LoggingViewModel

    // show only this level and above in the gui
    @State private var filterLevel: Log.Level = .verbose

    private let dateFormatter = DateFormatter()

    public init() {
        dateFormatter.dateFormat = "H:mm:ss.SSSS"
    }
    
    var body: some View {
        @Bindable var loggingViewModel = loggingViewModel
        return VStack(alignment: .leading) {
            Spacer().frame(height: 10)
            HStack {
                Spacer()

                Picker("Log Level", selection: $loggingViewModel.level) {
                    ForEach(Log.Level.allCases, id: \.self) { level in
                        Text("\(level.emo) \(level.rawValue)")
                    }
                }
                  .pickerStyle(.menu)
                  .fixedSize(horizontal: true, vertical: false)

                Picker("Filter Level", selection: $filterLevel) {
                    ForEach(Log.Level.allCases, id: \.self) { level in
                        Text("\(level.emo) \(level.rawValue)")
                    }
                }
                  .pickerStyle(.menu)
                  .fixedSize(horizontal: true, vertical: false)

                Button {
                    loggingViewModel.clearLogs()
                } label: {
                    Text("Clear")
                }

                Divider()
                  .frame(width: 4)
                  .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $loggingViewModel.fileLogEnabled) {
                    Text("Enable File Logging")
                      .foregroundColor(loggingViewModel.fileLogEnabled ? .black : .gray)
                }
                
                Picker(selection: $loggingViewModel.fileLogLevel) {
                    ForEach(Log.Level.allCases, id: \.self) { level in
                        Text("\(level.emo) \(level.rawValue)")
                    }
                } label: {
                    Text("File Log Level")
                      .foregroundColor(loggingViewModel.fileLogEnabled ? .black : .gray)
                }
                  .pickerStyle(.menu)
                  .fixedSize(horizontal: true, vertical: false)
                  .disabled(!loggingViewModel.fileLogEnabled)

                Spacer()
            }
            VStack(alignment: .leading) {
                ScrollView {
                    VStack(alignment: .leading) {
                        Grid(alignment: .leading) {
                            ForEach(loggingViewModel.logs, id: \.self) { logLine in
                                if logLine.level <= filterLevel {
                                    GridRow {
                                        Text(self.dateFormatter.string(from: logLine.time))
                                        Text(logLine.level.emo)
                                        Text(logLine.fileLocation)
                                        Text(logLine.message)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
          .navigationTitle("Star Debug")
    }
}
