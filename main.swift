// SnapShelf — minimal screenshot shelf for macOS.
// Hotkeys: ⌃⌘2 area capture, ⌃⌘1 full screen. Also via menu bar icon.
// Thumbnail floats bottom-left with a toolbar (Copy / Crop / Markup / ✕); ✕ dismisses.
// Drag the image into any window to drop the PNG. Clicking the image, Markup, or Crop
// opens a big centered in-app editor: pen, arrow, box, text, color, undo, crop.
// ponytail: capture delegates to /usr/sbin/screencapture — Apple's selection UI for free.

import Cocoa
import Carbon.HIToolbox
import ImageIO
import ServiceManagement
import Vision

private let maxThumbWidth: CGFloat = 320
private let screenMargin: CGFloat = 16
private let autoCleanupDays = 60   // captures older than this are deleted at launch

// Newest-first list of every saved capture.
private func capturedFiles() -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(at: saveDir,
                                                   includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
        .filter { $0.pathExtension.lowercased() == "png" }
        .sorted {
            let da = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da > db
        }
}

// All captures live here — survives reboots, browsable in Finder.
private let saveDir: URL = {
    let d = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SnapShelf")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}()

// Hotkeys — edit here, rebuild with build.sh. id 1 = area capture, id 2 = full screen.
// Command-Control shortcuts avoid conflicts with macOS system screenshot hotkeys.
private let hotkeys: [(keyCode: Int, modifiers: Int, id: UInt32)] = [
    (kVK_ANSI_2, cmdKey | controlKey, 1),
    (kVK_ANSI_1, cmdKey | controlKey, 2),
]

final class ActionButton: NSButton {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    convenience init(title: String) {
        self.init(title: title, target: nil, action: nil)
        target = self
        action = #selector(clicked)
        bezelStyle = .recessed
        showsBorderOnlyWhileMouseInside = true
        controlSize = .small
        font = .systemFont(ofSize: 11)
        sizeToFit()
    }
    @objc private func clicked() { onClick?() }
}

// MARK: - Annotations

enum Tool: Int { case pen = 0, highlight, arrow, box, text, blur, crop }

enum Annotation {
    case pen([NSPoint], NSColor)
    case highlight([NSPoint], NSColor)   // wide translucent multiply stroke
    case arrow(NSPoint, NSPoint, NSColor)
    case box(NSRect, NSColor)
    case text(String, NSPoint, NSColor, CGFloat)
    case blur(NSRect, NSImage)   // rect + prebuilt pixelated tile of that region

    func draw(lineWidth lw: CGFloat) {
        switch self {
        case .pen(let pts, let c):
            guard pts.count > 1 else { return }
            c.setStroke()
            let p = NSBezierPath()
            p.lineWidth = lw
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.move(to: pts[0])
            for pt in pts.dropFirst() { p.line(to: pt) }
            p.stroke()
        case .highlight(let pts, let c):
            guard pts.count > 1 else { return }
            let cgc = NSGraphicsContext.current?.cgContext
            cgc?.saveGState()
            cgc?.setBlendMode(.multiply)
            c.withAlphaComponent(0.45).setStroke()
            let p = NSBezierPath()
            p.lineWidth = lw
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.move(to: pts[0])
            for pt in pts.dropFirst() { p.line(to: pt) }
            p.stroke()
            cgc?.restoreGState()
        case .arrow(let a, let b, let c):
            c.setStroke()
            c.setFill()
            let p = NSBezierPath()
            p.lineWidth = lw
            p.lineCapStyle = .round
            p.move(to: a)
            p.line(to: b)
            p.stroke()
            let ang = atan2(b.y - a.y, b.x - a.x)
            let hl = lw * 4
            let p1 = NSPoint(x: b.x - hl * cos(ang - .pi / 7), y: b.y - hl * sin(ang - .pi / 7))
            let p2 = NSPoint(x: b.x - hl * cos(ang + .pi / 7), y: b.y - hl * sin(ang + .pi / 7))
            let head = NSBezierPath()
            head.move(to: b)
            head.line(to: p1)
            head.line(to: p2)
            head.close()
            head.fill()
        case .box(let r, let c):
            c.setStroke()
            let p = NSBezierPath(rect: r)
            p.lineWidth = lw
            p.stroke()
        case .text(let s, let pt, let c, let fs):
            NSAttributedString(string: s, attributes: [
                .font: NSFont.boldSystemFont(ofSize: fs),
                .foregroundColor: c,
            ]).draw(at: pt)
        case .blur(let r, let tile):
            let ctx = NSGraphicsContext.current
            let prev = ctx?.imageInterpolation ?? .default
            ctx?.imageInterpolation = .none   // hard pixel blocks, no smoothing
            tile.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
            ctx?.imageInterpolation = prev
        }
    }

    func translated(by d: NSPoint) -> Annotation {
        func t(_ p: NSPoint) -> NSPoint { NSPoint(x: p.x + d.x, y: p.y + d.y) }
        switch self {
        case .pen(let pts, let c): return .pen(pts.map(t), c)
        case .highlight(let pts, let c): return .highlight(pts.map(t), c)
        case .arrow(let a, let b, let c): return .arrow(t(a), t(b), c)
        case .box(let r, let c): return .box(NSRect(origin: t(r.origin), size: r.size), c)
        case .text(let s, let p, let c, let f): return .text(s, t(p), c, f)
        case .blur(let r, let tile): return .blur(NSRect(origin: t(r.origin), size: r.size), tile)
        }
    }
}

// MARK: - Editor canvas: draws image + annotations, handles tool input in image coords

final class EditorCanvas: NSView {
    var image: NSImage {
        didSet {
            superview?.needsLayout = true
            needsDisplay = true
        }
    }
    struct Mark {
        let a: Annotation
        let width: CGFloat
    }
    var marks: [Mark] = [] { didSet { needsDisplay = true } }
    var searchHighlights: [NSRect] = [] { didSet { needsDisplay = true } }   // view-only, never saved
    var tool: Tool = .pen
    var color: NSColor = .systemRed
    var widthScale: CGFloat = 1   // set by the S/M/L picker
    var onTextRequest: ((NSPoint) -> Void)?   // image-point where user clicked with text tool

    // Undo stack: annotations undo one mark, crops restore the pre-crop state.
    private enum EditOp {
        case mark
        case crop(NSImage, [Mark])
    }
    private var ops: [EditOp] = []

    private var currentPen: [NSPoint] = []
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?

    static func strokeWidth(for image: NSImage) -> CGFloat { max(2, image.size.width / 250) }
    static func fontSize(for image: NSImage) -> CGFloat { max(14, image.size.width / 30) }

    var viewScale: CGFloat { bounds.width / max(image.size.width, 1) }
    private func toImage(_ e: NSEvent) -> NSPoint {
        let p = convert(e.locationInWindow, from: nil)
        return NSPoint(x: p.x / viewScale, y: p.y / viewScale)
    }

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        guard image.size.width > 0 else { return }
        let t = NSAffineTransform()
        t.scale(by: viewScale)
        t.concat()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        if !searchHighlights.isEmpty {
            NSColor.systemYellow.withAlphaComponent(0.45).setFill()
            for r in searchHighlights { NSBezierPath(rect: r.insetBy(dx: -3, dy: -3)).fill() }
        }
        for m in marks { m.a.draw(lineWidth: m.width) }
        let lw = Self.strokeWidth(for: image) * widthScale
        if currentPen.count > 1 {
            if tool == .highlight {
                Annotation.highlight(currentPen, color).draw(lineWidth: lw * 5)
            } else {
                Annotation.pen(currentPen, color).draw(lineWidth: lw)
            }
        }
        if let s = dragStart, let c = dragCurrent {
            let r = rect(from: s, to: c)
            switch tool {
            case .arrow: Annotation.arrow(s, c, color).draw(lineWidth: lw)
            case .box: Annotation.box(r, color).draw(lineWidth: lw)
            case .blur:
                NSColor.black.withAlphaComponent(0.35).setFill()
                NSBezierPath(rect: r).fill()
            case .crop:
                NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
                NSBezierPath(rect: r).fill()
                NSColor.controlAccentColor.setStroke()
                let p = NSBezierPath(rect: r)
                p.lineWidth = max(1, lw / 2)
                p.setLineDash([6, 4], count: 2, phase: 0)
                p.stroke()
            default: break
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)   // commits any active text field
        let p = toImage(event)
        switch tool {
        case .text: onTextRequest?(p)
        case .pen, .highlight: currentPen = [p]
        default: dragStart = p; dragCurrent = p
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = toImage(event)
        if tool == .pen || tool == .highlight { currentPen.append(p) } else { dragCurrent = p }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { currentPen = []; dragStart = nil; dragCurrent = nil; needsDisplay = true }
        let p = toImage(event)
        switch tool {
        case .pen:
            if currentPen.count > 1 { addMark(.pen(currentPen, color)) }
        case .highlight:
            if currentPen.count > 1 { addMark(.highlight(currentPen, color)) }
        case .arrow:
            if let s = dragStart, hypot(p.x - s.x, p.y - s.y) * viewScale > 6 {
                addMark(.arrow(s, p, color))
            }
        case .box:
            if let s = dragStart {
                let r = rect(from: s, to: p)
                if r.width * viewScale > 6, r.height * viewScale > 6 { addMark(.box(r, color)) }
            }
        case .blur:
            if let s = dragStart {
                let r = rect(from: s, to: p)
                if r.width * viewScale > 6, r.height * viewScale > 6, let tile = pixelTile(for: r) {
                    addMark(.blur(r, tile))
                }
            }
        case .crop:
            if let s = dragStart {
                let r = rect(from: s, to: p)
                if r.width * viewScale > 8, r.height * viewScale > 8 { applyCrop(imageRect: r) }
            }
        case .text: break
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            undo()
            return
        }
        super.keyDown(with: event)
    }

    func addMark(_ a: Annotation) {
        var w = Self.strokeWidth(for: image) * widthScale
        if case .highlight = a { w *= 5 }
        marks.append(Mark(a: a, width: w))
        ops.append(.mark)
    }

    func undo() {
        switch ops.popLast() {
        case .mark:
            _ = marks.popLast()
        case .crop(let prevImage, let prevMarks):
            image = prevImage
            marks = prevMarks
        case nil:
            break
        }
        needsDisplay = true
    }

    private func applyCrop(imageRect r: NSRect) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let s = CGFloat(cg.width) / max(image.size.width, 1)
        let px = CGRect(x: r.minX * s, y: (image.size.height - r.maxY) * s,
                        width: r.width * s, height: r.height * s).integral
        guard px.width > 2, px.height > 2, let cropped = cg.cropping(to: px) else { return }
        ops.append(.crop(image, marks))
        image = NSImage(cgImage: cropped, size: NSSize(width: px.width / s, height: px.height / s))
        let d = NSPoint(x: -r.minX, y: -r.minY)
        marks = marks.map { Mark(a: $0.a.translated(by: d), width: $0.width) }
    }

    private func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // Downscale the region to ~12pt blocks; drawn back up with interpolation off = pixelate.
    private func pixelTile(for r: NSRect) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let s = CGFloat(cg.width) / max(image.size.width, 1)
        let px = CGRect(x: r.minX * s, y: (image.size.height - r.maxY) * s,
                        width: r.width * s, height: r.height * s).integral
        guard px.width > 1, px.height > 1, let crop = cg.cropping(to: px) else { return nil }
        let w = max(Int(r.width / 12), 2)
        let h = max(Int(CGFloat(w) * r.height / max(r.width, 1)), 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSImage(cgImage: crop, size: NSSize(width: w, height: h))
            .draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let tiny = NSImage(size: NSSize(width: w, height: h))
        tiny.addRepresentation(rep)
        return tiny
    }

    // Render image + annotations at full pixel resolution.
    func renderPNG() -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cg.width, pixelsHigh: cg.height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(origin: .zero, size: image.size))
        for m in marks { m.a.draw(lineWidth: m.width) }
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Editor window: centered, big, toolbar of tools + Done/Cancel

final class EditorController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    let window: NSWindow
    private let canvas: EditorCanvas
    private let toolPicker: NSSegmentedControl
    private let widthPicker = NSSegmentedControl(labels: ["S", "M", "L"],
                                                 trackingMode: .selectOne, target: nil, action: nil)
    private let colorWell = NSColorWell()
    private let onSave: (Data) -> Void
    private var activeField: NSTextField?
    private var pendingTextPoint = NSPoint.zero
    var onClosed: (() -> Void)?

    init(image: NSImage, tool: Tool, onSave: @escaping (Data) -> Void) {
        self.onSave = onSave
        canvas = EditorCanvas(image: image)
        canvas.tool = tool
        toolPicker = NSSegmentedControl(labels: ["Pen", "Highlight", "Arrow", "Box", "Text", "Blur", "Crop"],
                                        trackingMode: .selectOne, target: nil, action: nil)
        toolPicker.selectedSegment = tool.rawValue

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let barH: CGFloat = 48
        let avail = NSSize(width: screen.width * 0.8, height: screen.height * 0.85 - barH)
        let s = min(avail.width / max(image.size.width, 1), avail.height / max(image.size.height, 1))
        let content = NSSize(width: max(image.size.width * s, 480),
                             height: image.size.height * s + barH)

        window = NSWindow(contentRect: NSRect(origin: .zero, size: content),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        super.init()

        window.title = "Edit Screenshot"
        window.isReleasedWhenClosed = false
        window.delegate = self

        toolPicker.target = self
        toolPicker.action = #selector(toolChanged)
        widthPicker.selectedSegment = 1
        widthPicker.target = self
        widthPicker.action = #selector(widthChanged)
        colorWell.color = canvas.color
        colorWell.target = self
        colorWell.action = #selector(colorChanged)

        let undoBtn = ActionButton(title: "Undo")
        undoBtn.bezelStyle = .rounded
        undoBtn.showsBorderOnlyWhileMouseInside = false
        undoBtn.onClick = { [weak self] in self?.canvas.undo() }
        undoBtn.sizeToFit()

        let cancelBtn = ActionButton(title: "Cancel")
        cancelBtn.bezelStyle = .rounded
        cancelBtn.showsBorderOnlyWhileMouseInside = false
        cancelBtn.keyEquivalent = "\u{1b}"
        cancelBtn.onClick = { [weak self] in self?.window.close() }
        cancelBtn.sizeToFit()

        let doneBtn = ActionButton(title: "Done")
        doneBtn.bezelStyle = .rounded
        doneBtn.showsBorderOnlyWhileMouseInside = false
        doneBtn.keyEquivalent = "\r"
        doneBtn.onClick = { [weak self] in self?.saveAndClose() }
        doneBtn.sizeToFit()

        let container = EditorContainer(canvas: canvas, barHeight: barH,
                                        barItems: [toolPicker, widthPicker, colorWell, undoBtn],
                                        rightItems: [cancelBtn, doneBtn])
        window.contentView = container
        window.initialFirstResponder = canvas

        canvas.onTextRequest = { [weak self] p in self?.beginText(at: p) }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }

    func showSearchHighlights(_ rects: [NSRect], query: String) {
        canvas.searchHighlights = rects
        window.title = rects.isEmpty
            ? "No matches for “\(query)”"
            : "\(rects.count) match\(rects.count == 1 ? "" : "es") for “\(query)”"
    }

    private func saveAndClose() {
        commitActiveField()
        if let data = canvas.renderPNG() { onSave(data) }
        window.close()
    }

    @objc private func toolChanged() {
        commitActiveField()
        canvas.tool = Tool(rawValue: toolPicker.selectedSegment) ?? .pen
        if canvas.tool == .highlight {   // highlighters are yellow until told otherwise
            colorWell.color = .systemYellow
            canvas.color = .systemYellow
        }
        window.makeFirstResponder(canvas)
    }

    @objc private func widthChanged() {
        canvas.widthScale = [0.6, 1, 2][max(widthPicker.selectedSegment, 0)]
    }

    @objc private func colorChanged() { canvas.color = colorWell.color }

    // MARK: Text tool — overlay field, committed into an annotation

    private func beginText(at imagePoint: NSPoint) {
        commitActiveField()
        pendingTextPoint = imagePoint
        let fs = EditorCanvas.fontSize(for: canvas.image) * canvas.viewScale
        let field = NSTextField(frame: NSRect(x: imagePoint.x * canvas.viewScale,
                                              y: imagePoint.y * canvas.viewScale,
                                              width: max(canvas.bounds.width - imagePoint.x * canvas.viewScale, 120),
                                              height: fs + 10))
        field.font = .boldSystemFont(ofSize: fs)
        field.textColor = canvas.color
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .exterior
        field.delegate = self
        canvas.addSubview(field)
        activeField = field
        window.makeFirstResponder(field)
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitActiveField() }

    private func commitActiveField() {
        guard let field = activeField else { return }
        activeField = nil
        let text = field.stringValue
        field.removeFromSuperview()
        guard !text.isEmpty else { return }
        canvas.addMark(.text(text, pendingTextPoint, canvas.color,
                             EditorCanvas.fontSize(for: canvas.image)))
    }

    func windowWillClose(_ notification: Notification) {
        activeField?.removeFromSuperview()
        activeField = nil
        NSColorPanel.shared.close()
        onClosed?()
    }
}

// Lays out the toolbar row on top and keeps the canvas aspect-fit centered below.
final class EditorContainer: NSView {
    private let canvas: EditorCanvas
    private let barHeight: CGFloat
    private let barItems: [NSView]
    private let rightItems: [NSView]

    init(canvas: EditorCanvas, barHeight: CGFloat, barItems: [NSView], rightItems: [NSView]) {
        self.canvas = canvas
        self.barHeight = barHeight
        self.barItems = barItems
        self.rightItems = rightItems
        super.init(frame: .zero)
        addSubview(canvas)
        (barItems + rightItems).forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    override func layout() {
        super.layout()
        let barY = bounds.height - barHeight
        var x: CGFloat = 12
        for item in barItems {
            var f = item.frame
            if item is NSColorWell { f.size = NSSize(width: 44, height: 24) }
            f.origin = NSPoint(x: x, y: barY + (barHeight - f.height) / 2)
            item.frame = f
            x += f.width + 10
        }
        var rx = bounds.width - 12
        for item in rightItems.reversed() {
            var f = item.frame
            f.origin = NSPoint(x: rx - f.width, y: barY + (barHeight - f.height) / 2)
            item.frame = f
            rx -= f.width + 8
        }

        let img = canvas.image.size
        let avail = NSRect(x: 0, y: 0, width: bounds.width, height: barY).insetBy(dx: 12, dy: 12)
        guard img.width > 0, img.height > 0, avail.width > 0, avail.height > 0 else { return }
        let s = min(avail.width / img.width, avail.height / img.height)
        let size = NSSize(width: img.width * s, height: img.height * s)
        canvas.frame = NSRect(x: avail.minX + (avail.width - size.width) / 2,
                              y: avail.minY + (avail.height - size.height) / 2,
                              width: size.width, height: size.height)
    }
}

// MARK: - Thumbnail image view: drag out, click to dismiss

final class ThumbView: NSView, NSDraggingSource {
    var image: NSImage { didSet { layer?.contents = image } }
    let fileURL: URL
    var onClick: (() -> Void)?
    private var downPoint = NSPoint.zero
    private var dragging = false

    init(image: NSImage, fileURL: URL) {
        self.image = image
        self.fileURL = fileURL
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resizeAspectFill
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = event.locationInWindow
        guard !dragging, hypot(p.x - downPoint.x, p.y - downPoint.y) > 4 else { return }
        dragging = true
        // ponytail: drag payload is the file URL only — covers Finder, Slack, browsers,
        // mail, chat. Add an NSImage writer too if some app refuses file drops.
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragging { onClick?() }   // click (no drag) opens the editor
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

// MARK: - One pinned screenshot: panel + toolbar + image + file watcher

final class ShelfItem: NSObject {
    static let barHeight: CGFloat = 26

    let panel: NSPanel
    let url: URL
    var onClosed: ((ShelfItem) -> Void)?

    private var image: NSImage
    private let thumbView: ThumbView
    private let bar = NSVisualEffectView()
    private let copyBtn = ActionButton(title: "Copy")
    private let ocrBtn = ActionButton(title: "OCR")
    private let cropBtn = ActionButton(title: "Crop")
    private let markupBtn = ActionButton(title: "Markup")
    private let linkBtn = ActionButton(title: "Link")
    private let closeBtn = ActionButton(title: "✕")
    private var watcher: DispatchSourceFileSystemObject?
    private var editor: EditorController?
    private var closed = false

    static func thumbSize(for image: NSImage) -> NSSize {
        let scale = min(1, maxThumbWidth / max(image.size.width, 1))
        return NSSize(width: max(image.size.width * scale, 60),
                      height: max(image.size.height * scale, 40))
    }

    init(url: URL, image: NSImage, origin: NSPoint) {
        self.url = url
        self.image = image
        self.thumbView = ThumbView(image: image, fileURL: url)

        let size = ShelfItem.thumbSize(for: image)
        let total = NSSize(width: size.width, height: size.height + ShelfItem.barHeight)
        panel = NSPanel(contentRect: NSRect(origin: origin, size: total),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(origin: .zero, size: total))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor

        bar.material = .titlebar
        bar.blendingMode = .behindWindow
        bar.state = .active

        thumbView.onClick = { [weak self] in self?.openEditor(tool: .pen) }
        copyBtn.onClick = { [weak self] in self?.copyToClipboard() }
        ocrBtn.onClick = { [weak self] in self?.runOCR() }
        cropBtn.onClick = { [weak self] in self?.openEditor(tool: .crop) }
        markupBtn.onClick = { [weak self] in self?.openEditor(tool: .pen) }
        linkBtn.onClick = { [weak self] in self?.shareLink() }
        closeBtn.onClick = { [weak self] in self?.close() }

        container.addSubview(thumbView)
        [copyBtn, ocrBtn, cropBtn, markupBtn, linkBtn, closeBtn].forEach { bar.addSubview($0) }
        container.addSubview(bar)
        panel.contentView = container

        layout()
        startWatching()
    }

    private func layout() {
        let size = ShelfItem.thumbSize(for: image)
        var frame = panel.frame
        frame.size = NSSize(width: size.width, height: size.height + Self.barHeight)
        panel.setFrame(frame, display: true)   // origin fixed → stays anchored bottom-left

        thumbView.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        bar.frame = NSRect(x: 0, y: size.height, width: size.width, height: Self.barHeight)

        var x: CGFloat = 6
        for btn in [copyBtn, ocrBtn, cropBtn, markupBtn, linkBtn] {
            btn.frame.origin = NSPoint(x: x, y: (Self.barHeight - btn.frame.height) / 2)
            x += btn.frame.width + 4
        }
        closeBtn.frame.origin = NSPoint(x: size.width - closeBtn.frame.width - 6,
                                        y: (Self.barHeight - closeBtn.frame.height) / 2)
    }

    // MARK: Actions

    private func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        // Read from disk so editor saves are what gets copied.
        let current = NSImage(contentsOf: url) ?? image
        pb.writeObjects([current, url as NSURL])
        copyBtn.title = "Copied ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.copyBtn.title = "Copy"
            self?.copyBtn.sizeToFit()
        }
        copyBtn.sizeToFit()
    }

    // On-device text recognition → clipboard.
    private func runOCR() {
        ocrBtn.title = "…"
        ocrBtn.sizeToFit()
        let u = url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var text = ""
            if let img = NSImage(contentsOf: u),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.usesLanguageCorrection = true
                try? VNImageRequestHandler(cgImage: cg).perform([req])
                text = (req.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if text.isEmpty {
                    self.ocrBtn.title = "No text"
                } else {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    self.ocrBtn.title = "Copied ✓"
                }
                self.ocrBtn.sizeToFit()
                self.layout()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    self.ocrBtn.title = "OCR"
                    self.ocrBtn.sizeToFit()
                    self.layout()
                }
            }
        }
    }

    // Upload to litterbox (catbox.moe's temp host, no account needed) and copy the URL.
    // Anyone with the link can view it, so blur secrets first; expires after 72 hours.
    private func shareLink() {
        linkBtn.title = "…"
        linkBtn.sizeToFit()
        layout()
        guard let fileData = try? Data(contentsOf: url) else { return }
        var req = URLRequest(url: URL(string: "https://litterbox.catbox.moe/resources/internals/api.php")!)
        req.httpMethod = "POST"
        let boundary = "snapshelf-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("SnapShelf/1.0", forHTTPHeaderField: "User-Agent")
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"reqtype\"\r\n\r\nfileupload\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"time\"\r\n\r\n72h\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"fileToUpload\"; filename=\"\(url.lastPathComponent)\"\r\nContent-Type: image/png\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        URLSession.shared.uploadTask(with: req, from: body) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let link = data.flatMap { String(data: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let link, link.hasPrefix("http"),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(link, forType: .string)
                    self.linkBtn.title = "Link ✓"
                } else {
                    self.linkBtn.title = "Failed"
                }
                self.linkBtn.sizeToFit()
                self.layout()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.linkBtn.title = "Link"
                    self.linkBtn.sizeToFit()
                    self.layout()
                }
            }
        }.resume()
    }

    private func openEditor(tool: Tool) {
        if let editor {
            editor.show()
            return
        }
        let current = NSImage(contentsOf: url) ?? image
        let e = EditorController(image: current, tool: tool) { [weak self] data in
            guard let self else { return }
            try? data.write(to: self.url)   // watcher picks this up → thumb reloads + refits
        }
        e.onClosed = { [weak self] in
            guard let self, !self.closed else { return }
            self.editor = nil
            self.panel.orderFrontRegardless()   // bring the thumb back when editing ends
        }
        editor = e
        panel.orderOut(nil)   // big editor replaces the small thumb while open
        e.show()
    }

    func close() {
        closed = true
        editor?.close()
        watcher?.cancel()
        watcher = nil
        panel.orderOut(nil)
        onClosed?(self)
    }

    // MARK: File watcher — editor saves land back on the thumbnail

    private func startWatching() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, let w = self.watcher else { return }
            let flags = w.data
            // Atomic saves replace the file: re-arm the watch on the new inode.
            if flags.contains(.delete) || flags.contains(.rename) {
                w.cancel()
                self.watcher = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.reloadFromDisk()
                    self.startWatching()
                }
            } else {
                self.reloadFromDisk()
            }
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        watcher = src
    }

    private func reloadFromDisk() {
        guard let img = NSImage(contentsOf: url) else { return }
        image = img
        thumbView.image = img
        layout()
    }
}

