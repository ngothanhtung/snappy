import Foundation

/// Colour theme for the whole mini display. Colours are 0xRRGGBB; the card,
/// its outline and the bar tracks are one tint at different opacities.
public struct MiniDisplayTheme: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var backgroundTop: UInt32
    public var backgroundBottom: UInt32
    /// Card fill / outline / bar track: `tint` at these opacities.
    public var tint: UInt32
    public var cardAlpha: Double
    public var strokeAlpha: Double
    public var trackAlpha: Double
    public var text: UInt32
    public var textDim: UInt32
    // Widget accents.
    public var cpu: UInt32
    public var gpu: UInt32
    public var memory: UInt32
    public var network: UInt32
    public var storage: UInt32
    public var lunar: UInt32
    public var claude: UInt32
    // Status: temperatures, thermal state, usage limits, overdue items.
    public var good: UInt32
    public var warning: UInt32
    public var critical: UInt32

    /// The original dark blue look.
    public static let midnight = MiniDisplayTheme(
        id: "midnight", name: "Midnight", backgroundTop: 0x0B1020, backgroundBottom: 0x151C33,
        tint: 0xFFFFFF, cardAlpha: 0.05, strokeAlpha: 0.08, trackAlpha: 0.10,
        text: 0xF2F4F8, textDim: 0x8A93A8,
        cpu: 0x4FC3F7, gpu: 0xB388FF, memory: 0x69F0AE, network: 0xFFD54F, storage: 0xFF8A65,
        lunar: 0xF48FB1, claude: 0xD97757, good: 0x69F0AE, warning: 0xFFAB40, critical: 0xFF5252)

    public static let graphite = MiniDisplayTheme(
        id: "graphite", name: "Graphite", backgroundTop: 0x0E0E10, backgroundBottom: 0x1A1A1D,
        tint: 0xFFFFFF, cardAlpha: 0.06, strokeAlpha: 0.09, trackAlpha: 0.12,
        text: 0xEDEDED, textDim: 0x8E8E93,
        cpu: 0x64D2FF, gpu: 0xBF8CFF, memory: 0x30D158, network: 0xFFD60A, storage: 0xFF9F0A,
        lunar: 0xFF6482, claude: 0xE08A63, good: 0x30D158, warning: 0xFF9F0A, critical: 0xFF453A)

    public static let ocean = MiniDisplayTheme(
        id: "ocean", name: "Ocean", backgroundTop: 0x021B2B, backgroundBottom: 0x06324A,
        tint: 0xBFEFFF, cardAlpha: 0.07, strokeAlpha: 0.12, trackAlpha: 0.13,
        text: 0xE6F7FF, textDim: 0x7FA7BC,
        cpu: 0x4DD0E1, gpu: 0x80CBC4, memory: 0x64FFDA, network: 0xFFE082, storage: 0x81D4FA,
        lunar: 0xFFAB91, claude: 0xFFB74D, good: 0x64FFDA, warning: 0xFFCA28, critical: 0xFF7043)

    public static let forest = MiniDisplayTheme(
        id: "forest", name: "Forest", backgroundTop: 0x0B1A12, backgroundBottom: 0x14291D,
        tint: 0xD8FFE4, cardAlpha: 0.06, strokeAlpha: 0.10, trackAlpha: 0.12,
        text: 0xEAF5EC, textDim: 0x86A08E,
        cpu: 0xA5D6A7, gpu: 0xC5E1A5, memory: 0x66BB6A, network: 0xFFF176, storage: 0xFFB74D,
        lunar: 0xF48FB1, claude: 0xE6A15C, good: 0x81C784, warning: 0xFFB300, critical: 0xEF5350)

    public static let sunset = MiniDisplayTheme(
        id: "sunset", name: "Sunset", backgroundTop: 0x1E0B1E, backgroundBottom: 0x3A1424,
        tint: 0xFFD9E0, cardAlpha: 0.07, strokeAlpha: 0.11, trackAlpha: 0.13,
        text: 0xFFF1F0, textDim: 0xB4919B,
        cpu: 0xFF8A80, gpu: 0xEA80FC, memory: 0xFFD180, network: 0xFFE57F, storage: 0xFF9E80,
        lunar: 0xF8BBD0, claude: 0xFFAB91, good: 0xB9F6CA, warning: 0xFFD740, critical: 0xFF5252)

    public static let arctic = MiniDisplayTheme(
        id: "arctic", name: "Arctic", backgroundTop: 0x2E3440, backgroundBottom: 0x3B4252,
        tint: 0xECEFF4, cardAlpha: 0.07, strokeAlpha: 0.10, trackAlpha: 0.14,
        text: 0xECEFF4, textDim: 0x9AA5B8,
        cpu: 0x88C0D0, gpu: 0xB48EAD, memory: 0xA3BE8C, network: 0xEBCB8B, storage: 0xD08770,
        lunar: 0xE5A3B5, claude: 0xD08770, good: 0xA3BE8C, warning: 0xEBCB8B, critical: 0xFF8A8A)

    /// Retro terminal: amber on black.
    public static let amber = MiniDisplayTheme(
        id: "amber", name: "Amber Terminal", backgroundTop: 0x000000, backgroundBottom: 0x0D0700,
        tint: 0xFFB000, cardAlpha: 0.05, strokeAlpha: 0.22, trackAlpha: 0.14,
        text: 0xFFC233, textDim: 0xA87414,
        cpu: 0xFFB000, gpu: 0xFFB000, memory: 0xFFB000, network: 0xFFB000, storage: 0xFFB000,
        lunar: 0xFFD27A, claude: 0xFFB000, good: 0xFFB000, warning: 0xFFE08A, critical: 0xFF5A1F)

    /// Light background, dark text.
    public static let paper = MiniDisplayTheme(
        id: "paper", name: "Paper (Light)", backgroundTop: 0xF4F1EA, backgroundBottom: 0xE6E1D6,
        tint: 0x000000, cardAlpha: 0.04, strokeAlpha: 0.10, trackAlpha: 0.09,
        text: 0x1C1C1E, textDim: 0x6E6A62,
        cpu: 0x0277BD, gpu: 0x6A1B9A, memory: 0x2E7D32, network: 0xB26A00, storage: 0xD84315,
        lunar: 0xC2185B, claude: 0xC15F3C, good: 0x2E7D32, warning: 0xB45309, critical: 0xC62828)

    public static let all: [MiniDisplayTheme] = [midnight, graphite, ocean, forest, sunset, arctic, amber, paper]

    /// The theme with this id, or Midnight.
    public static func named(_ id: String?) -> MiniDisplayTheme {
        all.first { $0.id == id } ?? midnight
    }
}
