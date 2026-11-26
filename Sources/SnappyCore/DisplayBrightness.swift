import Foundation

/// Brightness / volume stepping for hotkeys and software dimming math.
/// Levels are 0…1 fractions.
public enum DisplayLevel {
    /// Steps per full range — 16, like the macOS brightness OSD.
    public static let steps = 16

    /// Next level on the 1/16 grid: snaps to the grid first, so an off-grid
    /// value (set by a slider) moves to the neighbouring grid line.
    public static func step(_ value: Double, up: Bool, steps: Int = steps) -> Double {
        let n = Double(steps)
        let scaled = clamp(value) * n
        let next = up ? (scaled + 1e-6).rounded(.down) + 1 : (scaled - 1e-6).rounded(.up) - 1
        return clamp(next / n)
    }

    /// Number of lit segments in a 16-segment OSD bar.
    public static func segments(_ value: Double, steps: Int = steps) -> Int {
        Int((clamp(value) * Double(steps)).rounded())
    }

    public static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }

    /// Fraction → raw DDC value (0…maximum).
    public static func ddcValue(_ fraction: Double, maximum: UInt16) -> UInt16 {
        UInt16((clamp(fraction) * Double(maximum)).rounded())
    }

    /// Percent label ("75%").
    public static func percent(_ value: Double) -> String { "\(Int((clamp(value) * 100).rounded()))%" }
}

/// Software dimming by scaling a display's gamma table — for displays without
/// hardware brightness (no DDC, TVs, some docks). Level 0 is kept visible.
public enum SoftwareDimming {
    /// Darkest multiplier, so 0% never turns the screen fully black.
    public static let floor: Double = 0.1

    /// Multiplier applied to the gamma table at a brightness level.
    public static func factor(for level: Double) -> Double {
        floor + (1 - floor) * DisplayLevel.clamp(level)
    }

    /// Gamma table scaled for a level.
    public static func scaled(_ table: [Float], level: Double) -> [Float] {
        let f = Float(factor(for: level))
        return table.map { $0 * f }
    }
}
