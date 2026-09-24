import SwiftUI
import PDFKit

/// Transparent overlay on top of the PDF that captures the drag and draws the live
/// selection rectangle. When inactive it passes mouse events through (hitTest → nil)
/// so normal PDF scrolling/selection keeps working.
final class DrawOverlay: NSView {
    var active = false {
        didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) }
    }
    var onCommit: ((NSRect) -> Void)?
    var onUpdate: ((NSRect) -> Void)?   // live drag rect, once past the size threshold
    var onCancel: (() -> Void)?        // drag ended below the threshold
    /// Hide the dashed drag rect while the live stamp preview is standing in for it.
    var suppressDragRect = false {
        didSet { needsDisplay = true }
    }

    private var start: NSPoint?
    private var current: NSRect?

    override func hitTest(_ point: NSPoint) -> NSView? { active ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = start else { return }
        let p = convert(event.locationInWindow, from: nil)
        current = NSRect(x: min(s.x, p.x), y: min(s.y, p.y),
                         width: abs(p.x - s.x), height: abs(p.y - s.y))
        needsDisplay = true
        if let r = current, r.width > 6, r.height > 6 { onUpdate?(r) }
    }

    override func mouseUp(with event: NSEvent) {
        let rect = current
        start = nil
        current = nil
        needsDisplay = true
        if let rect, rect.width > 6, rect.height > 6 { onCommit?(rect) } else { onCancel?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard active, let r = current, !suppressDragRect else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        r.fill()
        let path = NSBezierPath(rect: r)
        path.lineWidth = 1.5
        path.setLineDash([6, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    override func resetCursorRects() {
        if active { addCursorRect(bounds, cursor: .crosshair) }
    }
}

/// The placement box rendered as the actual stamp: same layout the engine draws
/// (border, left graphic, text lines) so what you see is what gets signed.
final class StampAnnotation: PDFAnnotation {
    let appearance: StampAppearance
    /// Handle square size in screen points (converted to page units at draw time).
    var handleScreenSize: CGFloat = 7

    init(bounds: CGRect, appearance: StampAppearance) {
        self.appearance = appearance
        super.init(bounds: bounds, forType: .square, withProperties: nil)
        shouldPrint = true
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }()

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let b = bounds
        guard b.width > 4, b.height > 4 else { return }
        context.saveGState()
        // draw() is called in page space (y-up); flip into AppKit space within the bounds.
        context.translateBy(x: b.minX, y: b.minY + b.height)
        context.scaleBy(x: 1, y: -1)
        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        let w = b.width, h = b.height
        let pad: CGFloat = 6

        // Never let content spill outside the box.
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: w, height: h)).addClip()

        // Subtle rounded border, matching the engine.
        NSColor(white: 0.75, alpha: 1).setStroke()
        let border = NSBezierPath(roundedRect: CGRect(x: 0.6, y: 0.6,
                                                      width: max(1, w - 1.2), height: max(1, h - 1.2)),
                                  xRadius: 4, yRadius: 4)
        border.lineWidth = 0.8
        border.stroke()

        // --- Adaptive layout, mirroring the engine ---
        // Wide box: graphic left, text right. Tall box: graphic top, text below,
        // centered. Fonts shrink to fit the available width.
        let name = appearance.name.map { "Signed by \($0)" } ?? "Digitally signed"
        var subs: [String] = []
        if appearance.showDate {
            subs.append(Self.dateFormatter.string(from: Date()) + " UTC")
        }
        if let text = appearance.customText, !text.isEmpty { subs.append(text) }

        let sigImage = appearance.image.flatMap {
            $0.size.width > 0 && $0.size.height > 0 ? $0 : nil
        }
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

        // Helvetica to match the engine's PDF standard-14 fonts — SF Pro can't be
        // embedded in the output (Apple's license allows mock-ups only), so the
        // preview conforms to the engine, not the other way around.
        func fonts() -> (NSFont, NSFont) {
            (NSFont(name: "Helvetica-Bold", size: fs1) ?? NSFont.boldSystemFont(ofSize: fs1),
             NSFont(name: "Helvetica", size: fs2) ?? NSFont.systemFont(ofSize: fs2))
        }
        var (boldFont, regFont) = fonts()
        func width(of s: String, font: NSFont) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: font]).width
        }
        var maxLineW = width(of: name, font: boldFont)
        for s in subs { maxLineW = max(maxLineW, width(of: s, font: regFont)) }
        if maxLineW > availW, maxLineW > 0 {
            let scale = availW / maxLineW
            fs1 = max(3, fs1 * scale)  // past ~3pt it clips at the border
            fs2 = max(3, fs2 * scale)
            (boldFont, regFont) = fonts()
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
                  withAttributes: [.font: boldFont,
                                   .foregroundColor: NSColor(white: 0.10, alpha: 1)])
        y += lh1
        for line in subs {
            line.draw(at: NSPoint(x: horizontal ? tx : (w - width(of: line, font: regFont)) / 2, y: y),
                      withAttributes: [.font: regFont,
                                       .foregroundColor: NSColor(white: 0.37, alpha: 1)])
            y += lh2
        }

        // Selection handles — UI affordance only; this annotation is never saved
        // into the signed PDF (the engine re-stamps from the source file).
        // Constant screen size: convert through the CTM (page units → device px).
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let hs = handleScreenSize * backing / max(context.ctm.a, 0.01)
        let inset = hs / 2
        let centers: [CGPoint] = [  // flipped space: y-down, (0,0) = top-left
            CGPoint(x: inset, y: inset), CGPoint(x: w / 2, y: inset),
            CGPoint(x: w - inset, y: inset), CGPoint(x: w - inset, y: h / 2),
            CGPoint(x: w - inset, y: h - inset), CGPoint(x: w / 2, y: h - inset),
            CGPoint(x: inset, y: h - inset), CGPoint(x: inset, y: h / 2),
        ]
        for c in centers {
            let r = CGRect(x: c.x - inset, y: c.y - inset, width: hs, height: hs)
            NSColor.white.setFill()
            NSBezierPath(rect: r).fill()
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(rect: r)
            p.lineWidth = 1
            p.stroke()
        }

        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
}

