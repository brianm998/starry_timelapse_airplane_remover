import SwiftUI

public struct ExpandDownButton: View {

    @Binding var isOpen: Bool

    init(_ isOpen: Binding<Bool>) { _isOpen = isOpen }

    public var body: some View {
        Button() {
            isOpen = !isOpen
        } label: {
            if isOpen {
                Image(systemName: "chevron.right.2")
                  .rotationEffect(.degrees(-90))
                  .foregroundColor(.white)
            } else {
                Image(systemName: "chevron.right.2")
                  .rotationEffect(.degrees(90))
                  .foregroundColor(.white)
            }
        }
          .buttonStyle(PlainButtonStyle())
          .cursor(isOpen ? .resizeDown : .resizeUp)
    }
}
