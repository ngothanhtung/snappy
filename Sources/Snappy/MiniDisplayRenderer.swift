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

    private func heat(_ t: Double?) -> CGColor {
        guard let t else { return textDim }
        if t >= 85 { return Self.rgb(0xFF5252) }
        if t >= 70 { return Self.rgb(0xFFAB40) }
        return Self.rgb(0x69F0AE)
    }

    // MARK: Drawing

    func render(_ s: MiniDisplaySnapshot, now: Date = Date()) -> CGImage? {
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

        // Cards sized by weight with 16 px gutters.
        let m: CGFloat = 16
        let weights: [CGFloat] = [480, 345, 345, 360, 400]
        let usable = W - m * CGFloat(weights.count + 1)
        let total = weights.reduce(0, +)
        var x = m
        var rects: [CGRect] = []
        for w in weights {
            let cw = usable * w / total
            rects.append(CGRect(x: x, y: m, width: cw, height: H - 2 * m))
            x += cw + m
        }
        for r in rects { drawCard(ctx, r) }

        drawCPU(ctx, rects[0], s)
        drawGPU(ctx, rects[1], s)
        drawMemory(ctx, rects[2], s)
        drawDisk(ctx, rects[3], s)
        drawClock(ctx, rects[4], s, now)

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

    private func drawCPU(_ ctx: CGContext, _ r: CGRect, _ s: MiniDisplaySnapshot) {
        let p: CGFloat = 28
        text(ctx, "CPU", x: r.minX + p, y: r.minY + p + 30, size: 30, color: textDim, bold: true)
        text(ctx, temp(s.cpuTemp), x: r.maxX - p, y: r.minY + p + 30, size: 30,
             color: heat(s.cpuTemp), bold: true, align: .right)
        bigNumber(ctx, pct(s.cpuTotal), x: r.minX + p, y: r.minY + 175)

        // One bar per core
        let cores = s.cpuCores.isEmpty ? [s.cpuTotal] : s.cpuCores
        let area = CGRect(x: r.minX + p, y: r.minY + 230, width: r.width - 2 * p, height: r.height - 230 - p)
        let gap: CGFloat = 10
        let bw = (area.width - gap * CGFloat(cores.count - 1)) / CGFloat(cores.count)
        for (i, v) in cores.enumerated() {
            let bx = area.minX + CGFloat(i) * (bw + gap)
            let col = CGRect(x: bx, y: area.minY, width: bw, height: area.height)
            roundRect(ctx, col, radius: 6, color: track)
            let h = max(6, area.height * CGFloat(min(1, max(0, v))))
            roundRect(ctx, CGRect(x: bx, y: area.maxY - h, width: bw, height: h), radius: 6, color: cpuColor)
        }
    }

    private func drawGPU(_ ctx: CGContext, _ r: CGRect, _ s: MiniDisplaySnapshot) {
        let p: CGFloat = 28
        text(ctx, "GPU", x: r.minX + p, y: r.minY + p + 30, size: 30, color: textDim, bold: true)
        text(ctx, temp(s.gpuTemp), x: r.maxX - p, y: r.minY + p + 30, size: 30,
             color: heat(s.gpuTemp), bold: true, align: .right)
        bigNumber(ctx, s.gpu.map(pct) ?? "--", x: r.minX + p, y: r.minY + 175)
        bar(ctx, CGRect(x: r.minX + p, y: r.maxY - p - 40, width: r.width - 2 * p, height: 40),
            value: s.gpu ?? 0, color: gpuColor)
        text(ctx, "SoC max " + temp(s.socTemp), x: r.minX + p, y: r.maxY - p - 64, size: 28,
             color: heat(s.socTemp))
    }

    private func drawMemory(_ ctx: CGContext, _ r: CGRect, _ s: MiniDisplaySnapshot) {
        let p: CGFloat = 28
        let gb = 1024.0 * 1024 * 1024
        let used = Double(s.memUsed) / gb, total = Double(s.memTotal) / gb
        let frac = total > 0 ? used / total : 0
        text(ctx, "RAM", x: r.minX + p, y: r.minY + p + 30, size: 30, color: textDim, bold: true)
        text(ctx, pct(frac), x: r.maxX - p, y: r.minY + p + 30, size: 30, color: memColor, bold: true, align: .right)
        bigNumber(ctx, String(format: "%.1f", used), x: r.minX + p, y: r.minY + 175)
        text(ctx, String(format: "/ %.1f GB", total), x: r.minX + p, y: r.minY + 225, size: 32, color: textDim)
        bar(ctx, CGRect(x: r.minX + p, y: r.maxY - p - 40, width: r.width - 2 * p, height: 40),
            value: frac, color: memColor)
    }

    private func drawDisk(_ ctx: CGContext, _ r: CGRect, _ s: MiniDisplaySnapshot) {
        let p: CGFloat = 28
        let total = Double(s.diskTotal), free = Double(s.diskFree)
        let usedFrac = total > 0 ? (total - free) / total : 0
        text(ctx, "Storage", x: r.minX + p, y: r.minY + p + 30, size: 30, color: textDim, bold: true)
        text(ctx, temp(s.diskTemp), x: r.maxX - p, y: r.minY + p + 30, size: 30,
             color: heat(s.diskTemp), bold: true, align: .right)
        let f = MiniDisplayFormat.size(free), t = MiniDisplayFormat.size(total)
        bigNumber(ctx, f.number, x: r.minX + p, y: r.minY + 175)
        text(ctx, "\(f.unit) free / \(t.number) \(t.unit)", x: r.minX + p,
             y: r.minY + 222, size: 28, color: textDim)
        text(ctx, "Read  " + rate(s.diskRead), x: r.minX + p, y: r.maxY - p - 104, size: 28, color: diskColor, bold: true)
        text(ctx, "Write " + rate(s.diskWrite), x: r.minX + p, y: r.maxY - p - 64, size: 28, color: diskColor, bold: true)
        bar(ctx, CGRect(x: r.minX + p, y: r.maxY - p - 40, width: r.width - 2 * p, height: 40),
            value: usedFrac, color: diskColor)
    }

    private func drawClock(_ ctx: CGContext, _ r: CGRect, _ s: MiniDisplaySnapshot, _ now: Date) {
        let p: CGFloat = 28
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US")
        df.dateFormat = "EEEE, dd/MM/yyyy"

        let hm = tf.string(from: now)
        text(ctx, hm, x: r.minX + p, y: r.minY + 165, size: 120, color: textMain, bold: true)
        text(ctx, df.string(from: now), x: r.minX + p, y: r.minY + 225, size: 32, color: textDim)

        text(ctx, "↓ " + rate(s.netRx), x: r.minX + p, y: r.maxY - p - 60, size: 40, color: netColor, bold: true)
        text(ctx, "↑ " + rate(s.netTx), x: r.minX + p, y: r.maxY - p - 8, size: 40, color: netColor, bold: true)
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

    /// Big number: integer part large, ".x%" tail smaller on the same baseline.
    private func bigNumber(_ ctx: CGContext, _ s: String, x: CGFloat, y: CGFloat) {
        let parts = s.split(separator: ".", maxSplits: 1)
        let head = String(parts.first ?? "")
        let w = text(ctx, head, x: x, y: y, size: 104, color: textMain, bold: true)
        if parts.count > 1 {
            text(ctx, "." + parts[1], x: x + w + 2, y: y, size: 52, color: textMain, bold: true)
        }
    }

    enum Align { case left, right }

    /// Draws text with its baseline at y and returns the line width.
    @discardableResult
    private func text(_ ctx: CGContext, _ s: String, x: CGFloat, y: CGFloat, size: CGFloat,
                      color: CGColor, bold: Bool = false, align: Align = .left) -> CGFloat {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
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
        while q >= 0.3 {
            if let d = encode(image, quality: q), d.count <= maxBytes { return d }
            q -= 0.05
        }
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
