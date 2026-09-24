import SwiftUI
import AppKit

/// Trackpad/mouse signature pad, Preview.app-style. Strokes are captured in view
/// coordinates and rendered to a transparent PNG cropped to the ink bounds, so the
/// engine can scale it into the stamp without dead margins.
final class SignatureCanvasView: NSView {
    var onCommit: ((NSImage) -> Void)?

    private var strokes: [[NSPoint]] = []
    private var inkBounds = CGRect.null
    private let lineWidth: CGFloat = 3.0

    var isEmpty: Bool { strokes.isEmpty }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func clear() {
        strokes = []
        inkBounds = .null
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        strokes.append([p])
        extendInkBounds(to: p)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        strokes[strokes.count - 1].append(p)
        extendInkBounds(to: p)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let image = renderedImage() { onCommit?(image) }
    }

    private func extendInkBounds(to p: NSPoint) {
        let dot = CGRect(x: p.x - lineWidth, y: p.y - lineWidth,
                         width: lineWidth * 2, height: lineWidth * 2)
        inkBounds = inkBounds.union(dot)
    }

    /// Smooth path through a stroke: quadratic curves via segment midpoints.
    private func path(for stroke: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        guard let first = stroke.first else { return path }
        path.move(to: first)
        if stroke.count < 3 {
            for p in stroke.dropFirst() { path.line(to: p) }
            return path
        }
        for i in 1..<(stroke.count - 1) {
            let mid = NSPoint(x: (stroke[i].x + stroke[i + 1].x) / 2,
                              y: (stroke[i].y + stroke[i + 1].y) / 2)
            path.curve(to: mid, controlPoint: stroke[i])
        }
        path.line(to: stroke[stroke.count - 1])
        return path
    }

    private func drawInk() {
        NSColor.black.setStroke()
        for stroke in strokes { path(for: stroke).stroke() }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Baseline guide + hint when empty.
        NSColor.quaternaryLabelColor.setStroke()
        let guide = NSBezierPath()
        guide.lineWidth = 1
        guide.setLineDash([4, 3], count: 2, phase: 0)
        let gy = bounds.height * 0.28
        guide.move(to: NSPoint(x: 12, y: gy))
        guide.line(to: NSPoint(x: bounds.width - 12, y: gy))
        guide.stroke()

        if strokes.isEmpty {
            let hint = NSString(string: "Sign here")
            hint.draw(at: NSPoint(x: 12, y: bounds.height / 2 - 8), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.placeholderTextColor,
            ])
        }
        drawInk()
    }

    /// Renders the ink at 3x, cropped to the stroke bounds (small margin kept).
    func renderedImage() -> NSImage? {
        guard !strokes.isEmpty, !inkBounds.isNull, inkBounds.width > 0, inkBounds.height > 0
        else { return nil }

        let margin: CGFloat = 6
        let crop = inkBounds.insetBy(dx: -margin, dy: -margin).intersection(bounds)
        let scale: CGFloat = 3
        let pxW = Int(ceil(crop.width * scale))
        let pxH = Int(ceil(crop.height * scale))
        guard pxW > 0, pxH > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pxW, pixelsHigh: pxH,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = ctx
        ctx?.shouldAntialias = true
        ctx?.imageInterpolation = .high
        ctx?.cgContext.translateBy(x: -crop.minX * scale, y: -crop.minY * scale)
        ctx?.cgContext.scaleBy(x: scale, y: scale)
        drawInk()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: pxW, height: pxH))
        image.addRepresentation(rep)
        return image
    }
}

/// SwiftUI wrapper. `onCommit` fires on mouse-up with the cropped signature image.
struct SignatureCanvas: NSViewRepresentable {
    var onCommit: (NSImage) -> Void

    func makeNSView(context: Context) -> SignatureCanvasView {
        let view = SignatureCanvasView()
        view.onCommit = onCommit
        return view
    }

    func updateNSView(_ view: SignatureCanvasView, context: Context) {
        view.onCommit = onCommit
    }
}
