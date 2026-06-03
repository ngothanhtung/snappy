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
}

enum Bindings {
    static let layouts: [ActionBinding] = [
        .init(name: .leftHalf,       title: "Left Half",        action: .layout(.leftHalf)),
        .init(name: .rightHalf,      title: "Right Half",       action: .layout(.rightHalf)),
        .init(name: .topHalf,        title: "Top Half",         action: .layout(.topHalf)),
        .init(name: .bottomHalf,     title: "Bottom Half",      action: .layout(.bottomHalf)),
        .init(name: .firstThird,     title: "First Third",      action: .layout(.firstThird)),
        .init(name: .centerThird,    title: "Center Third",     action: .layout(.centerThird)),
        .init(name: .lastThird,      title: "Last Third",       action: .layout(.lastThird)),
        .init(name: .firstTwoThirds, title: "First Two Thirds", action: .layout(.firstTwoThirds)),
        .init(name: .lastTwoThirds,  title: "Last Two Thirds",  action: .layout(.lastTwoThirds)),
    ]

    static let displays: [ActionBinding] = [
        .init(name: .nextDisplay,     title: "Move to Next Display",     action: .moveToDisplay(.next)),
        .init(name: .previousDisplay, title: "Move to Previous Display", action: .moveToDisplay(.previous)),
    ]

    static var all: [ActionBinding] { layouts + displays }
}
