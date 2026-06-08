import KeyboardShortcuts
import SnappyCore

/// One global shortcut name per action, with sensible defaults
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
    // Fill the whole usable screen (not macOS full-screen mode).
    static let maximize       = Self("maximize",       default: .init(.return, modifiers: [.control, .option]))
    // Move the focused window to the next/previous display.
    static let nextDisplay     = Self("nextDisplay",     default: .init(.rightArrow, modifiers: [.control, .option, .command]))
    static let previousDisplay = Self("previousDisplay", default: .init(.leftArrow,  modifiers: [.control, .option, .command]))
}

/// An action a shortcut (or menu item) can trigger.
enum AppAction {
    case layout(WindowLayout)
    case moveToDisplay(DisplayOrdering.Direction)
}

/// Pairs each action with its shortcut name and a human-readable title.
/// Single source of truth for hotkeys, menu, and settings.
struct ActionBinding {
    let name: KeyboardShortcuts.Name
    let title: String
    let action: AppAction
    /// SF Symbol name shown next to the action in the menu.
    let symbol: String
}

enum Bindings {
    static let layouts: [ActionBinding] = [
        .init(name: .maximize,       title: "Maximize",         action: .layout(.maximize),       symbol: "rectangle.fill"),
        .init(name: .leftHalf,       title: "Left Half",        action: .layout(.leftHalf),       symbol: "rectangle.lefthalf.filled"),
        .init(name: .rightHalf,      title: "Right Half",       action: .layout(.rightHalf),      symbol: "rectangle.righthalf.filled"),
        .init(name: .topHalf,        title: "Top Half",         action: .layout(.topHalf),        symbol: "rectangle.tophalf.filled"),
        .init(name: .bottomHalf,     title: "Bottom Half",      action: .layout(.bottomHalf),     symbol: "rectangle.bottomhalf.filled"),
        .init(name: .firstThird,     title: "First Third",      action: .layout(.firstThird),     symbol: "rectangle.lefthalf.inset.filled"),
        .init(name: .centerThird,    title: "Center Third",     action: .layout(.centerThird),    symbol: "rectangle.inset.filled"),
        .init(name: .lastThird,      title: "Last Third",       action: .layout(.lastThird),      symbol: "rectangle.righthalf.inset.filled"),
        .init(name: .firstTwoThirds, title: "First Two Thirds", action: .layout(.firstTwoThirds), symbol: "rectangle.split.3x1.fill"),
        .init(name: .lastTwoThirds,  title: "Last Two Thirds",  action: .layout(.lastTwoThirds),  symbol: "rectangle.split.3x1"),
    ]

    static let displays: [ActionBinding] = [
        .init(name: .nextDisplay,     title: "Move to Next Display",     action: .moveToDisplay(.next),     symbol: "arrow.right.to.line"),
        .init(name: .previousDisplay, title: "Move to Previous Display", action: .moveToDisplay(.previous), symbol: "arrow.left.to.line"),
    ]

    static var all: [ActionBinding] { layouts + displays }
}
