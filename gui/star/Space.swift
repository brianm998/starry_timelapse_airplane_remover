import SwiftUI

/*
 replace Spacer().frame(width: 20)
 with    Space(width: 20)
 */
struct Space: View {

    let height: CGFloat?
    let width: CGFloat?

    init() {
        self.height = nil
        self.width = nil
    }
    
    init(height: CGFloat) {
        self.height = height
        self.width = nil
    }
    init(width: CGFloat) {
        self.width = width
        self.height = nil
    }

    var body: some View {
        Group {
            if let height {
                if let width {
                    Spacer().frame(width: width, height: height)
                } else {
                    // no width
                    Spacer().frame(height: height)
                }
            } else {
                // no height
                if let width {
                    Spacer().frame(width: width)
                } else {
                    // no width or height 
                    Spacer()
                }
            }
        }
    }
}
