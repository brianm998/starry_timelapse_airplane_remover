import SwiftUI

struct CircularProgressView: View {

    @Binding private var progress: Double

    init(progress: Binding<Double>) {
        _progress = progress
    }
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    Color.blue.opacity(0.5),
                    lineWidth: 80
                )
            Circle()
                // 2
                .trim(from: 0, to: progress)
                .stroke(
                    Color.blue,
                    style: StrokeStyle(
                      lineWidth: 80,
                      lineCap: .round
                    )
                )
                .rotationEffect(.degrees(-90))
        }
    }
}

