import SwiftUI
import SnappyCore

/// Settings ▸ Displays: software dimming and how each display is controlled.
struct DisplaySettingsView: View {
    @ObservedObject private var center = DisplayControlCenter.shared

    var body: some View {
        Form {
            Section {
                Toggle("Dim with software when there is no hardware control", isOn: Binding(
                    get: { center.softwareDimmingEnabled },
                    set: { center.setSoftwareDimmingEnabled($0) }
                ))
                ForEach(center.displays) { d in
                    LabeledContent(d.name, value: Self.methodText(center.controls[d.id]))
                }
            } header: {
                Text("Brightness")
            } footer: {
                Text("External monitors are controlled over DDC/CI (brightness, contrast, volume) when they support it — "
                     + "turn on DDC/CI in the monitor's own menu if it's missing. Others are dimmed by scaling their "
                     + "colour table. Brightness hotkeys (Shortcuts tab) act on the display under the pointer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }

    private static func methodText(_ c: DisplayControls?) -> String {
        guard let c else { return "\u{2014}" }
        if c.probing { return "Checking\u{2026}" }
        var parts: [String]
        switch c.brightnessMethod {
        case .native: parts = ["Built-in control"]
        case .ddc: parts = ["DDC/CI"]
        case .software: parts = ["Software dimming"]
        case .none: parts = ["No brightness control"]
        }
        if c.contrast != nil { parts.append("contrast") }
        if c.volume != nil { parts.append("volume") }
        return parts.joined(separator: ", ")
    }
}
