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
    private let identifier: ((Selection) -> String)?
    private let content: (Selection,Bool) -> Content

    /// `identifier` names each option for UI tests (`mode.edit`), which also see which one is selected.
    public init(_ title: String? = nil,
                selection: Binding<Selection>,
                identifier: ((Selection) -> String)? = nil,
                @ViewBuilder content: @escaping (Selection,Bool) -> Content)
    {
        self.title = title
        self.identifier = identifier
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
                          .optionIdentity(identifier?(value), selected: true)
                    } else {
                        content(value, isEnabled)
                          .padding(4)
                          .onTapGesture { _ in
                              selection = value
                          }
                          .optionIdentity(identifier?(value), selected: false)
                    }
                }
            }
              .background(Color(red: foobar, green: foobar, blue: foobar2))
              .cornerRadius(5)
        }
    }    
}

public struct VerticalStarPicker<Selection, Content: View> : View
  where Selection: CaseIterable & Hashable,
        Selection.AllCases: RandomAccessCollection
{
    @Binding private var selection: Selection
    @Environment(\.isEnabled) var isEnabled

    private let title: String?
    private let content: (Selection,Bool,Bool) -> Content

    public init(_ title: String? = nil,
                selection: Binding<Selection>,
                @ViewBuilder content: @escaping (Selection,Bool,Bool) -> Content)
    {
        self.title = title
        self._selection = selection
        self.content = content
    }

    let foobar = 134.0/255.0 // XXX make a custom color from these
    let foobar2 = 138.0/255.0

    public var body: some View {
        VStack(alignment: .leading) {
            if let title {
                Text(title)
                  .foregroundColor(.white)
            }
            VStack(alignment: .leading) {
                ForEach(Selection.allCases, id: \.self) { value in
                    ZStack(alignment: .leading) {
                        if value == selection {
                            Color.white
                              .cornerRadius(5)
                              .opacity(0.6)
                        }

                        HStack {
                            content(value, isEnabled, value == selection)
                              .padding(4)
                              .onTapGesture { _ in
                                  selection = value
                              }
                            Spacer()
                        }
                          .fixedSize(horizontal: false, vertical: false)
                    }
                }
            }
              .fixedSize(horizontal: true, vertical: false)
              .background(Color(red: foobar, green: foobar, blue: foobar2))
              .opacity(isEnabled ? 1.0 : 0.8)
              .cornerRadius(5)
        }
    }    
}

extension View {
    /// The accessibility identifier of a picker's option, and the selected trait on the one that is; nothing when the picker is not named.
    @ViewBuilder func optionIdentity(_ identifier: String?, selected: Bool) -> some View {
        if let identifier {
            self.accessibilityIdentifier(identifier).accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            self
        }
    }
}
