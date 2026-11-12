import SwiftUI
import PDFKit

/// Transparent overlay on top of the PDF that captures the placement drag and draws the
/// live selection rectangle. When inactive it passes mouse events through (hitTest → nil)
/// so normal PDF scrolling/selection keeps working.
final class DrawOverlay: NSView {
    var active = false {
        didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) }
    }
    var onCommit: ((NSRect) -> Void)?
    var onUpdate: ((NSRect) -> Void)?   // live drag rect, once past the size threshold
    var onClick: ((NSPoint) -> Void)?   // released below the threshold: place a default-size field
    /// Hide the dashed drag rect while the live preview is standing in for it.
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
        let rect = current, origin = start
        start = nil
        current = nil
        needsDisplay = true
        if let rect, rect.width > 6, rect.height > 6 {
            onCommit?(rect)
        } else if let origin {
            onClick?(origin)
        }
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

/// A placed field rendered as its final content (stamp / text) so what you see is what
/// gets signed, plus editing affordances. UI only — never saved into the signed PDF
/// (the engine re-stamps from the source file).
final class FieldAnnotation: PDFAnnotation {
    var field: PlacedField
    var appearance: StampAppearance
    var isSelectedField = false
    /// Handle square size in screen points (converted to page units at draw time).
    var handleScreenSize: CGFloat = 7

    init(field: PlacedField, appearance: StampAppearance) {
        self.field = field
        self.appearance = appearance
        super.init(bounds: field.rect, forType: .square, withProperties: nil)
        shouldPrint = false
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let b = bounds
        guard b.width > 4, b.height > 4 else { return }
        let unit = pixelUnit(context)

        FieldRenderer.withFieldContext(context, rect: b, display: page?.displayTransform ?? .identity) { size in
            var shown = field
            shown.rect = b
            if field.kind == .text, field.text.isEmpty {
                // Placeholder so an empty text field is visible and obviously unfilled.
                ("Text…" as NSString).draw(
                    at: NSPoint(x: 2, y: max(0, (size.height - 12) / 2)),
                    withAttributes: [.font: NSFont.systemFont(ofSize: min(11, size.height * 0.6)),
                                     .foregroundColor: NSColor.systemOrange])
            } else {
                FieldRenderer.draw(shown, appearance: appearance, size: size)
            }

            if isSelectedField, field.isFormField {
                // The form fixes this box — outline it, but offer no resize handles.
                let p = NSBezierPath(rect: CGRect(origin: .zero, size: size).insetBy(dx: unit, dy: unit))
                p.lineWidth = 2 * unit
                NSColor.controlAccentColor.setStroke()
                p.stroke()
            } else if isSelectedField {
                drawHandles(size: size, unit: unit)
            } else if field.kind != .signature {
                // Text/date are borderless in the output — outline them so they're findable.
                let p = NSBezierPath(rect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5 * unit, dy: 0.5 * unit))
                p.lineWidth = unit
                p.setLineDash([3 * unit, 2 * unit], count: 2, phase: 0)
                NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
                p.stroke()
            }
        }
    }

    private func drawHandles(size: CGSize, unit: CGFloat) {
        let w = size.width, h = size.height
        let outline = NSBezierPath(rect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5 * unit, dy: 0.5 * unit))
        outline.lineWidth = unit
        NSColor.controlAccentColor.setStroke()
        outline.stroke()

        let hs = handleScreenSize * unit
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
            let p = NSBezierPath(rect: r)
            p.lineWidth = unit
            p.stroke()
        }
    }
}

/// Page units → device pixels, so affordances keep a constant on-screen size. Uses the
/// CTM's scale, not `a` alone, which is 0 on 90°/270° pages.
private func pixelUnit(_ context: CGContext) -> CGFloat {
    let backing = NSScreen.main?.backingScaleFactor ?? 2
    let m = context.ctm
    return backing / max(hypot(m.a, m.b), 0.01)
}

/// One of the document's own empty signature fields, offered as a place to sign: a
/// dashed box with a "Sign here" tag. Clicking it fills that field (see fillSlot).
final class SlotAnnotation: PDFAnnotation {
    let slot: FormSignatureField

