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

//public struct StarPicker<Foobar: CaseIterable & Equatable & Hashable, Content: View> : View {
//public struct StarPicker<Foobar, Content: View> : View where Foobar.AllCases: RandomAccessCollection, Foobar: CaseIterable, Foobar: Hashable, Foobar == Content.Element, Content: RandomAccessCollection, Content.Element: Identifiable & Equatable, Content.Element.ID == String {
public struct StarPicker<Foobar, Content: View> : View
  where Foobar.AllCases: RandomAccessCollection,
        Foobar: CaseIterable & Hashable
{
    @Binding private var selection: Foobar
    @Environment(\.isEnabled) var isEnabled

    private let content: (Foobar,Bool) -> Content

    public init(selection: Binding<Foobar>,
                @ViewBuilder content: @escaping (Foobar,Bool) -> Content)
    {
        self._selection = selection
        self.content = content
    }

    public var body: some View {
        HStack {
            ForEach(Foobar.allCases, id: \.self) { value in
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
