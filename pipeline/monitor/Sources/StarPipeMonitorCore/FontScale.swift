import Foundation

/// The monitor window's text scale: ⌘+ / ⌘− step it, ⌘0 resets it. Pure arithmetic so it can be tested without the UI.
public enum FontScale {
    public static let `default`: Double = 1.0
    public static let minimum: Double = 0.7
    public static let maximum: Double = 2.0
    public static let step: Double = 0.1

    /// Clamps into the allowed range; a garbage stored value (NaN, infinite, zero, negative) becomes the default.
    public static func clamped(_ scale: Double) -> Double {
        guard scale.isFinite, scale > 0 else { return `default` }
        return round(min(maximum, max(minimum, scale)) * 100) / 100
    }

    public static func bigger(_ scale: Double) -> Double { clamped(clamped(scale) + step) }

    public static func smaller(_ scale: Double) -> Double { clamped(clamped(scale) - step) }
}