// MARK: - History window: searchable grid of every capture

final class HistoryCell: NSView, NSDraggingSource {
    let url: URL
    var onPin: ((URL) -> Void)?
    private var downPoint = NSPoint.zero
    private var dragging = false

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        toolTip = url.deletingPathExtension().lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 400,
            ]
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            else { return }
            let img = NSImage(cgImage: cg, size: .zero)
            DispatchQueue.main.async { self?.layer?.contents = img }
        }
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = event.locationInWindow
        guard !dragging, hypot(p.x - downPoint.x, p.y - downPoint.y) > 4 else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: layer?.contents)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragging { onPin?(url) }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

final class HistoryGrid: NSView {
    var onPin: ((URL) -> Void)?
    private let cellSize = NSSize(width: 168, height: 116)
    private let gap: CGFloat = 10

    override var isFlipped: Bool { true }   // newest capture top-left

    func show(urls: [URL]) {
        subviews.forEach { $0.removeFromSuperview() }
        for u in urls {
            let c = HistoryCell(url: u)
            c.onPin = { [weak self] in self?.onPin?($0) }
            addSubview(c)
        }
        relayout()
    }

    func relayout() {
        let w = max(bounds.width, cellSize.width + 2 * gap)
        let cols = max(Int((w - gap) / (cellSize.width + gap)), 1)
        for (i, v) in subviews.enumerated() {
            let row = i / cols, col = i % cols
            v.frame = NSRect(x: gap + CGFloat(col) * (cellSize.width + gap),
                             y: gap + CGFloat(row) * (cellSize.height + gap),
                             width: cellSize.width, height: cellSize.height)
        }
        let rows = (subviews.count + cols - 1) / cols
        setFrameSize(NSSize(width: w, height: gap + CGFloat(max(rows, 1)) * (cellSize.height + gap)))
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        relayout()
    }
}

