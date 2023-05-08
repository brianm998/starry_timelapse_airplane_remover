import SwiftUI
import StarCore

struct MassivePaintSheetView: View {
    @Binding var isVisible: Bool
    @ObservedObject var viewModel: ViewModel
    var closure: (Bool, Int, Int) -> Void

    @State var start_index: Int = 0
    @State var end_index: Int = 1   // XXX 1
    @State var should_paint = false

    init(isVisible: Binding<Bool>,
         viewModel: ViewModel,
         closure: @escaping (Bool, Int, Int) -> Void)
    {
        self._isVisible = isVisible
        self.closure = closure
        self.viewModel = viewModel
    }
    
    var body: some View {
        HStack {

            Spacer()
            VStack {
                Spacer()
                Text((should_paint ? "Paint" : "Clear") + " \(end_index-start_index) frames from")
                Spacer()
                Picker("start frame", selection: $start_index) {
                    ForEach(0 ..< viewModel.frames.count, id: \.self) {
                        Text("frame \($0)")
                    }
                }
                Spacer()
                Picker("to end frame", selection: $end_index) {
                    ForEach(0 ..< viewModel.frames.count, id: \.self) {
                        Text("frame \($0)")
                    }
                }
                Toggle("should paint", isOn: $should_paint)

                HStack {
                    Button("Cancel") {
                        self.isVisible = false
                    }
                    
                    Button(should_paint ? "Paint All" : "Clear All") {
                        self.isVisible = false
                        closure(should_paint, start_index, end_index)
                    }
                }
                Spacer()
            }
            Spacer()
        }
    }
}

