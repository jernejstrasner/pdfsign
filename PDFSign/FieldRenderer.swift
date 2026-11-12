import AppKit

/// Draws field content exactly the way the signing engine lays it out, so the on-screen
/// preview and agent renders match the signed output. All drawing happens in a flipped
/// (y-down) AppKit context whose origin is the field's top-left corner.
enum FieldRenderer {
    static func draw(_ field: PlacedField, appearance: StampAppearance, size: CGSize, date: Date = Date()) {
        switch field.kind {
        case .signature: drawStamp(appearance: appearance, size: size, date: date)
        case .date, .text: drawText(field.displayText(at: date) ?? "", size: size)
        }
    }

    // Helvetica to match the engine's PDF standard-14 fonts — SF Pro can't be embedded
    // in the output (Apple's license allows mock-ups only), so the preview conforms to
    // the engine, not the other way around. (Arial, the engine's non-Latin-1 fallback,
    // is metric-compatible.)
    private static func helvetica(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size)
            ?? (bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
    }

    private static func width(of s: String, font: NSFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    private static let stampDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }()

    /// Single-line text; mirrors MakeTextXObject in the engine.
    static func drawText(_ text: String, size: CGSize) {
        let w = size.width, h = size.height
        guard !text.isEmpty else { return }
        let pad = min(2, w * 0.05)
        var fs = max(3, h * 0.62)
        let tw = width(of: text, font: helvetica(fs))
        if tw > w - 2 * pad, tw > 0 { fs = max(3, fs * (w - 2 * pad) / tw) }
        let font = helvetica(fs)
        // Engine baseline sits (h - capHeight)/2 above the bottom; draw(at:) in a flipped
        // context positions the line's top, which is `ascender` above the baseline.
        let baselineFromTop = h - (h - fs * 0.72) / 2
        (text as NSString).draw(at: NSPoint(x: pad, y: baselineFromTop - font.ascender),
                                withAttributes: [.font: font,
                                                 .foregroundColor: NSColor(white: 0.08, alpha: 1)])
    }

