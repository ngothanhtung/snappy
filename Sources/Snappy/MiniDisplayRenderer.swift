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
    }

    // MARK: Colors

    private static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    private let bgTop = rgb(0x0B1020)
    private let bgBottom = rgb(0x151C33)
    private let card = rgb(0xFFFFFF, 0.05)
    private let cardStroke = rgb(0xFFFFFF, 0.08)
    private let track = rgb(0xFFFFFF, 0.10)
    private let textMain = rgb(0xF2F4F8)
    private let textDim = rgb(0x8A93A8)
    private let cpuColor = rgb(0x4FC3F7)
    private let gpuColor = rgb(0xB388FF)
    private let memColor = rgb(0x69F0AE)
    private let netColor = rgb(0xFFD54F)
    private let diskColor = rgb(0xFF8A65)
    private let lunarColor = rgb(0xF48FB1)

    private func heat(_ t: Double?) -> CGColor {
        guard let t else { return textDim }
        if t >= 85 { return Self.rgb(0xFF5252) }
        if t >= 70 { return Self.rgb(0xFFAB40) }
        return Self.rgb(0x69F0AE)
    }

    // MARK: Drawing

    /// - Parameters:
    ///   - photoPanel: reserve a full-height photo card (shape from `photo.aspect`) at the right edge.
    ///   - photo: what to show there (current photo, and the previous one mid-crossfade).
    func render(_ s: MiniDisplaySnapshot, now: Date = Date(),
                photoPanel: Bool = false, photo: MiniDisplayPhotoFrame? = nil) -> CGImage? {
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

        // Cards sized by weight with 16 px gutters. With a photo panel the
        // photo card (full card height, chosen aspect) sits at the right and the dashboard gets the rest.
        let m: CGFloat = 16
        let weights: [CGFloat] = [420, 420, 400]  // CPU+GPU, RAM+Storage, Clock
        let photoH = H - 2 * m, photoW = (photoH * (photo?.aspect ?? 4 / 3)).rounded()
        let photoRect = CGRect(x: W - m - photoW, y: m, width: photoW, height: photoH)
        let dashW = photoPanel ? photoRect.minX : W
        let usable = dashW - m * CGFloat(weights.count + 1)
        let total = weights.reduce(0, +)
        var x = m
        var rects: [CGRect] = []
        for w in weights {
            let cw = usable * w / total
            rects.append(CGRect(x: x, y: m, width: cw, height: H - 2 * m))
            x += cw + m
        }
        for r in rects { drawCard(ctx, r) }

        drawProcessors(ctx, rects[0], s)
        drawStorage(ctx, rects[1], s)
        drawClock(ctx, rects[2], s, now)
        if photoPanel { drawPhoto(ctx, photoRect, photo) }

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

    /// CPU on top, GPU below.
    private func drawProcessors(_ ctx: CGContext, _ r: CGRect, _ s: MiniDisplaySnapshot) {
        let (top, bottom) = splitCard(ctx, r)
        drawGauge(ctx, top, title: "CPU", badge: (temp(s.cpuTemp), heat(s.cpuTemp)),
                  value: s.cpuTotal, number: pct(s.cpuTotal), color: cpuColor, notes: [])
        drawGauge(ctx, bottom, title: "GPU", badge: (temp(s.gpuTemp), heat(s.gpuTemp)),
                  value: s.gpu ?? 0, number: s.gpu.map(pct) ?? "--", color: gpuColor,
                  notes: [("SoC " + temp(s.socTemp), heat(s.socTemp))])
    }

    /// RAM on top, storage below.
    private func drawStorage(_ ctx: CGContext, _ r: CGRect, _ s: MiniDisplaySnapshot) {
        let (top, bottom) = splitCard(ctx, r)
        let gb = 1024.0 * 1024 * 1024
        let used = Double(s.memUsed) / gb, memTotal = Double(s.memTotal) / gb
        let memFrac = memTotal > 0 ? used / memTotal : 0
        drawGauge(ctx, top, title: "RAM", badge: (pct(memFrac), memColor),
                  value: memFrac, number: String(format: "%.1f", used), color: memColor,
                  notes: [(String(format: "/ %.1f GB", memTotal), textDim)])

        let total = Double(s.diskTotal), free = Double(s.diskFree)
        let usedFrac = total > 0 ? (total - free) / total : 0
        let f = MiniDisplayFormat.size(free), t = MiniDisplayFormat.size(total)
        drawGauge(ctx, bottom, title: "STORAGE", badge: (temp(s.diskTemp), heat(s.diskTemp)),
                  value: usedFrac, number: f.number, color: diskColor,
                  notes: [("\(f.unit) free / \(t.number) \(t.unit)", textDim),
                          ("R " + rate(s.diskRead) + "  W " + rate(s.diskWrite), diskColor)])
    }

    /// Half-card: title + badge (temperature or %), big number with up to two
    /// small note lines on its right (each dropped if it doesn't fit), and a bar.
    private func drawGauge(_ ctx: CGContext, _ r: CGRect, title: String, badge: (String, CGColor),
                           value: Double, number: String, color: CGColor, notes: [(String, CGColor)]) {
        let p: CGFloat = 28
        let baseline = r.minY + 140
        text(ctx, title, x: r.minX + p, y: r.minY + p + 22, size: 28, color: textDim, bold: true)
        text(ctx, badge.0, x: r.maxX - p, y: r.minY + p + 22, size: 28, color: badge.1, bold: true, align: .right)
        let numberWidth = bigNumber(ctx, number, x: r.minX + p, y: baseline, size: 84)
        let room = r.width - 2 * p - numberWidth - 16
        for (k, note) in notes.prefix(2).enumerated() {
            guard textWidth(note.0, size: 22, bold: false) <= room else { continue }
            // Last note sits on the number's baseline, the one before it above.
            let y = baseline - CGFloat(notes.prefix(2).count - 1 - k) * 30
            text(ctx, note.0, x: r.maxX - p, y: y, size: 22, color: note.1, align: .right)
        }
        bar(ctx, CGRect(x: r.minX + p, y: r.maxY - p - 18, width: r.width - 2 * p, height: 18),
            value: value, color: color)
    }

    /// Clock on top, network below.
    private func drawClock(_ ctx: CGContext, _ r: CGRect, _ s: MiniDisplaySnapshot, _ now: Date) {
        let p: CGFloat = 28
        let (top, bottom) = splitCard(ctx, r)
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US")
        df.dateFormat = "EEEE, yyyy-MM-dd"

        // Shrink to fit in case the card gets narrow.
        let hm = tf.string(from: now), day = df.string(from: now)
        let lunar = "Âm lịch " + LunarCalendar.lunarDate(for: now).shortText
        let avail = top.width - 2 * p
        text(ctx, hm, x: top.minX + p, y: top.minY + 100,
             size: fitSize(hm, 88, avail, bold: true), color: textMain, bold: true)
        let small = min(fitSize(day, 26, avail, bold: false), fitSize(lunar, 26, avail, bold: false))
        text(ctx, day, x: top.minX + p, y: top.minY + 142, size: small, color: textDim)
        text(ctx, lunar, x: top.minX + p, y: top.minY + 178, size: small, color: lunarColor)

        text(ctx, "NETWORK", x: bottom.minX + p, y: bottom.minY + p + 22, size: 28, color: textDim, bold: true)
        let down = "\u{2193} " + rate(s.netRx), up = "\u{2191} " + rate(s.netTx)
        let rateSize = min(fitSize(down, 40, avail, bold: true), fitSize(up, 40, avail, bold: true))
        text(ctx, down, x: bottom.minX + p, y: bottom.minY + 122, size: rateSize, color: netColor, bold: true)
        text(ctx, up, x: bottom.minX + p, y: bottom.maxY - p - 6, size: rateSize, color: netColor, bold: true)
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

    enum Align { case left, right }

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
        ctx.textPosition = CGPoint(x: align == .right ? x - w : x, y: y)
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