/// PDFView that lets the user drag a rectangle to place the signature. The committed
/// box is shown as a stamp-preview annotation on the page so it scrolls/zooms with content.
final class SelectablePDFView: PDFView {
    var placing = false {
        didSet {
            overlay.active = placing
            if placing {
                addSubview(overlay, positioned: .above, relativeTo: nil)
                overlay.suppressDragRect = false
            }
            overlay.frame = bounds
            window?.invalidateCursorRects(for: overlay)
        }
    }
    var onSelect: ((SignatureBox) -> Void)?
    var stampAppearance = StampAppearance() {
        didSet {
            // Rebuild the preview in place when the stamp's look changes.
            guard stampAppearance != oldValue, let prev = previewAnnotation else { return }
            showPreview(on: prev.page, rect: prev.annotation.bounds)
        }
    }

    private let overlay = DrawOverlay()
    private var previewAnnotation: (page: PDFPage, annotation: StampAnnotation)?
    private var lastCommitted: SignatureBox?

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        overlay.onCommit = { [weak self] rect in self?.commit(overlayRect: rect) }
        overlay.onUpdate = { [weak self] rect in self?.livePreview(overlayRect: rect) }
        overlay.onCancel = { [weak self] in self?.revertPreview() }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func layout() {
        super.layout()
        overlay.frame = bounds
        if placing { addSubview(overlay, positioned: .above, relativeTo: nil) }
    }

    /// Live stamp preview while dragging the initial box: the committed StampAnnotation
    /// is created/updated in real time, so what you see mid-drag is what you get.
    private func livePreview(overlayRect: NSRect) {
        let viewRect = convert(overlayRect, from: overlay)
        guard let page = page(for: NSPoint(x: viewRect.midX, y: viewRect.midY), nearest: true),
              document != nil else { return }
        let pageRect = convert(viewRect, to: page)
        if let prev = previewAnnotation {
            if prev.page == page {
                prev.annotation.bounds = pageRect
            } else {
                prev.page.removeAnnotation(prev.annotation)
                let annotation = StampAnnotation(bounds: pageRect, appearance: stampAppearance)
                page.addAnnotation(annotation)
                previewAnnotation = (page, annotation)
            }
        } else {
            showPreview(on: page, rect: pageRect)
        }
        overlay.suppressDragRect = true
        setNeedsDisplay(convert(pageRect, from: page).insetBy(dx: -12, dy: -12))
    }

