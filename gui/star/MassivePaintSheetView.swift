import SwiftUI
import StarCore

struct MassivePaintSheetView: View {
    @EnvironmentObject var viewModel: ViewModel
    @Binding var isVisible: Bool
    var closure: (Bool, Int, Int) -> Void

    @State var startIndex: Int = 0
    @State var endIndex: Int = 1   // XXX 1
    @State var shouldPaint = false

    init(isVisible: Binding<Bool>,
         closure: @escaping (Bool, Int, Int) -> Void)
    {
        self._isVisible = isVisible
        self.closure = closure
    }
    
    var body: some View {
        HStack {

            Spacer()
            VStack {
                Spacer()
                Text((shouldPaint ? "Paint" : "Clear") + " \(endIndex-startIndex) frames from")
                Spacer()
                Picker("start frame", selection: $startIndex) {
                    ForEach(0 ..< viewModel.frames.count, id: \.self) {
                        Text("frame \($0)")
                    }
                }
                Spacer()
                Picker("to end frame", selection: $endIndex) {
                    ForEach(0 ..< viewModel.frames.count, id: \.self) {
                        Text("frame \($0)")
                    }
                }
                Toggle("should paint", isOn: $shouldPaint)

                HStack {
                    Button("Cancel") {
                        self.isVisible = false
                    }
                    
                    Button(shouldPaint ? "Paint All" : "Clear All") {
                        self.isVisible = false
                        closure(shouldPaint, startIndex, endIndex)
                    }
                }
                Spacer()
            }
            Spacer()
        }
    }
}

