import SwiftUI
import StarCore
import logging

public struct StarPicker<Selection, Content: View> : View
  where Selection: CaseIterable & Hashable,
        Selection.AllCases: RandomAccessCollection
{
    @Binding private var selection: Selection
    @Environment(\.isEnabled) var isEnabled

    private let title: String?
    private let content: (Selection,Bool) -> Content

    public init(_ title: String? = nil,
                selection: Binding<Selection>,
                @ViewBuilder content: @escaping (Selection,Bool) -> Content)
    {
        self.title = title
        self._selection = selection
        self.content = content
    }

    let foobar = 134.0/255.0 // XXX make a custom color from these
    let foobar2 = 138.0/255.0

    public var body: some View {
        HStack {
            if let title {
                Text(title)
                  .foregroundColor(.white)
            }
            HStack {
                ForEach(Selection.allCases, id: \.self) { value in
                    if value == selection {
                        content(value, isEnabled)
                          .padding(4)
                          .background(.white)
                          .cornerRadius(5)
                          .onTapGesture { _ in
                              selection = value
                          }
                    } else {
                        content(value, isEnabled)
                          .padding(4)
                          .onTapGesture { _ in
                              selection = value
                          }
                    }
                }
            }
              .background(Color(red: foobar, green: foobar, blue: foobar2))
              .cornerRadius(5)
        }
    }    
}