    /// Drag ended below the size threshold: restore the previously committed box.
    private func revertPreview() {
        overlay.suppressDragRect = false
        if let box = lastCommitted, let doc = document, box.pageIndex < doc.pageCount,
           let page = doc.page(at: box.pageIndex) {
            if let prev = previewAnnotation, prev.page == page {
                prev.annotation.bounds = box.rect
            } else {
                showPreview(on: page, rect: box.rect)
            }
            setNeedsDisplay(convert(box.rect, from: page).insetBy(dx: -12, dy: -12))
        } else if let prev = previewAnnotation {
            prev.page.removeAnnotation(prev.annotation)
            previewAnnotation = nil
            setNeedsDisplay(bounds)
        }
    }

    /// Forget the box entirely (called when the document changes).
    func clearBox() {
        if let prev = previewAnnotation { prev.page.removeAnnotation(prev.annotation) }
        previewAnnotation = nil
        lastCommitted = nil
    }

    private func commit(overlayRect: NSRect) {
        overlay.suppressDragRect = false
        livePreview(overlayRect: overlayRect)
        placing = false
        guard let doc = document, let (page, annotation) = previewAnnotation else { return }
        let box = SignatureBox(pageIndex: doc.index(for: page), rect: annotation.bounds)
        lastCommitted = box
        onSelect?(box)
    }

    private func showPreview(on page: PDFPage, rect: CGRect) {
        if let prev = previewAnnotation { prev.page.removeAnnotation(prev.annotation) }
        let annotation = StampAnnotation(bounds: rect, appearance: stampAppearance)
        page.addAnnotation(annotation)
        previewAnnotation = (page, annotation)
    }

    // MARK: Box resize / move

    private enum BoxHandle: CaseIterable { case nw, n, ne, e, se, s, sw, w }

    private struct BoxDrag {
        let page: PDFPage
        let startPoint: CGPoint   // page coords
        let startBounds: CGRect   // page coords
        let handle: BoxHandle?    // nil = move
    }
    private var boxDrag: BoxDrag?
    private let minBoxSize: CGFloat = 24

    /// Handle centers in page coords (y-up), inset like the drawn handles.
    private func handleCenters(bounds b: CGRect, inset: CGFloat) -> [(BoxHandle, CGPoint)] {
        [(.nw, CGPoint(x: b.minX + inset, y: b.maxY - inset)),
         (.n,  CGPoint(x: b.midX, y: b.maxY - inset)),
         (.ne, CGPoint(x: b.maxX - inset, y: b.maxY - inset)),
         (.e,  CGPoint(x: b.maxX - inset, y: b.midY)),
         (.se, CGPoint(x: b.maxX - inset, y: b.minY + inset)),
         (.s,  CGPoint(x: b.midX, y: b.minY + inset)),
         (.sw, CGPoint(x: b.minX + inset, y: b.minY + inset)),
         (.w,  CGPoint(x: b.minX + inset, y: b.midY))]
    }

    private func handleAt(point pt: CGPoint, bounds: CGRect, tol: CGFloat) -> BoxHandle? {
        let inset = 3.5 / max(scaleFactor, 0.01)
        return handleCenters(bounds: bounds, inset: inset)
            .first { abs($0.1.x - pt.x) <= tol && abs($0.1.y - pt.y) <= tol }?.0
    }

    private func cursor(for handle: BoxHandle) -> NSCursor {
        switch handle {
        case .n, .s: return .resizeUpDown
        case .e, .w: return .resizeLeftRight
        default: return .crosshair
        }
    }

    /// The box under the event, if the event is on the box's page. Returns the point
    /// in page coordinates.
    private func boxPoint(for event: NSEvent) -> (point: CGPoint, page: PDFPage, bounds: CGRect)? {
        guard let (boxPage, annotation) = previewAnnotation else { return nil }
        let viewPt = convert(event.locationInWindow, from: nil)
        guard let hitPage = page(for: viewPt, nearest: true), hitPage == boxPage else { return nil }
        return (convert(viewPt, to: boxPage), boxPage, annotation.bounds)
    }