    init(slot: FormSignatureField) {
        self.slot = slot
        super.init(bounds: slot.rect, forType: .square, withProperties: nil)
        shouldPrint = false
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let unit = pixelUnit(context)
        FieldRenderer.withFieldContext(context, rect: bounds, display: page?.displayTransform ?? .identity) { size in
            let tint = NSColor.systemOrange
            tint.withAlphaComponent(0.10).setFill()
            CGRect(origin: .zero, size: size).fill()
            let p = NSBezierPath(rect: CGRect(origin: .zero, size: size).insetBy(dx: unit, dy: unit))
            p.lineWidth = 1.5 * unit
            p.setLineDash([5 * unit, 3 * unit], count: 2, phase: 0)
            tint.setStroke()
            p.stroke()
            let label = "Sign here" as NSString
            let font = NSFont.systemFont(ofSize: min(12, max(6, size.height * 0.3)), weight: .semibold)
            let ls = label.size(withAttributes: [.font: font])
            label.draw(at: NSPoint(x: (size.width - ls.width) / 2, y: (size.height - ls.height) / 2),
                       withAttributes: [.font: font, .foregroundColor: tint])
        }
    }
}

/// Callbacks from the PDF view back into the model. The view owns transient state
/// (in-progress drags); the model owns the committed field list.
struct FieldEditingHandlers {
    var add: (_ id: UUID, _ kind: FieldKind, _ pageIndex: Int, _ rect: CGRect) -> Void = { _, _, _, _ in }
    var move: (_ id: UUID, _ rect: CGRect) -> Void = { _, _ in }
    var select: (UUID?) -> Void = { _ in }
    var delete: (UUID) -> Void = { _ in }
    var placingDone: () -> Void = {}
    /// Sign into the document's own signature field with this name.
    var fillSlot: (String) -> Void = { _ in }
}

/// PDFView that places, selects, moves and resizes fields. Fields are shown as
/// annotations so they scroll/zoom with the content.
final class SelectablePDFView: PDFView {
    var placingKind: FieldKind? {
        didSet {
            guard placingKind != oldValue else { return }
            overlay.active = placingKind != nil
            if placingKind != nil {
                addSubview(overlay, positioned: .above, relativeTo: nil)
                overlay.suppressDragRect = false
            } else {
                discardPending()
            }
            overlay.frame = bounds
            window?.invalidateCursorRects(for: overlay)
        }
    }
    var handlers = FieldEditingHandlers()

