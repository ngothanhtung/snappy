# Snappy

**English** | [Tiếng Việt](README.vi.md)

Snappy is a macOS menu bar app for snapping the focused window with global
keyboard shortcuts.

## Features

- **Halves:** left half, right half, top half, bottom half
- **Thirds:** first third, center third, last third, first two thirds, last two thirds
- **Display movement:** move the active window to the previous or next display while preserving its relative position and size
- Customizable global shortcuts in the Settings window
- Multi-display support; snapping is calculated within the display that contains the window
- Custom template menu bar icon that adapts to light and dark menu bars
- Launch at login

## Default Shortcuts

| Action | Shortcut |
| --- | --- |
| Left / Right / Top / Bottom Half | Control + Option + Arrow |
| First / Center / Last Third | Control + Option + D / F / G |
| First / Last Two Thirds | Control + Option + E / T |
| Move to Previous / Next Display | Control + Option + Command + Left / Right |

Change shortcuts from **menu bar -> Settings...**

## Build And Run

```bash
swift test              # run unit tests for the core logic
./Scripts/bundle.sh     # build release and assemble Snappy.app
open ./Snappy.app
```

On first launch, macOS will ask for **Accessibility** permission. Enable Snappy
in **System Settings -> Privacy & Security -> Accessibility**, then the global
shortcuts will work.

## Important: Accessibility Permission And Rebuilds

macOS ties Accessibility permission to the app's **code signature**. When the app
is signed ad hoc, which is the default in `bundle.sh`, every rebuild gets a new
signature. That invalidates the previous Accessibility grant, so snapping can
appear to fail silently.

Quick fix after each ad-hoc build: open **System Settings -> Privacy & Security
-> Accessibility**, remove Snappy with the minus button, then add the newly built
app again. The app also shows guidance when a shortcut is pressed without the
required permission.

Recommended fix: sign with a stable self-signed code-signing certificate so the
permission survives rebuilds.

1. Open **Keychain Access -> Certificate Assistant -> Create a Certificate...**
2. Use:
   - Name: `Snappy Self-Signed`
   - Type: `Code Signing`
3. Build with that identity:

```bash
export SNAPPY_SIGN_IDENTITY="Snappy Self-Signed"
./Scripts/bundle.sh
```

Grant Accessibility permission once. Future builds signed with the same identity
will keep the permission.

## Architecture

`SnappyCore` contains pure, platform-independent logic with unit tests:

- `LayoutCalculator` computes target `CGRect` values for layouts
- `Geometry` converts between AppKit and Accessibility coordinate systems
- `DisplayMapper` maps a window proportionally between displays
- `DisplayOrdering` selects the previous or next display by position

`Snappy` contains the app layer built with AppKit, Accessibility APIs, and
KeyboardShortcuts:

- `WindowEngine`
- `ScreenProvider`
- `WindowManager`
- `HotkeyManager`
- `MenuBarIcon`
- `StatusMenuController`
- `SettingsView`
- `AppDelegate`

Detailed design notes:
[`docs/superpowers/specs/2026-06-04-macos-window-manager-design.md`](docs/superpowers/specs/2026-06-04-macos-window-manager-design.md)

## Custom Icons

Drop `MenuBarIcon.png` or `MenuBarIcon.pdf` into `Resources/`, then rebuild:

```bash
./Scripts/bundle.sh
```

The app will use that file instead of the built-in menu bar icon. A black shape
on a transparent background is recommended because Snappy treats it as a template
image and adapts it automatically for light and dark menu bars.

For menu bar and app icon details, see [`Resources/README.md`](Resources/README.md).

## Requirements

- macOS 14 or later
- Swift 5.9 or later
- Accessibility permission

## Notes

- Snappy runs non-sandboxed because the macOS sandbox prevents controlling other
  apps' windows through Accessibility APIs.
- It is intended as a personal utility and is not suitable for Mac App Store
  distribution in its current form.
- Dependency: [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts)

## Author

Tony Woo (Ngô Thanh Tùng)