final class HistoryWindow: NSObject {
    var onPin: ((URL) -> Void)?
    var onPreview: ((URL, String) -> Void)?   // click during an active search

    private let window: NSWindow
    private let search = NSSearchField()
    private let grid = HistoryGrid()
    private let scroll = NSScrollView()
    private var index: [String: String] = [:]   // filename → recognized text
    private var indexing = false
    private let indexURL = saveDir.appendingPathComponent(".ocr-index.json")

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "SnapShelf History"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 300)

        search.placeholderString = "Search text inside screenshots"
        search.target = self
        search.action = #selector(searchChanged)
        search.isContinuous = true

        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        grid.autoresizingMask = [.width]
        grid.onPin = { [weak self] url in
            guard let self else { return }
            let q = self.search.stringValue
            // Searching? Open the big preview with matches highlighted. Otherwise re-pin.
            if q.isEmpty { self.onPin?(url) } else { self.onPreview?(url, q) }
        }

        let container = HistoryContainer(search: search, scroll: scroll)
        window.contentView = container
    }

    func open() {
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        index = loadIndex()
        reload()
        buildIndex()
    }

    @objc private func searchChanged() { reload() }

    private func reload() {
        let q = search.stringValue.lowercased()
        var urls = capturedFiles()
        if !q.isEmpty {
            urls = urls.filter {
                $0.lastPathComponent.lowercased().contains(q)
                    || (index[$0.lastPathComponent]?.lowercased().contains(q) ?? false)
            }
        }
        grid.show(urls: urls)
    }

    // Image-point rects of every occurrence of query, via Vision word boxes.
    static func matchRects(in url: URL, query: String) -> [NSRect] {
        guard !query.isEmpty, let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cg).perform([req])
        let w = img.size.width, h = img.size.height
        let q = query.lowercased()
        var rects: [NSRect] = []
        for obs in req.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            let text = cand.string.lowercased()
            var from = text.startIndex
            while let r = text.range(of: q, range: from..<text.endIndex) {
                // Vision boxes are normalized with a bottom-left origin — same as image points.
                if let box = try? cand.boundingBox(for: r) {
                    let bb = box.boundingBox
                    rects.append(NSRect(x: bb.minX * w, y: bb.minY * h,
                                        width: bb.width * w, height: bb.height * h))
                }
                from = r.upperBound
            }
        }
        return rects
    }

    static func recognizeText(in url: URL) -> String? {
        guard let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let req = VNRecognizeTextRequest()
        // .accurate, not .fast — fast mode mangles screenshot text into
        // garbage that no search query can match. Runs once per file.
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cg).perform([req])
        return (req.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
    }

    // Called on every new capture so search is current without reopening the window.
    func indexFile(_ url: URL) {
        guard index[url.lastPathComponent] == nil else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let text = HistoryWindow.recognizeText(in: url) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.index[url.lastPathComponent] = text
                self.saveIndex()
            }
        }
    }

    // OCR every un-indexed capture in the background so search-by-content works.
    private func buildIndex() {
        guard !indexing else { return }
        indexing = true
        window.title = "SnapShelf History — indexing…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var idx = self.loadIndex()
            for f in capturedFiles() where idx[f.lastPathComponent] == nil {
                idx[f.lastPathComponent] = HistoryWindow.recognizeText(in: f) ?? ""
            }
            DispatchQueue.main.async {
                self.index.merge(idx) { _, new in new }
                self.saveIndex()
                self.indexing = false
                self.window.title = "SnapShelf History"
                self.reload()
            }
        }
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: indexURL) }
    }

    private func loadIndex() -> [String: String] {
        guard let data = try? Data(contentsOf: indexURL),
              let idx = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return idx
    }
}