    /// Signature stamp; mirrors MakeStampXObject in the engine.
    static func drawStamp(appearance: StampAppearance, size: CGSize, date: Date = Date()) {
        let w = size.width, h = size.height
        let pad: CGFloat = 6

        // Subtle rounded border, matching the engine.
        NSColor(white: 0.75, alpha: 1).setStroke()
        let border = NSBezierPath(roundedRect: CGRect(x: 0.6, y: 0.6,
                                                      width: max(1, w - 1.2), height: max(1, h - 1.2)),
                                  xRadius: 4, yRadius: 4)
        border.lineWidth = 0.8
        border.stroke()

        // Wide box: graphic left, text right. Tall box: graphic top, text below,
        // centered. Fonts shrink to fit the available width.
        let name = appearance.name.map { "Signed by \($0)" } ?? "Digitally signed"
        var subs: [String] = []
        if appearance.showDate { subs.append(stampDateFormatter.string(from: date) + " UTC") }
        if let text = appearance.customText, !text.isEmpty { subs.append(text) }

        let sigImage = appearance.image.flatMap { $0.size.width > 0 && $0.size.height > 0 ? $0 : nil }
        let sigAspect = sigImage.map { $0.size.width / $0.size.height } ?? 1

        let horizontal = w >= h * 1.5
        var fs1 = min(max(h * 0.20, 5), 11)
        var fs2 = min(max(h * 0.165, 4.5), 9)
        var imgX = pad, imgY: CGFloat = 0, imgW: CGFloat = 0, imgH: CGFloat = 0
        var tx = pad, availW = w - 2 * pad
        var textRegionTop: CGFloat = 0, textRegionH = h

        if horizontal {
            if sigImage != nil {
                imgH = max(8, h - 2 * pad)
                imgW = imgH * sigAspect
                let maxW = max(8, w * 0.45)
                if imgW > maxW { imgW = maxW; imgH = imgW / sigAspect }
            } else {
                imgH = min(max(h - 2 * pad, 16), 40)  // badge slot
                imgW = imgH
            }
            imgY = (h - imgH) / 2
            tx = pad + imgW + pad
            availW = w - tx - pad
        } else {
            imgH = sigImage != nil
                ? min(h * 0.45, (w - 2 * pad) / sigAspect)
                : min(max(min(h * 0.45, w - 2 * pad), 12), 40)
            imgW = sigImage != nil ? imgH * sigAspect : imgH
            imgX = (w - imgW) / 2
            imgY = pad
            textRegionTop = imgY + imgH + pad
            textRegionH = max(0, h - pad - textRegionTop)
            fs1 = min(max(textRegionH * 0.34, 5), 11)
            fs2 = min(max(fs1 * 0.82, 4.5), 9)
        }

        var boldFont = helvetica(fs1, bold: true), regFont = helvetica(fs2)
        var maxLineW = width(of: name, font: boldFont)
        for s in subs { maxLineW = max(maxLineW, width(of: s, font: regFont)) }
        if maxLineW > availW, maxLineW > 0 {
            let scale = availW / maxLineW
            fs1 = max(3, fs1 * scale)  // past ~3pt it clips at the border
            fs2 = max(3, fs2 * scale)
            boldFont = helvetica(fs1, bold: true)
            regFont = helvetica(fs2)
        }

        // Graphic: signature image, else the seal badge.
        if let image = sigImage {
            image.draw(in: CGRect(x: imgX, y: imgY, width: imgW, height: imgH),
                       from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else if let base = NSImage(systemSymbolName: "checkmark.seal.fill", accessibilityDescription: nil),
                  let icon = base.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: imgH * 0.9, weight: .semibold)
                        .applying(NSImage.SymbolConfiguration(
                            hierarchicalColor: NSColor(red: 0.20, green: 0.65, blue: 0.33, alpha: 1)))) {
            let s = icon.size
            let scale = min(imgH / s.width, imgH / s.height, 1)
            icon.draw(in: CGRect(x: imgX + (imgH - s.width * scale) / 2,
                                 y: imgY + (imgH - s.height * scale) / 2,
                                 width: s.width * scale, height: s.height * scale),
                      from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }

        // Text block, centered in its region.
        let lh1 = fs1 * 1.3, lh2 = fs2 * 1.25
        let blockH = lh1 + CGFloat(subs.count) * lh2
        var y = textRegionTop + (textRegionH - blockH) / 2

        name.draw(at: NSPoint(x: horizontal ? tx : (w - width(of: name, font: boldFont)) / 2, y: y),
                  withAttributes: [.font: boldFont, .foregroundColor: NSColor(white: 0.10, alpha: 1)])
        y += lh1
        for line in subs {
            line.draw(at: NSPoint(x: horizontal ? tx : (w - width(of: line, font: regFont)) / 2, y: y),
                      withAttributes: [.font: regFont, .foregroundColor: NSColor(white: 0.37, alpha: 1)])
            y += lh2
        }
    }

    /// Run `body` in a flipped (y-down) AppKit context whose origin is the top-left of
    /// `rect` *as displayed*: `context` is in page space and `display` is the page's
    /// page→display transform, so content reads upright on /Rotate pages just like the
    /// engine's output. `body` gets the displayed size.
    static func withFieldContext(_ context: CGContext, rect: CGRect, display: CGAffineTransform,
                                 _ body: (CGSize) -> Void) {
        let shown = rect.applying(display)
        context.saveGState()
        context.concatenate(display.inverted())
        context.translateBy(x: shown.minX, y: shown.maxY)
        context.scaleBy(x: 1, y: -1)
        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        // Never let content spill outside the box.
        NSBezierPath(rect: CGRect(origin: .zero, size: shown.size)).addClip()
        body(shown.size)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
}
