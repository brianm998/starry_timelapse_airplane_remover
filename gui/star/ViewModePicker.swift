import SwiftUI
import StarCore
import logging

// Acts like a segmented picker but allows more control over views
public struct ViewModePicker<Content: View> : View {
    @Binding private var selection: FrameViewMode
    @Environment(\.isEnabled) var isEnabled

    private let content: (FrameViewMode,Bool) -> Content

    public init(selection: Binding<FrameViewMode>,
                @ViewBuilder content: @escaping (FrameViewMode,Bool) -> Content)
    {
        self._selection = selection
        self.content = content
    }

    public var body: some View {
        HStack {
            ForEach(FrameViewMode.allCases, id: \.self) { value in
                Group {
                    if value == selection {
                        content(value, isEnabled)
                          .background(.white)
                          .cornerRadius(5)
                    } else {
                        content(value, isEnabled)
                    }
                }
            }
        }
    }    
}