final class HistoryContainer: NSView {
    private let search: NSSearchField
    private let scroll: NSScrollView

    init(search: NSSearchField, scroll: NSScrollView) {
        self.search = search
        self.scroll = scroll
        super.init(frame: .zero)
        addSubview(search)
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    override func layout() {
        super.layout()
        let pad: CGFloat = 10
        search.frame = NSRect(x: pad, y: bounds.height - 28 - pad,
                              width: bounds.width - 2 * pad, height: 28)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width,
                              height: bounds.height - 28 - 2 * pad)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var items: [ShelfItem] = []
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var loginItem: NSMenuItem!
    private let recentMenu = NSMenu()
    private let history = HistoryWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder",
                                           accessibilityDescription: "SnapShelf")
        let menu = NSMenu()
        let area = NSMenuItem(title: "Capture Area", action: #selector(captureArea), keyEquivalent: "2")
        area.keyEquivalentModifierMask = [.command, .control]
        area.target = self
        let full = NSMenuItem(title: "Capture Full Screen", action: #selector(captureFull), keyEquivalent: "1")
        full.keyEquivalentModifierMask = [.command, .control]
        full.target = self
        let clear = NSMenuItem(title: "Dismiss All Thumbnails", action: #selector(dismissAll), keyEquivalent: "")
        clear.target = self
        let restart = NSMenuItem(title: "Restart SnapShelf", action: #selector(restartApp), keyEquivalent: "r")
        restart.target = self
        loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        let recent = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recent.submenu = recentMenu
        let historyItem = NSMenuItem(title: "History…", action: #selector(openHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(area)
        menu.addItem(full)
        menu.addItem(.separator())
        menu.addItem(recent)
        menu.addItem(historyItem)
        menu.addItem(clear)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(restart)
        menu.addItem(NSMenuItem(title: "Quit SnapShelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        registerHotkeys()

        // Keep it always available: register as login item on first run.
        if SMAppService.mainApp.status == .notRegistered { try? SMAppService.mainApp.register() }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        history.onPin = { [weak self] url in self?.showThumb(for: url) }
        history.onPreview = { [weak self] url, query in self?.openSearchPreview(url: url, query: query) }
        cleanupOldCaptures()
    }

    @objc private func openHistory() { history.open() }

    private var previewEditors: [EditorController] = []

    private func openSearchPreview(url: URL, query: String) {
        guard let image = NSImage(contentsOf: url) else { return }
        let e = EditorController(image: image, tool: .pen) { data in
            try? data.write(to: url)
        }
        e.onClosed = { [weak self, weak e] in
            self?.previewEditors.removeAll { $0 === e }
        }
        previewEditors.append(e)
        e.window.title = "Finding “\(query)”…"
        e.show()
        DispatchQueue.global(qos: .userInitiated).async {
            let rects = HistoryWindow.matchRects(in: url, query: query)
            DispatchQueue.main.async { e.showSearchHighlights(rects, query: query) }
        }
    }

    private func cleanupOldCaptures() {
        DispatchQueue.global(qos: .utility).async {
            let cutoff = Date().addingTimeInterval(-Double(autoCleanupDays) * 86400)
            for f in capturedFiles() {
                let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let d, d < cutoff { try? FileManager.default.removeItem(at: f) }
            }
        }
    }

    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func restartApp() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.5; /usr/bin/open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: - Global hotkeys (Carbon — no Accessibility permission needed)

    private func registerHotkeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // Dispatcher target, not application target — app target only delivers
        // hotkeys while the app is active, and an accessory app never is.
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let me = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            NSLog("SnapShelf hotkey fired: id=%d", hkID.id)
            DispatchQueue.main.async {
                hkID.id == 1 ? me.captureArea() : me.captureFull()
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)

        let sig = OSType(0x534E4150) // "SNAP"
        for (i, hk) in hotkeys.enumerated() {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(hk.keyCode), UInt32(hk.modifiers),
                                             EventHotKeyID(signature: sig, id: hk.id),
                                             GetEventDispatcherTarget(), 0, &ref)
            hotKeyRefs.append(ref)
            NSLog("SnapShelf hotkey %d (action %d) registered: %d (0 = ok)", i, hk.id, status)
        }
    }

    // MARK: - Capture

    @objc func captureArea() { runCapture(interactive: true) }
    @objc func captureFull() { runCapture(interactive: false) }

    private func runCapture(interactive: Bool) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Screenshot \(df.string(from: Date())).png"
        let url = saveDir.appendingPathComponent(name)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = (interactive ? ["-i"] : ["-m"]) + [url.path]
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                // Esc during area select → no file → nothing to show.
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                self?.showThumb(for: url)
            }
        }
        try? p.run()
    }

    // MARK: - Thumbnail shelf

    private func showThumb(for url: URL) {
        guard let image = NSImage(contentsOf: url), let screen = NSScreen.main else { return }

        // ponytail: new thumbs stack upward from bottom-left; gaps after dismissals
        // aren't repacked — restack logic when it bothers you.
        let stackedHeight = items.reduce(CGFloat(0)) { $0 + $1.panel.frame.height + 8 }
        let origin = NSPoint(x: screen.visibleFrame.minX + screenMargin,
                             y: screen.visibleFrame.minY + screenMargin + stackedHeight)

        let item = ShelfItem(url: url, image: image, origin: origin)
        item.onClosed = { [weak self] it in
            self?.items.removeAll { $0 === it }
        }
        item.panel.orderFrontRegardless()
        items.append(item)

        // Auto-copy: capture is on the clipboard immediately, no button needed.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image, url as NSURL])

        history.indexFile(url)   // searchable right away, no window reopen needed
    }

    // MARK: - Recent captures submenu (rebuilt each time the menu opens)

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let files = capturedFiles().prefix(10)
        if files.isEmpty {
            menu.addItem(NSMenuItem(title: "No captures yet", action: nil, keyEquivalent: ""))
        }
        for f in files {
            let mi = NSMenuItem(title: f.deletingPathExtension().lastPathComponent,
                                action: #selector(rePin(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = f
            if let img = NSImage(contentsOf: f) {
                let h: CGFloat = 32
                let w = max(h * img.size.width / max(img.size.height, 1), 8)
                let thumb = NSImage(size: NSSize(width: w, height: h))
                thumb.lockFocus()
                img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
                thumb.unlockFocus()
                mi.image = thumb
            }
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let folder = NSMenuItem(title: "Open Captures Folder", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
    }

    @objc private func rePin(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if let existing = items.first(where: { $0.url == url }) {
            existing.panel.orderFrontRegardless()
            return
        }
        showThumb(for: url)
    }

    @objc private func openFolder() { NSWorkspace.shared.open(saveDir) }

    @objc private func dismissAll() {
        for item in items { item.panel.orderOut(nil) }
        items.removeAll()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
