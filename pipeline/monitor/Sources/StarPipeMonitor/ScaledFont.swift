import StarPipeMonitorCore
import SwiftUI

private struct FontScaleKey: EnvironmentKey {
    static let defaultValue: Double = FontScale.default
}

extension EnvironmentValues {
    var fontScale: Double {
        get { self[FontScaleKey.self] }
        set { self[FontScaleKey.self] = newValue }
    }
}

/// The macOS point size of each semantic text style. macOS ignores dynamicTypeSize, so the scale is applied to these explicitly.
enum MonitorTextStyle {
    case counter, title2, title3, body, callout, caption, caption2

    var basePointSize: Double {
        switch self {
        case .counter: 24
        case .title2: 17
        case .title3: 15
        case .body: 13
        case .callout: 12
        case .caption, .caption2: 10
        }
    }
}

private struct ScaledFont: ViewModifier {
    @Environment(\.fontScale) private var scale
    let style: MonitorTextStyle
    let weight: Font.Weight
    let monospaced: Bool

    func body(content: Content) -> some View {
        // the tile counter is the only rounded text
        let design: Font.Design = monospaced ? .monospaced : style == .counter ? .rounded : .default
        content.font(.system(size: style.basePointSize * scale, weight: weight, design: design))
    }
}

extension View {
    /// `.font(style)` that follows the window's font scale, keeping weight and monospacing.
    func scaledFont(_ style: MonitorTextStyle, weight: Font.Weight = .regular, monospaced: Bool = false) -> some View {
        modifier(ScaledFont(style: style, weight: weight, monospaced: monospaced))
    }
}
