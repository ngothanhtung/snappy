import Foundation

/// One widget of the mini display dashboard. Each takes one slot of the
/// n-column × 2-row grid, except the photo, which takes a whole column.
public enum MiniDisplayWidget: String, CaseIterable, Codable, Sendable, Identifiable {
    case cpu, gpu, ram, storage, clock, network, topCPU, topMemory, claude, calendar, reminders, photo

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .ram: return "RAM"
        case .storage: return "Storage"
        case .clock: return "Clock"
        case .network: return "Network"
        case .topCPU: return "Top CPU Apps"
        case .topMemory: return "Top Memory Apps"
        case .claude: return "Claude Usage"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .photo: return "Photos"
        }
    }

    /// SF Symbol for settings UI.
    public var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "cube"
        case .ram: return "memorychip"
        case .storage: return "internaldrive"
        case .clock: return "clock"
        case .network: return "network"
        case .topCPU: return "list.number"
        case .topMemory: return "list.bullet.rectangle"
        case .claude: return "sparkles"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .photo: return "photo.on.rectangle"
        }
    }

    /// The photo fills its column (both rows).
    public var spansColumn: Bool { self == .photo }
}

/// What the mini display shows where: columns left to right, each with a top
/// and a bottom slot (nil = empty).
public struct MiniDisplayLayout: Codable, Equatable, Sendable {
    public struct Column: Codable, Equatable, Sendable {
        public var top: MiniDisplayWidget?
        public var bottom: MiniDisplayWidget?
        public init(_ top: MiniDisplayWidget?, _ bottom: MiniDisplayWidget?) {
            self.top = top
            self.bottom = bottom
        }
        public var widgets: [MiniDisplayWidget] { [top, bottom].compactMap { $0 } }
    }

    public static let maxColumns = 8

    public var columns: [Column]
    public init(columns: [Column]) { self.columns = Array(columns.prefix(Self.maxColumns)) }

    /// CPU/GPU, RAM/Storage, Clock/Network.
    public static let standard = MiniDisplayLayout(columns: [
        Column(.cpu, .gpu), Column(.ram, .storage), Column(.clock, .network),
    ])

    /// The layout matching the old per-card switches (before slots existed).
    public static func migrated(photos: Bool, topApps: Bool, calendar: Bool,
                                reminders: Bool, claude: Bool) -> MiniDisplayLayout {
        var cols = standard.columns
        if topApps { cols.append(Column(.topCPU, .topMemory)) }
        if claude { cols.append(Column(.claude, nil)) }
        if calendar || reminders {
            cols.append(Column(calendar ? .calendar : .reminders, calendar && reminders ? .reminders : nil))
        }
        if photos { cols.append(Column(.photo, nil)) }
        return MiniDisplayLayout(columns: cols)
    }

    public func contains(_ w: MiniDisplayWidget) -> Bool {
        columns.contains { $0.top == w || $0.bottom == w }
    }

    /// Puts `widget` (nil = empty) in one slot. The photo takes the whole column,
    /// so placing it clears the other slot, and placing anything in a photo
    /// column replaces the photo.
    public mutating func set(_ widget: MiniDisplayWidget?, column: Int, top: Bool) {
        guard columns.indices.contains(column) else { return }
        if widget?.spansColumn == true {
            columns[column] = Column(widget, nil)
        } else if columns[column].widgets.contains(where: \.spansColumn) {
            columns[column] = Column(widget, nil)
        } else if top {
            columns[column].top = widget
        } else {
            columns[column].bottom = widget
        }
    }

    /// Whether the column is one tall photo slot.
    public func isPhotoColumn(_ column: Int) -> Bool {
        columns.indices.contains(column) && columns[column].widgets.contains(where: \.spansColumn)
    }

    /// Adds empty columns or drops the last ones.
    public mutating func setColumnCount(_ n: Int) {
        let n = max(1, min(Self.maxColumns, n))
        if columns.count > n { columns.removeLast(columns.count - n) }
        while columns.count < n { columns.append(Column(nil, nil)) }
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// nil for missing or unreadable data; unknown widget names become empty slots.
    public static func decode(_ data: Data?) -> MiniDisplayLayout? {
        guard let data,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cols = raw["columns"] as? [[String: Any]] else { return nil }
        func widget(_ v: Any?) -> MiniDisplayWidget? { (v as? String).flatMap(MiniDisplayWidget.init(rawValue:)) }
        return MiniDisplayLayout(columns: cols.map { Column(widget($0["top"]), widget($0["bottom"])) })
    }

    /// Where a widget is drawn, in a top-left-origin area.
    public struct Placement: Equatable, Sendable {
        public var widget: MiniDisplayWidget
        public var x, y, width, height: Double
        public init(widget: MiniDisplayWidget, x: Double, y: Double, width: Double, height: Double) {
            self.widget = widget
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// Lays the columns out in `width`×`height` with `gap` around and between cards.
    /// Empty columns are skipped and the shown columns share the width equally,
    /// except a photo column, which is as wide as
    /// the photo frame (`photoAspect` = w/h) and shrinks only if the others would
    /// get narrower than 120 px. A column with one widget gives it the full height.
    public func placements(width: Double, height: Double, gap: Double, photoAspect: Double) -> [Placement] {
        let shown = MiniDisplayLayout(columns: columns.filter { !$0.widgets.isEmpty })
        guard !shown.columns.isEmpty else { return [] }
        return shown.layoutShown(width: width, height: height, gap: gap, photoAspect: photoAspect)
    }

    private func layoutShown(width: Double, height: Double, gap: Double, photoAspect: Double) -> [Placement] {
        let fullH = height - 2 * gap
        let halfH = (fullH - gap) / 2
        let isPhoto = columns.indices.map(isPhotoColumn)
        let photoCount = Double(isPhoto.filter { $0 }.count)
        let others = Double(columns.count) - photoCount
        let inner = width - gap * Double(columns.count + 1)
        var pw = (fullH * photoAspect).rounded()
        if photoCount > 0 {
            pw = others > 0 ? max(0, min(pw, (inner - others * 120) / photoCount)) : inner / photoCount
        }
        let cw = others > 0 ? max(0, inner - pw * photoCount) / others : 0
        var x = gap
        var out: [Placement] = []
        for (i, col) in columns.enumerated() {
            let w = isPhoto[i] ? pw : cw
            if isPhoto[i] {
                out.append(Placement(widget: .photo, x: x, y: gap, width: w, height: fullH))
            } else if col.widgets.count == 1 {
                out.append(Placement(widget: col.widgets[0], x: x, y: gap, width: w, height: fullH))
            } else if let top = col.top, let bottom = col.bottom {
                out.append(Placement(widget: top, x: x, y: gap, width: w, height: halfH))
                out.append(Placement(widget: bottom, x: x, y: gap + halfH + gap, width: w, height: halfH))
            }
            x += w + gap
        }
        return out
    }
}
