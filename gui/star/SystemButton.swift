import Foundation
import SwiftUI

// a button with a system name

struct SystemButton: View {

    let name: String
    let shortcutKey: KeyEquivalent
    let modifiers: EventModifiers
    let color: Color
    let size: CGFloat
    let toolTip: String
    let action: () -> Void

    init(named name: String,
         shortcutKey: KeyEquivalent,
         modifiers: EventModifiers = [],
         color: Color,
         size: CGFloat = 30,
         toolTip: String,
         action: @escaping () -> Void)
    {
        self.name = name
        self.shortcutKey = shortcutKey
        self.modifiers = modifiers
        self.color = color
        self.size = size
        self.toolTip = toolTip
        self.action = action
    }
    var body: some View {
        //Log.d("button \(name) using modifiers \(modifiers)")
        return ZStack {
            Button("", action: action)
              .opacity(0)
              .keyboardShortcut(shortcutKey, modifiers: modifiers)
            
            Button(action: action) {
                buttonImage(name, size: size)
            }
              .buttonStyle(PlainButtonStyle())                            
              .help(toolTip)
              .foregroundColor(color)
        }
    }
}

public func buttonImage(_ name: String, size: CGFloat) -> some View {
    return Image(systemName: name)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .frame(maxWidth: size,
             maxHeight: size,
             alignment: .center)
}