    override func mouseDown(with event: NSEvent) {
        guard !placing, let (pt, page, bounds) = boxPoint(for: event) else {
            super.mouseDown(with: event)
            return
        }
        let tol = 9.0 / max(scaleFactor, 0.01)
        if let handle = handleAt(point: pt, bounds: bounds, tol: tol) {
            boxDrag = BoxDrag(page: page, startPoint: pt, startBounds: bounds, handle: handle)
            cursor(for: handle).set()
        } else if bounds.contains(pt) {
            boxDrag = BoxDrag(page: page, startPoint: pt, startBounds: bounds, handle: nil)
            NSCursor.closedHand.set()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag = boxDrag, let (_, annotation) = previewAnnotation else {
            super.mouseDragged(with: event)
            return
        }
        let viewPt = convert(event.locationInWindow, from: nil)
        let pt = convert(viewPt, to: drag.page)
        let dx = pt.x - drag.startPoint.x, dy = pt.y - drag.startPoint.y
        let s = drag.startBounds
        let pageBounds = drag.page.bounds(for: .mediaBox)
        var r = s

        if let handle = drag.handle {
            var minX = s.minX, minY = s.minY, maxX = s.maxX, maxY = s.maxY
            // y-up page coords: N grows maxY, S moves minY.
            if handle == .nw || handle == .w || handle == .sw {
                minX = min(s.minX + dx, s.maxX - minBoxSize)
            }
            if handle == .ne || handle == .e || handle == .se {
                maxX = max(s.maxX + dx, s.minX + minBoxSize)
            }
            if handle == .sw || handle == .s || handle == .se {
                minY = min(s.minY + dy, s.maxY - minBoxSize)
            }
            if handle == .nw || handle == .n || handle == .ne {
                maxY = max(s.maxY + dy, s.minY + minBoxSize)
            }
            minX = max(minX, pageBounds.minX); minY = max(minY, pageBounds.minY)
            maxX = min(maxX, pageBounds.maxX); maxY = min(maxY, pageBounds.maxY)
            r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        } else {
            var origin = CGPoint(x: s.minX + dx, y: s.minY + dy)
            origin.x = min(max(origin.x, pageBounds.minX), pageBounds.maxX - s.width)
            origin.y = min(max(origin.y, pageBounds.minY), pageBounds.maxY - s.height)
            r = CGRect(origin: origin, size: s.size)
        }

        annotation.bounds = r
        setNeedsDisplay(convert(r, from: drag.page).insetBy(dx: -12, dy: -12))
    }

    override func mouseUp(with event: NSEvent) {
        guard boxDrag != nil, let (page, annotation) = previewAnnotation else {
            super.mouseUp(with: event)
            return
        }
        boxDrag = nil
        NSCursor.arrow.set()
        if let doc = document {
            let box = SignatureBox(pageIndex: doc.index(for: page), rect: annotation.bounds)
            lastCommitted = box
            onSelect?(box)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard !placing, let (pt, _, bounds) = boxPoint(for: event) else { return }
        let tol = 9.0 / max(scaleFactor, 0.01)
        if let handle = handleAt(point: pt, bounds: bounds, tol: tol) {
            cursor(for: handle).set()
        } else if bounds.contains(pt) {
            NSCursor.openHand.set()
        }
    }
}

/// SwiftUI wrapper around SelectablePDFView.
struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument
    @Binding var placing: Bool
    var appearance = StampAppearance()
    var onSelect: (SignatureBox) -> Void

    func makeNSView(context: Context) -> SelectablePDFView {
        let view = SelectablePDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.document = document
        view.onSelect = onSelect
        view.stampAppearance = appearance
        return view
    }

    func updateNSView(_ view: SelectablePDFView, context: Context) {
        if view.document !== document {
            view.clearBox()
            view.document = document
        }
        view.placing = placing
        view.onSelect = onSelect
        view.stampAppearance = appearance
    }
}
