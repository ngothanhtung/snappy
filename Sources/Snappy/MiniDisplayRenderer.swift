import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SnappyCore

/// Draws the mini-display dashboard (e.g. 1920x462) with Core Graphics; layout uses top-left coordinates.
final class MiniDisplayRenderer {
    let width: Int
    let height: Int
    private let space = CGColorSpaceCreateDeviceRGB()

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        applyTheme()
    }

    // MARK: Colors

    private static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    /// Colour theme; every colour below comes from it.
    var theme: MiniDisplayTheme = .midnight {
        didSet { if theme != oldValue { applyTheme() } }
    }

    private var bgTop = rgb(0), bgBottom = rgb(0), card = rgb(0), cardStroke = rgb(0), track = rgb(0)
    private var textMain = rgb(0), textDim = rgb(0)
    private var cpuColor = rgb(0), gpuColor = rgb(0), memColor = rgb(0), netColor = rgb(0)
    private var diskColor = rgb(0), lunarColor = rgb(0), claudeColor = rgb(0)
    private var goodColor = rgb(0), warnColor = rgb(0), critColor = rgb(0)

    private func applyTheme() {
        let t = theme
        bgTop = Self.rgb(t.backgroundTop)
        bgBottom = Self.rgb(t.backgroundBottom)
        card = Self.rgb(t.tint, t.cardAlpha)
        cardStroke = Self.rgb(t.tint, t.strokeAlpha)
        track = Self.rgb(t.tint, t.trackAlpha)
        textMain = Self.rgb(t.text)
        textDim = Self.rgb(t.textDim)
        cpuColor = Self.rgb(t.cpu)
        gpuColor = Self.rgb(t.gpu)
        memColor = Self.rgb(t.memory)
        netColor = Self.rgb(t.network)
        diskColor = Self.rgb(t.storage)
        lunarColor = Self.rgb(t.lunar)
        claudeColor = Self.rgb(t.claude)
        goodColor = Self.rgb(t.good)
        warnColor = Self.rgb(t.warning)
        critColor = Self.rgb(t.critical)
    }

    private func heat(_ t: Double?) -> CGColor {
        guard let t else { return textDim }
        if t >= 85 { return critColor }
        if t >= 70 { return warnColor }
        return goodColor
    }

    // MARK: Drawing

    /// - Parameters:
    ///   - layout: which widget goes in which slot (n columns × 2 rows).
    ///   - photo: what the photo widget shows (current photo, and the previous one mid-crossfade).
    ///   - agenda: calendar events / reminders for those widgets (nil while not loaded).
    ///   - claude: plan usage for the Claude widget.
    func render(_ s: MiniDisplaySnapshot, layout: MiniDisplayLayout, now: Date = Date(),
                photo: MiniDisplayPhotoFrame? = nil, agenda: MiniDisplayAgenda? = nil,
                claude: ClaudeLimitsMonitor.Snapshot? = nil) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // Flip so we can lay out top-down.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        let W = CGFloat(width), H = CGFloat(height)
        if let g = CGGradient(colorsSpace: space, colors: [bgTop, bgBottom] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: H), options: [])
        }

        // One card per slot, 16 px gutters; see MiniDisplayLayout.placements.
        let placements = layout.placements(width: Double(W), height: Double(H), gap: 16,
                                           photoAspect: Double(photo?.aspect ?? 4 / 3))
        if placements.isEmpty {
            text(ctx, "No widgets \u{2014} choose some in Snappy Settings \u{25B8} Widgets",
                 x: W / 2, y: H / 2 + 12, size: 30, color: textDim, align: .center)
        }
        for p in placements {
            let r = CGRect(x: p.x, y: p.y, width: p.width, height: p.height)
            if p.widget == .photo {
                drawPhoto(ctx, r, photo)
            } else {
                drawCard(ctx, r)
                draw(p.widget, ctx, r, s, now: now, agenda: agenda, claude: claude)
            }
        }

        // Software brightness: a black overlay. fw 5.3 accepts SetLight but never changes the backlight.
        let b = max(0.05, min(1, brightness))
        if b < 0.999 {
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: CGFloat(1 - b)))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        }

        guard let landscape = ctx.makeImage() else { return nil }
        return rotate(landscape, degreesClockwise: rotation)
    }

    /// Software brightness, 0...1.
    var brightness: Double = 1

    /// Clockwise pre-rotation applied before sending: 0, 90, 180 or 270.
    var rotation = 0

    private func rotate(_ img: CGImage, degreesClockwise deg: Int) -> CGImage? {
        let d = ((deg % 360) + 360) % 360
        if d == 0 { return img }
        let w = img.width, h = img.height
        let (ow, oh) = (d == 180) ? (w, h) : (h, w)
        guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        switch d {
        case 90:   // CG origin bottom-left: (x,y) -> (y, W-x)
            ctx.translateBy(x: 0, y: CGFloat(w))
            ctx.rotate(by: -.pi / 2)
        case 180:
            ctx.translateBy(x: CGFloat(w), y: CGFloat(h))
            ctx.rotate(by: .pi)
        default:   // 270: (x,y) -> (H-y, x)
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private func drawCard(_ ctx: CGContext, _ r: CGRect) {
        let path = CGPath(roundedRect: r, cornerWidth: 22, cornerHeight: 22, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(card)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(cardStroke)
        ctx.setLineWidth(2)
        ctx.strokePath()
    }

    /// Splits a card into top and bottom halves divided by a hairline.
    private func splitCard(_ ctx: CGContext, _ r: CGRect) -> (CGRect, CGRect) {
        let half = r.height / 2
        ctx.setFillColor(cardStroke)
        ctx.fill(CGRect(x: r.minX + 28, y: r.midY - 1, width: r.width - 56, height: 2))
        return (CGRect(x: r.minX, y: r.minY, width: r.width, height: half),
                CGRect(x: r.minX, y: r.minY + half, width: r.width, height: half))
    }

    private func draw(_ w: MiniDisplayWidget, _ ctx: CGContext, _ r: CGRect, _ s: MiniDisplaySnapshot,
                      now: Date, agenda: MiniDisplayAgenda?, claude: ClaudeLimitsMonitor.Snapshot?) {
        switch w {
        case .cpu:
            drawGauge(ctx, r, title: "CPU", badge: (temp(s.cpuTemp), heat(s.cpuTemp)),
                      value: s.cpuTotal, number: pct(s.cpuTotal), color: cpuColor,
                      notes: [(s.thermal.text, thermalColor(s.thermal))])
        case .gpu:
            drawGauge(ctx, r, title: "GPU", badge: (temp(s.gpuTemp), heat(s.gpuTemp)),
                      value: s.gpu ?? 0, number: s.gpu.map(pct) ?? "--", color: gpuColor,
                      notes: [("SoC " + temp(s.socTemp), heat(s.socTemp))])
        case .ram:
            let gb = 1024.0 * 1024 * 1024
            let used = Double(s.memUsed) / gb, memTotal = Double(s.memTotal) / gb
            let memFrac = memTotal > 0 ? used / memTotal : 0
            drawGauge(ctx, r, title: "RAM", badge: (pct(memFrac), memColor),
                      value: memFrac, number: String(format: "%.1f", used), color: memColor,
                      notes: [(String(format: "/ %.1f GB", memTotal), textDim)])
        case .storage:
            let total = Double(s.diskTotal), free = Double(s.diskFree)
            let usedFrac = total > 0 ? (total - free) / total : 0
            let f = MiniDisplayFormat.size(free), t = MiniDisplayFormat.size(total)
            drawGauge(ctx, r, title: "STORAGE", badge: (temp(s.diskTemp), heat(s.diskTemp)),
                      value: usedFrac, number: f.number, color: diskColor,
                      notes: [("\(f.unit) free / \(t.number) \(t.unit)", textDim),
                              ("R " + rate(s.diskRead) + "  W " + rate(s.diskWrite), diskColor)])
        case .clock:
            drawClock(ctx, r, now)
        case .network:
            drawNetwork(ctx, r, s)
        case .topCPU:
            drawAppList(ctx, r, title: "TOP CPU", rows: s.topCPU.map { ($0.app, ProcessUsage.cpuText($0.value)) },
                        color: cpuColor)
        case .topMemory:
            drawAppList(ctx, r, title: "TOP MEMORY",
                        rows: s.topMemory.map { ($0.app, ProcessUsage.memoryText($0.value)) }, color: memColor)
        case .claude:
            drawClaude(ctx, r, claude, now: now)
        case .calendar:
            drawAgendaSection(ctx, r, ("CALENDAR", agenda?.events ?? [],
                                       agenda?.events == nil ? "Loading\u{2026}" : agenda?.eventsNote, "No more events"))
        case .reminders:
            drawAgendaSection(ctx, r, ("REMINDERS", agenda?.reminders ?? [],
                                       agenda?.reminders == nil ? "Loading\u{2026}" : agenda?.remindersNote, "All done"))
        case .photo:
            break
        }
    }

    /// Half-card: title + badge (temperature or %), big number with up to two
    /// small note lines on its right (each dropped if it doesn't fit), and a bar.
    private func drawGauge(_ ctx: CGContext, _ r: CGRect, title: String, badge: (String, CGColor),
                           value: Double?, number: String, color: CGColor, notes: [(String, CGColor)]) {
        let p: CGFloat = 28
        let baseline = r.minY + 140
        text(ctx, title, x: r.minX + p, y: r.minY + p + 22, size: 28, color: textDim, bold: true)
        // Badge shrinks rather than run into the title on narrow cards.
        let titleW = textWidth(title, size: 28, bold: true)
        let badgeSize = fitSize(badge.0, 28, r.width - 2 * p - titleW - 14, bold: true)
        text(ctx, badge.0, x: r.maxX - p, y: r.minY + p + 22, size: badgeSize, color: badge.1, bold: true, align: .right)
        let numberWidth = bigNumber(ctx, number, x: r.minX + p, y: baseline, size: 84)
        let room = r.width - 2 * p - numberWidth - 16
        for (k, note) in notes.prefix(2).enumerated() {
            guard textWidth(note.0, size: 22, bold: false) <= room else { continue }
            // Last note sits on the number's baseline, the one before it above.
            let y = baseline - CGFloat(notes.prefix(2).count - 1 - k) * 30
            text(ctx, note.0, x: r.maxX - p, y: y, size: 22, color: note.1, align: .right)
        }
        if let value {
            bar(ctx, CGRect(x: r.minX + p, y: r.maxY - p - 18, width: r.width - 2 * p, height: 18),
                value: value, color: color)
        }
    }

    /// Time, date and lunar date, centred vertically in tall slots.
    private func drawClock(_ ctx: CGContext, _ r: CGRect, _ now: Date) {
        let p: CGFloat = 28
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US")
        df.dateFormat = "EEEE, yyyy-MM-dd"

        // Shrink to fit in case the card gets narrow.
        let hm = tf.string(from: now), day = df.string(from: now)
        let lunar = LunarCalendar.lunarDate(for: now).shortText
        let avail = r.width - 2 * p
        let top = r.minY + max(0, (r.height - 207) / 2) - 6
        text(ctx, hm, x: r.minX + p, y: top + 100,
             size: fitSize(hm, 88, avail, bold: true), color: textMain, bold: true)
        let small = min(fitSize(day, 26, avail, bold: false), fitSize(lunar, 26, avail, bold: false))
        text(ctx, day, x: r.minX + p, y: top + 142, size: small, color: textDim)
        text(ctx, lunar, x: r.minX + p, y: top + 176, size: small, color: lunarColor)
    }

    /// Download / upload rates, with the sound output in the header corner.
    private func drawNetwork(_ ctx: CGContext, _ r: CGRect, _ s: MiniDisplaySnapshot) {
        let p: CGFloat = 28
        let avail = r.width - 2 * p
        text(ctx, "NETWORK", x: r.minX + p, y: r.minY + p + 22, size: 28, color: textDim, bold: true)
        // Speaker + volume (or Muted) + device name.
        if let a = s.audio {
            let level = a.muted ? "Muted" : a.volume.map { "\(Int(($0 * 100).rounded()))%" } ?? ""
            let icon = a.muted || a.volume == 0 ? "\u{1F507}" : "\u{1F50A}"
            let short = [icon, level].filter { !$0.isEmpty }.joined(separator: " ")
            let full = short + " " + a.name
            let room = avail - textWidth("NETWORK", size: 28, bold: true) - 16
            // Device name only if it fits whole; a cut-off name ("Ma…") says nothing.
            // Then volume without the name, then the speaker alone — never a cut-off "4…".
            let label = [full, short, icon].first { textWidth($0, size: 22, bold: false) <= room } ?? ""
            text(ctx, label, x: r.maxX - p,
                 y: r.minY + p + 20, size: 22, color: a.muted ? critColor : textDim, align: .right)
        }
        let down = "\u{2193} " + rate(s.netRx), up = "\u{2191} " + rate(s.netTx)
        let rateSize = min(fitSize(down, 40, avail, bold: true), fitSize(up, 40, avail, bold: true))
        let mid = r.minY + 50 + (r.height - 50) / 2
        text(ctx, down, x: r.minX + p, y: mid - 4, size: rateSize, color: netColor, bold: true)
        text(ctx, up, x: r.minX + p, y: mid + 50, size: rateSize, color: netColor, bold: true)
    }

    private func drawAppList(_ ctx: CGContext, _ r: CGRect, title: String, rows: [(String, String)], color: CGColor) {
        let p: CGFloat = 28
        text(ctx, title, x: r.minX + p, y: r.minY + p + 22, size: 28, color: textDim, bold: true)
        guard !rows.isEmpty else {
            text(ctx, "Measuring\u{2026}", x: r.minX + p, y: r.minY + p + 22 + 46, size: 24, color: textDim)
            return
        }
        let lineH: CGFloat = 38
        for (i, row) in rows.prefix(3).enumerated() {
            let y = r.minY + p + 22 + 46 + CGFloat(i) * lineH
            let valueW = text(ctx, row.1, x: r.maxX - p, y: y, size: 24, color: color, bold: true, align: .right)
            text(ctx, truncated(row.0, size: 24, width: r.width - 2 * p - valueW - 14, bold: false),
                 x: r.minX + p, y: y, size: 24, color: textMain)
        }
    }

    private func thermalColor(_ t: ThermalLevel) -> CGColor {
        switch t {
        case .nominal: return goodColor
        case .fair: return warnColor
        case .serious: return warnColor
        case .critical: return critColor
        }
    }

    /// Claude plan usage of the signed-in account — the same numbers as Claude
    /// Code's usage panel. One slot: Session (5hr) and Weekly (7 day) as two
    /// rows with thin bars; a full-height slot gets two big gauges instead.
    private func drawClaude(_ ctx: CGContext, _ r: CGRect, _ c: ClaudeLimitsMonitor.Snapshot?, now: Date) {
        let p: CGFloat = 28
        func color(_ w: ClaudeLimits.Window) -> CGColor {
            w.percent >= 90 ? critColor : (w.percent >= 70 ? warnColor : claudeColor)
        }
        guard let account = c?.current else {
            text(ctx, "CLAUDE", x: r.minX + p, y: r.minY + p + 22, size: 28, color: textDim, bold: true)
            text(ctx, truncated(c?.note ?? "Loading\u{2026}", size: 24, width: r.width - 2 * p, bold: false),
                 x: r.minX + p, y: r.minY + p + 22 + 46, size: 24, color: textDim)
            return
        }
        // Which account (you rotate several): the part of the email before "@".
        let who = account.email.map { String($0.split(separator: "@").first ?? "") } ?? ""
        let stale = c?.note != nil ? " \u{26A0}\u{FE0E}" : ""
        let windows: [(String, ClaudeLimits.Window?)] = [("SESSION", account.usage.session),
                                                        ("WEEKLY", account.usage.weekly)]
        if r.height > 300 {
            let (top, bottom) = splitCard(ctx, r)
            for (k, (title, w)) in windows.enumerated() {
                guard let w else { continue }
                drawGauge(ctx, k == 0 ? top : bottom, title: title,
                          badge: (k == 0 ? who + stale : account.plan ?? "", textDim), value: w.percent / 100,
                          number: ClaudeLimits.percentText(w), color: color(w),
                          notes: [(ClaudeLimits.resetText(w.resetsAt, now: now, compact: true), textDim)])
            }
            return
        }
        text(ctx, "CLAUDE", x: r.minX + p, y: r.minY + p + 22, size: 28, color: textDim, bold: true)
        let badge = [who + stale, account.plan ?? ""].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        let room = r.width - 2 * p - textWidth("CLAUDE", size: 28, bold: true) - 14
        text(ctx, truncated(badge, size: 22, width: room, bold: false), x: r.maxX - p, y: r.minY + p + 20,
             size: 22, color: textDim, align: .right)
        let rowH = (r.maxY - p - (r.minY + p + 34)) / 2
        for (k, (title, w)) in windows.enumerated() {
            let y = r.minY + p + 34 + CGFloat(k) * rowH + rowH - 22   // text baseline; the bar sits below it
            text(ctx, title, x: r.minX + p, y: y, size: 22, color: textDim, bold: true)
            guard let w else {
                text(ctx, "--", x: r.maxX - p, y: y, size: 30, color: textDim, bold: true, align: .right)
                continue
            }
            let pctW = text(ctx, ClaudeLimits.percentText(w), x: r.maxX - p, y: y + 2, size: 34,
                            color: color(w), bold: true, align: .right)
            let reset = ClaudeLimits.resetText(w.resetsAt, now: now, compact: true)
            let titleW = textWidth(title, size: 22, bold: true)
            let resetRoom = r.width - 2 * p - titleW - pctW - 28
            if textWidth(reset, size: 20, bold: false) <= resetRoom {
                text(ctx, reset, x: r.maxX - p - pctW - 14, y: y, size: 20, color: textDim, align: .right)
            }
            bar(ctx, CGRect(x: r.minX + p, y: y + 10, width: r.width - 2 * p, height: 10),
                value: w.percent / 100, color: color(w))
        }
    }

    private func drawAgendaSection(_ ctx: CGContext, _ r: CGRect,
                                   _ section: (title: String, items: [MiniDisplayAgendaItem], note: String?, empty: String)) {
        let p: CGFloat = 28
        let lineH: CGFloat = 36
        text(ctx, section.title, x: r.minX + p, y: r.minY + p + 22, size: 28, color: textDim, bold: true)
        if !section.items.isEmpty {
            text(ctx, "\(section.items.count)", x: r.maxX - p, y: r.minY + p + 22, size: 28,
                 color: textDim, bold: true, align: .right)
        }
        let firstY = r.minY + p + 22 + 46
        let capacity = max(1, Int((r.maxY - p + 8 - firstY) / lineH) + 1)
        if let note = section.note ?? (section.items.isEmpty ? section.empty : nil) {
            text(ctx, note, x: r.minX + p, y: firstY, size: 24, color: textDim)
            return
        }
        // Label column as wide as the widest label shown (e.g. "Tmrw 19:30").
        let labelW = min(150, max(80, section.items.prefix(capacity)
            .map { textWidth($0.label, size: 22, bold: false) }.max() ?? 0) + 14)
        for (i, item) in section.items.prefix(capacity).enumerated() {
            let y = firstY + CGFloat(i) * lineH
            // Calendar / list colour dot, time label, then the title cut to fit.
            ctx.setFillColor(item.color)
            ctx.fillEllipse(in: CGRect(x: r.minX + p, y: y - 15, width: 12, height: 12))
            let label = truncated(item.label, size: 22, width: labelW - 8, bold: false)
            text(ctx, label, x: r.minX + p + 22, y: y, size: 22,
                 color: item.isAlert ? critColor : textDim)
            let tx = r.minX + p + 22 + labelW
            text(ctx, truncated(item.title, size: 24, width: r.maxX - p - tx, bold: false),
                 x: tx, y: y, size: 24, color: textMain)
        }
    }

    /// `s` cut with an ellipsis so it fits in `width`.
    private func truncated(_ s: String, size: CGFloat, width: CGFloat, bold: Bool) -> String {
        guard textWidth(s, size: size, bold: bold) > width else { return s }
        var chars = Array(s)
        while !chars.isEmpty && textWidth(String(chars) + "\u{2026}", size: size, bold: bold) > width {
            chars.removeLast()
        }
        return String(chars).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// Photo card: the photo scaled to fill the card (centre-cropped), clipped
    /// to its corners; during a change the new photo fades in over the old one.
    private func drawPhoto(_ ctx: CGContext, _ r: CGRect, _ frame: MiniDisplayPhotoFrame?) {
        let path = CGPath(roundedRect: r, cornerWidth: 22, cornerHeight: 22, transform: nil)
        if let image = frame?.image {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            if let previous = frame?.previous {
                fill(ctx, r, with: previous)
                // Ease in-out so the fade starts and ends softly.
                let t = frame?.progress ?? 1
                ctx.setAlpha(CGFloat(t * t * (3 - 2 * t)))
            }
            fill(ctx, r, with: image)
            ctx.restoreGState()
        } else {
            drawCard(ctx, r)
            text(ctx, "PHOTOS", x: r.minX + 28, y: r.minY + 58, size: 30, color: textDim, bold: true)
            text(ctx, "Loading\u{2026}", x: r.minX + 28, y: r.midY + 10, size: 26, color: textDim)
        }
        ctx.addPath(path)
        ctx.setStrokeColor(cardStroke)
        ctx.setLineWidth(2)
        ctx.strokePath()
    }

    /// Draws `image` aspect-filling `r` (centre crop) in the flipped layout context.
    private func fill(_ ctx: CGContext, _ r: CGRect, with image: CGImage) {
        guard image.width > 0, image.height > 0 else { return }
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        var w = r.width, h = w / aspect
        if h < r.height { h = r.height; w = h * aspect }
        let dst = CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
        ctx.saveGState()
        // The context is flipped for top-down layout; flip the image back.
        ctx.translateBy(x: 0, y: dst.minY + dst.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: dst)
        ctx.restoreGState()
    }

    // MARK: Helpers

    private func pct(_ v: Double) -> String { MiniDisplayFormat.percent(v) }
    private func temp(_ t: Double?) -> String { MiniDisplayFormat.temperature(t) }
    private func rate(_ bps: Double) -> String { MiniDisplayFormat.rate(bps) }

    private func roundRect(_ ctx: CGContext, _ r: CGRect, radius: CGFloat, color: CGColor) {
        let rad = min(radius, r.width / 2, r.height / 2)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    private func bar(_ ctx: CGContext, _ r: CGRect, value: Double, color: CGColor) {
        roundRect(ctx, r, radius: r.height / 2, color: track)
        let w = max(r.height, r.width * CGFloat(min(1, max(0, value))))
        roundRect(ctx, CGRect(x: r.minX, y: r.minY, width: w, height: r.height), radius: r.height / 2, color: color)
    }

    /// Big number: integer part large, ".x%" tail half size on the same baseline.
    /// Returns the total width drawn.
    @discardableResult
    private func bigNumber(_ ctx: CGContext, _ s: String, x: CGFloat, y: CGFloat, size: CGFloat = 104) -> CGFloat {
        let parts = s.split(separator: ".", maxSplits: 1)
        let head = String(parts.first ?? "")
        var w = text(ctx, head, x: x, y: y, size: size, color: textMain, bold: true)
        if parts.count > 1 {
            w += 2 + text(ctx, "." + parts[1], x: x + w + 2, y: y, size: size / 2, color: textMain, bold: true)
        }
        return w
    }

    enum Align { case left, center, right }

    private func font(_ size: CGFloat, bold: Bool) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private func textWidth(_ s: String, size: CGFloat, bold: Bool) -> CGFloat {
        let attrs = [NSAttributedString.Key(kCTFontAttributeName as String): font(size, bold: bold)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Largest size up to `size` at which `s` fits in `width`.
    private func fitSize(_ s: String, _ size: CGFloat, _ width: CGFloat, bold: Bool) -> CGFloat {
        let w = textWidth(s, size: size, bold: bold)
        return w <= width ? size : floor(size * width / w)
    }

    /// Draws text with its baseline at y and returns the line width.
    @discardableResult
    private func text(_ ctx: CGContext, _ s: String, x: CGFloat, y: CGFloat, size: CGFloat,
                      color: CGColor, bold: Bool = false, align: Align = .left) -> CGFloat {
        let font = font(size, bold: bold)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textPosition = CGPoint(x: align == .right ? x - w : (align == .center ? x - w / 2 : x), y: y)
        CTLineDraw(line, ctx)
        return w
    }
}

/// Encodes baseline JPEGs that fit the panel's byte limit.
enum MiniDisplayJPEG {
    static func encode(_ image: CGImage, maxBytes: Int) -> Data? {
        var q: CGFloat = 0.85
        return encode(image, maxBytes: maxBytes, quality: &q)
    }

    /// Adaptive variant for streaming: starts at `quality` (the value that worked
    /// last frame), steps down until the frame fits, and nudges it back up when
    /// there is plenty of headroom, so most frames need a single encode.
    static func encode(_ image: CGImage, maxBytes: Int, quality: inout CGFloat) -> Data? {
        var q = min(0.85, max(0.3, quality))
        while q >= 0.3 {
            if let d = encode(image, quality: q), d.count <= maxBytes {
                quality = d.count < maxBytes * 7 / 10 ? min(0.85, q + 0.05) : q
                return d
            }
            q -= 0.05
        }
        quality = 0.3
        return encode(image, quality: 0.25)
    }

    static func encode(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: false],
        ]
        CGImageDestinationAddImage(dst, image, opts as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return data as Data
    }

    static func describe(_ d: Data) -> String {
        MiniDisplayProtocol.isBaseline420([UInt8](d)) ? "baseline 4:2:0 OK" : "NOT baseline 4:2:0 - panel will draw it wrong"
    }
}
