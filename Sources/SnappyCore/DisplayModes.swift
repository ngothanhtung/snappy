import Foundation
import CoreGraphics

/// One display mode, copied out of a CGDisplayMode so the choice logic is testable.
public struct DisplayModeInfo: Hashable, Sendable {
    /// `CGDisplayModeGetIODisplayModeID` — identifies the mode on its display.
    public let id: Int32
    /// Size in points (what "looks like" in System Settings).
    public let width: Int
    public let height: Int
    /// Backing size in pixels.
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double
    public let isUsableForDesktop: Bool

    public init(id: Int32, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int,
                refreshRate: Double, isUsableForDesktop: Bool = true) {
        self.id = id
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.isUsableForDesktop = isUsableForDesktop
    }

    public var isHiDPI: Bool { pixelWidth > width }

    /// Refresh rate rounded the way macOS shows it (59.94 → 60, 0 → unknown).
    public var roundedRefreshRate: Int { Int(refreshRate.rounded()) }
}

/// A point size + HiDPI flag; several refresh rates may share it.
public struct DisplayResolution: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let isHiDPI: Bool

    public init(width: Int, height: Int, isHiDPI: Bool) {
        self.width = width
        self.height = height
        self.isHiDPI = isHiDPI
    }

    public init(_ mode: DisplayModeInfo) {
        self.init(width: mode.width, height: mode.height, isHiDPI: mode.isHiDPI)
    }

    public var label: String { "\(width) \u{00D7} \(height)" }
}

/// Turns a raw mode list into the resolution / refresh-rate menus.
public enum DisplayModeCatalog {
    /// Distinct desktop-usable resolutions, largest first, HiDPI before
    /// low-resolution for the same size.
    public static func resolutions(_ modes: [DisplayModeInfo]) -> [DisplayResolution] {
        var seen = Set<DisplayResolution>()
        var out: [DisplayResolution] = []
        for m in modes where m.isUsableForDesktop {
            let r = DisplayResolution(m)
            if seen.insert(r).inserted { out.append(r) }
        }
        return out.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.isHiDPI && !$1.isHiDPI
        }
    }

    /// Distinct refresh rates offered at a resolution, highest first.
    public static func refreshRates(for resolution: DisplayResolution, in modes: [DisplayModeInfo]) -> [Int] {
        let rates = modes.filter { $0.isUsableForDesktop && DisplayResolution($0) == resolution }
            .map(\.roundedRefreshRate)
        return Array(Set(rates)).sorted(by: >)
    }

    /// Mode to switch to for a resolution: keeps the current refresh rate when
    /// offered, else the highest; prefers the mode with the largest backing
    /// store (sharpest) when several match.
    public static func mode(for resolution: DisplayResolution, keepingRateOf current: DisplayModeInfo?,
                            in modes: [DisplayModeInfo]) -> DisplayModeInfo? {
        let candidates = modes.filter { $0.isUsableForDesktop && DisplayResolution($0) == resolution }
        guard !candidates.isEmpty else { return nil }
        let rate = current?.roundedRefreshRate
        let sameRate = candidates.filter { $0.roundedRefreshRate == rate }
        let pool = sameRate.isEmpty ? candidates : sameRate
        return pool.max {
            if $0.roundedRefreshRate != $1.roundedRefreshRate { return $0.roundedRefreshRate < $1.roundedRefreshRate }
            return $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight
        }
    }

    /// Mode for a refresh rate at the current resolution.
    public static func mode(forRate rate: Int, at current: DisplayModeInfo,
                            in modes: [DisplayModeInfo]) -> DisplayModeInfo? {
        let res = DisplayResolution(current)
        return modes.filter { $0.isUsableForDesktop && DisplayResolution($0) == res && $0.roundedRefreshRate == rate }
            .max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
    }
}

/// Display arrangement math (global CG coordinates, top-left origin).
public enum DisplayArrangement {
    /// New origins making `main` the main display: the main display is the one
    /// at (0,0), so every display shifts by the new main's current origin.
    public static func originsMakingMain<ID: Hashable>(_ main: ID, bounds: [ID: CGRect]) -> [ID: CGPoint]? {
        guard let shift = bounds[main]?.origin else { return nil }
        return bounds.mapValues { CGPoint(x: $0.origin.x - shift.x, y: $0.origin.y - shift.y) }
    }
}

/// Rotation choices.
public enum DisplayRotation {
    public static let all = [0, 90, 180, 270]

    public static func label(_ degrees: Int) -> String {
        degrees == 0 ? "Standard" : "\(degrees)\u{00B0}"
    }
}
