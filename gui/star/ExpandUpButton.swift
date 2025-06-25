import SwiftUI

public struct ExpandUpButton: View {

    @Binding var isOpen: Bool

    init(_ isOpen: Binding<Bool>) { _isOpen = isOpen }

    public var body: some View {
        Button() {
            isOpen = !isOpen
        } label: {
            if isOpen {
                Image(systemName: "chevron.right.2")
                  .rotationEffect(.degrees(90))
                  .foregroundColor(.gray)
            } else {
                Image(systemName: "chevron.right.2")
                  .rotationEffect(.degrees(-90))
                  .foregroundColor(.gray)
            }
        }
          .buttonStyle(PlainButtonStyle())
          .cursor(isOpen ? .resizeDown : .resizeUp)
    }
}