    private let overlay = DrawOverlay()
    private var annotations: [UUID: FieldAnnotation] = [:]
    private var slotAnnotations: [String: SlotAnnotation] = [:]
    private var order: [UUID] = []          // model order; later = on top for hit testing
    private var selectedID: UUID?
    private var stampAppearance = StampAppearance()
    /// In-progress placement drag (not yet in the model).
    private var pending: (id: UUID, annotation: FieldAnnotation)?

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        overlay.onCommit = { [weak self] rect in self?.commit(overlayRect: rect) }
        overlay.onUpdate = { [weak self] rect in self?.livePreview(overlayRect: rect) }
        overlay.onClick = { [weak self] point in self?.placeDefault(at: point) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func layout() {
        super.layout()
        overlay.frame = bounds
        if placingKind != nil { addSubview(overlay, positioned: .above, relativeTo: nil) }
    }

    // MARK: Model → view

    /// Annotations belong to the old document's pages; forget them before swapping.
    func resetForNewDocument() {
        annotations.removeAll()
        slotAnnotations.removeAll()
        order.removeAll()
        pending = nil
        boxDrag = nil
    }

    /// Reconcile annotations with the model. Bounds of a field being dragged are left
    /// alone — the drag is the source of truth until mouse-up.
    func sync(fields: [PlacedField], slots: [FormSignatureField], selectedID: UUID?, appearance: StampAppearance) {
        guard let doc = document else { return }
        let appearanceChanged = appearance != stampAppearance
        stampAppearance = appearance
        self.selectedID = selectedID
        order = fields.map(\.id)
        var touched = Set<PDFPage>()

        // Slots sit below the fields: a filled slot disappears and its field takes over.
        let liveSlots = Set(slots.map(\.name))
        for (name, a) in slotAnnotations where !liveSlots.contains(name) {
            if let page = a.page { page.removeAnnotation(a); touched.insert(page) }
            slotAnnotations[name] = nil
        }
        for slot in slots where slotAnnotations[slot.name] == nil {
            guard let page = doc.page(at: slot.pageIndex) else { continue }
            let a = SlotAnnotation(slot: slot)
            page.addAnnotation(a)
            slotAnnotations[slot.name] = a
            touched.insert(page)
        }

        let live = Set(order)
        for (id, annotation) in annotations where !live.contains(id) {
            if let page = annotation.page { page.removeAnnotation(annotation); touched.insert(page) }
            annotations[id] = nil
        }

        for field in fields {
            guard field.pageIndex >= 0, field.pageIndex < doc.pageCount,
                  let page = doc.page(at: field.pageIndex) else { continue }
            let isSelected = field.id == selectedID
            if let a = annotations[field.id] {
                let dragging = boxDrag?.id == field.id
                var dirty = appearanceChanged || a.isSelectedField != isSelected || a.field != field
                a.field = field
                a.appearance = appearance
                a.isSelectedField = isSelected
                if a.page != page {
                    a.page?.removeAnnotation(a)
                    a.bounds = field.rect
                    page.addAnnotation(a)
                    dirty = true
                } else if !dragging, a.bounds != field.rect {
                    a.bounds = field.rect
                    dirty = true
                }
                if dirty { touched.insert(page) }
            } else {
                let a = FieldAnnotation(field: field, appearance: appearance)
                a.isSelectedField = isSelected
                page.addAnnotation(a)
                annotations[field.id] = a
                touched.insert(page)
            }
        }
        for page in touched { annotationsChanged(on: page) }
    }

    // MARK: Placement

    private func pagePoint(overlayPoint: NSPoint) -> (PDFPage, CGPoint)? {
        let viewPt = convert(overlayPoint, from: overlay)
        guard let page = page(for: viewPt, nearest: true) else { return nil }
        return (page, convert(viewPt, to: page))
    }

    /// Live preview while dragging out a new field: what you see mid-drag is what you get.
    private func livePreview(overlayRect: NSRect) {
        guard let kind = placingKind, document != nil else { return }
        let viewRect = convert(overlayRect, from: overlay)
        guard let page = page(for: NSPoint(x: viewRect.midX, y: viewRect.midY), nearest: true) else { return }
        let pageRect = page.clamp(convert(viewRect, to: page))
        if let p = pending, p.annotation.page == page {
            p.annotation.bounds = pageRect
        } else {
            discardPending()
            let id = UUID()
            let a = FieldAnnotation(field: PlacedField(id: id, kind: kind, pageIndex: 0, rect: pageRect),
                                    appearance: stampAppearance)
            a.isSelectedField = true
            page.addAnnotation(a)
            pending = (id, a)
        }
        overlay.suppressDragRect = true
        annotationsChanged(on: page)
    }

    private func discardPending() {
        guard let p = pending else { return }
        let page = p.annotation.page
        page?.removeAnnotation(p.annotation)
        pending = nil
        if let page { annotationsChanged(on: page) }
    }

    private func commit(overlayRect: NSRect) {
        overlay.suppressDragRect = false
        livePreview(overlayRect: overlayRect)
        guard let doc = document, let kind = placingKind, let p = pending, let page = p.annotation.page else { return }
        // Adopt the pending annotation under the field's id so sync() finds it — no flicker.
        annotations[p.id] = p.annotation
        pending = nil
        handlers.add(p.id, kind, doc.index(for: page), p.annotation.bounds)
        handlers.placingDone()
    }

    private func placeDefault(at overlayPoint: NSPoint) {
        guard let doc = document, let kind = placingKind,
              let (page, pt) = pagePoint(overlayPoint: overlayPoint) else { return }
        discardPending()
        if kind == .signature, let slot = slotAt(page: page, point: pt) {
            // Clicking the document's own signature field with the tool: sign there.
            handlers.fillSlot(slot.name)
            return
        }
        let size = page.pageSize(fromDisplay: kind.defaultSize)
        let rect = page.clamp(CGRect(x: pt.x - size.width / 2, y: pt.y - size.height / 2,
                                     width: size.width, height: size.height))
        handlers.add(UUID(), kind, doc.index(for: page), rect)
        handlers.placingDone()
    }

    // MARK: Selection, move, resize

    private enum BoxHandle: CaseIterable { case nw, n, ne, e, se, s, sw, w }

    private struct BoxDrag {
        let id: UUID
        let page: PDFPage
        let startPoint: CGPoint   // page coords
        let startBounds: CGRect   // page coords
        let handle: BoxHandle?    // nil = move
    }
    private var boxDrag: BoxDrag?
    private let minBoxSize: CGFloat = 10

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

    private func handleAt(point pt: CGPoint, bounds: CGRect) -> BoxHandle? {
        let tol = 6.0 / max(scaleFactor, 0.01)
        let inset = 3.5 / max(scaleFactor, 0.01)
        return handleCenters(bounds: bounds, inset: inset)
            .first { abs($0.1.x - pt.x) <= tol && abs($0.1.y - pt.y) <= tol }?.0
    }

    /// Handles are named in page space; on a 90°/270° page "n" looks sideways on screen.
    private func cursor(for handle: BoxHandle, on page: PDFPage) -> NSCursor {
        let sideways = page.rotation % 180 != 0
        switch handle {
        case .n, .s: return sideways ? .resizeLeftRight : .resizeUpDown
        case .e, .w: return sideways ? .resizeUpDown : .resizeLeftRight
        default: return .crosshair
        }
    }

    private func slotAt(page: PDFPage, point: CGPoint) -> FormSignatureField? {
        slotAnnotations.values.first { $0.page == page && $0.bounds.contains(point) }?.slot
    }

    private enum Hit { case handle(UUID, BoxHandle), body(UUID), slot(String) }

    /// What's under the event: the selected field's handles win, then the topmost field.
    private func hit(_ event: NSEvent) -> (hit: Hit, page: PDFPage, point: CGPoint)? {
        let viewPt = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPt, nearest: false) else { return nil }
        let pt = convert(viewPt, to: page)
        if let sel = selectedID, let a = annotations[sel], a.page == page, !a.field.isFormField,
           let handle = handleAt(point: pt, bounds: a.bounds) {
            return (.handle(sel, handle), page, pt)
        }
        for id in order.reversed() {
            if let a = annotations[id], a.page == page, a.bounds.contains(pt) {
                return (.body(id), page, pt)
            }
        }
        if let slot = slotAt(page: page, point: pt) { return (.slot(slot.name), page, pt) }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard placingKind == nil, let (hit, page, pt) = hit(event) else {
            if placingKind == nil, selectedID != nil { handlers.select(nil) }
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)  // so Delete / arrows reach keyDown
        switch hit {
        case .handle(let id, let handle):
            boxDrag = BoxDrag(id: id, page: page, startPoint: pt,
                              startBounds: annotations[id]!.bounds, handle: handle)
            cursor(for: handle, on: page).set()
        case .body(let id):
            if id != selectedID { handlers.select(id) }
            guard annotations[id]?.field.isFormField == false else { return }  // fixed by the form
            boxDrag = BoxDrag(id: id, page: page, startPoint: pt,
                              startBounds: annotations[id]!.bounds, handle: nil)
            NSCursor.closedHand.set()
        case .slot(let name):
            handlers.fillSlot(name)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag = boxDrag, let annotation = annotations[drag.id] else {
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
        annotationsChanged(on: drag.page)
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag = boxDrag, let annotation = annotations[drag.id] else {
            super.mouseUp(with: event)
            return
        }
        boxDrag = nil
        NSCursor.arrow.set()
        if annotation.bounds != drag.startBounds { handlers.move(drag.id, annotation.bounds) }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard placingKind == nil, boxDrag == nil, let (hit, page, _) = hit(event) else { return }
        switch hit {
        case .handle(_, let handle): cursor(for: handle, on: page).set()
        case .body(let id): (annotations[id]?.field.isFormField == true ? NSCursor.arrow : .openHand).set()
        case .slot: NSCursor.pointingHand.set()
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Escape: leave placement mode, else deselect
            if placingKind != nil { handlers.placingDone(); return }
            if selectedID != nil { handlers.select(nil); return }
        }
        guard let id = selectedID, let a = annotations[id], let page = a.page else {
            super.keyDown(with: event)
            return
        }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        // Arrows move the box the way it looks on screen, whatever the page's /Rotate.
        let screen: CGVector
        switch event.keyCode {
        case 51, 117: handlers.delete(id); return   // delete, forward delete
        case 123: screen = CGVector(dx: -step, dy: 0)
        case 124: screen = CGVector(dx: step, dy: 0)
        case 125: screen = CGVector(dx: 0, dy: -step)
        case 126: screen = CGVector(dx: 0, dy: step)
        default: super.keyDown(with: event); return
        }
        guard !a.field.isFormField else { return }
        let v = page.pageVector(fromDisplay: screen)
        handlers.move(id, page.clamp(a.bounds.offsetBy(dx: v.dx, dy: v.dy)))
    }
}

/// SwiftUI wrapper around SelectablePDFView.
struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument
    var fields: [PlacedField] = []
    var selectedFieldID: UUID? = nil
    var placingKind: FieldKind? = nil
    var slots: [FormSignatureField] = []
    var appearance = StampAppearance()
    var handlers = FieldEditingHandlers()

    func makeNSView(context: Context) -> SelectablePDFView {
        let view = SelectablePDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.document = document
        return view
    }

    func updateNSView(_ view: SelectablePDFView, context: Context) {
        if view.document !== document {
            view.resetForNewDocument()
            view.document = document
        }
        view.handlers = handlers
        view.placingKind = placingKind
        view.sync(fields: fields, slots: slots, selectedID: selectedFieldID, appearance: appearance)
    }
}
