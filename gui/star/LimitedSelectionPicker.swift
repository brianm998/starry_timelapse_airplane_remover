import SwiftUI
import StarCore
import logging

public struct LimitedSelectionPicker<Selection, Content: View> : View
  where Selection: CaseIterable & Hashable,
        Selection.AllCases: RandomAccessCollection
{
    @Binding private var selection: Selection
    @Environment(\.isEnabled) var isEnabled

    private let content: (Selection,Bool) -> Content

    public init(selection: Binding<Selection>,
                @ViewBuilder content: @escaping (Selection,Bool) -> Content)
    {
        self._selection = selection
        self.content = content
    }

    public var body: some View {
        HStack {
            ForEach(Selection.allCases, id: \.self) { value in
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

public struct VerticalLimitedSelectionPicker<Selection, Content: View> : View
  where Selection: CaseIterable & Hashable,
        Selection.AllCases: RandomAccessCollection
{
    @Binding private var selection: Selection
    @Environment(\.isEnabled) var isEnabled

    private let content: (Selection,Bool) -> Content

    public init(selection: Binding<Selection>,
                @ViewBuilder content: @escaping (Selection,Bool) -> Content)
    {
        self._selection = selection
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading) {
            ForEach(Selection.allCases, id: \.self) { value in
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
