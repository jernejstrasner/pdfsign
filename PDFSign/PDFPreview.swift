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
    }

    override func mouseUp(with event: NSEvent) {
        let rect = current
        start = nil
        current = nil
        needsDisplay = true
        if let rect, rect.width > 6, rect.height > 6 { onCommit?(rect) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard active, let r = current else { return }
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

/// PDFView that lets the user drag a rectangle to place the signature. The committed
/// box is shown as a square annotation on the page so it scrolls/zooms with content.
final class SelectablePDFView: PDFView {
    var placing = false {
        didSet {
            overlay.active = placing
            if placing { addSubview(overlay, positioned: .above, relativeTo: nil) }
            overlay.frame = bounds
            window?.invalidateCursorRects(for: overlay)
        }
    }
    var onSelect: ((SignatureBox) -> Void)?

    private let overlay = DrawOverlay()
    private var previewAnnotation: (page: PDFPage, annotation: PDFAnnotation)?

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        overlay.onCommit = { [weak self] rect in self?.commit(overlayRect: rect) }
    }

    override func layout() {
        super.layout()
        overlay.frame = bounds
        if placing { addSubview(overlay, positioned: .above, relativeTo: nil) }
    }

    private func commit(overlayRect: NSRect) {
        let viewRect = convert(overlayRect, from: overlay)
        guard let page = page(for: NSPoint(x: viewRect.midX, y: viewRect.midY), nearest: true),
              let doc = document else {
            placing = false
            return
        }
        let pageRect = convert(viewRect, to: page)
        showPreview(on: page, rect: pageRect)
        placing = false
        onSelect?(SignatureBox(pageIndex: doc.index(for: page), rect: pageRect))
    }

    private func showPreview(on page: PDFPage, rect: CGRect) {
        if let prev = previewAnnotation { prev.page.removeAnnotation(prev.annotation) }
        let annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        let border = PDFBorder()
        border.lineWidth = 1.5
        border.style = .dashed
        annotation.border = border
        annotation.color = NSColor.controlAccentColor
        page.addAnnotation(annotation)
        previewAnnotation = (page, annotation)
    }
}

/// SwiftUI wrapper around SelectablePDFView.
struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument
    @Binding var placing: Bool
    var onSelect: (SignatureBox) -> Void

    func makeNSView(context: Context) -> SelectablePDFView {
        let view = SelectablePDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.document = document
        view.onSelect = onSelect
        return view
    }

    func updateNSView(_ view: SelectablePDFView, context: Context) {
        if view.document !== document { view.document = document }
        view.placing = placing
        view.onSelect = onSelect
    }
}
