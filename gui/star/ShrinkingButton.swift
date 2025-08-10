import SwiftUI

struct ShrinkingButton: ButtonStyle {

    let backgroundColor: Color

    init(_ backgroundColor: Color = Color(red: 75/256, green: 80/256, blue: 147/256)) {
        self.backgroundColor = backgroundColor
    }
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding()
            .background(.clear)
            .foregroundColor(.white)
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.15),
                       value: configuration.isPressed)
    }
}


