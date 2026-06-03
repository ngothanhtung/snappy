import KeyboardShortcuts
import MagnetCore

/// One global shortcut name per layout, with sensible defaults
/// (Ctrl+Option based, similar to Magnet/Rectangle).
extension KeyboardShortcuts.Name {
    static let leftHalf       = Self("leftHalf",       default: .init(.leftArrow,  modifiers: [.control, .option]))
    static let rightHalf      = Self("rightHalf",      default: .init(.rightArrow, modifiers: [.control, .option]))
    static let topHalf        = Self("topHalf",        default: .init(.upArrow,    modifiers: [.control, .option]))
    static let bottomHalf     = Self("bottomHalf",     default: .init(.downArrow,  modifiers: [.control, .option]))
    static let firstThird     = Self("firstThird",     default: .init(.d, modifiers: [.control, .option]))
    static let centerThird    = Self("centerThird",    default: .init(.f, modifiers: [.control, .option]))
    static let lastThird      = Self("lastThird",      default: .init(.g, modifiers: [.control, .option]))
    static let firstTwoThirds = Self("firstTwoThirds", default: .init(.e, modifiers: [.control, .option]))
    static let lastTwoThirds  = Self("lastTwoThirds",  default: .init(.t, modifiers: [.control, .option]))
}

/// Pairs each layout with its shortcut name and a human-readable title.
/// Single source of truth used by both the hotkey manager and the menus.
struct LayoutBinding {
    let layout: WindowLayout
    let name: KeyboardShortcuts.Name
    let title: String

    static let all: [LayoutBinding] = [
        .init(layout: .leftHalf,       name: .leftHalf,       title: "Left Half"),
        .init(layout: .rightHalf,      name: .rightHalf,      title: "Right Half"),
        .init(layout: .topHalf,        name: .topHalf,        title: "Top Half"),
        .init(layout: .bottomHalf,     name: .bottomHalf,     title: "Bottom Half"),
        .init(layout: .firstThird,     name: .firstThird,     title: "First Third"),
        .init(layout: .centerThird,    name: .centerThird,    title: "Center Third"),
        .init(layout: .lastThird,      name: .lastThird,      title: "Last Third"),
        .init(layout: .firstTwoThirds, name: .firstTwoThirds, title: "First Two Thirds"),
        .init(layout: .lastTwoThirds,  name: .lastTwoThirds,  title: "Last Two Thirds"),
    ]
}
