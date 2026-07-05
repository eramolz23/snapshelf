// SnapShelf — minimal screenshot shelf for macOS.
// Hotkeys: ⇧⌘2 or ⌃⇧2 area capture, ⇧⌘1 or ⌃⇧1 full screen. Also via menu bar icon.
// Thumbnail floats bottom-left with a toolbar (Copy / Crop / Markup / ✕), stays until
// clicked. Drag the image into any window to drop the PNG. Markup/Crop open a big
// centered in-app editor: pen, arrow, box, text, color, undo, crop.
// ponytail: capture delegates to /usr/sbin/screencapture — Apple's selection UI for free.

import Cocoa
import Carbon.HIToolbox
import ServiceManagement

private let maxThumbWidth: CGFloat = 320
private let screenMargin: CGFloat = 16

// Hotkeys — edit here, rebuild with build.sh. id 1 = area capture, id 2 = full screen.
// Two combos per action: ⇧⌘ (matches system screenshot muscle memory) and ⌃⇧ (conflict-free fallback).
private let hotkeys: [(keyCode: Int, modifiers: Int, id: UInt32)] = [
    (kVK_ANSI_2, cmdKey | shiftKey, 1),
    (kVK_ANSI_1, cmdKey | shiftKey, 2),
    (kVK_ANSI_2, controlKey | shiftKey, 1),
    (kVK_ANSI_1, controlKey | shiftKey, 2),
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

enum Tool: Int { case pen = 0, arrow, box, text, crop }

enum Annotation {
    case pen([NSPoint], NSColor)
    case arrow(NSPoint, NSPoint, NSColor)
    case box(NSRect, NSColor)
    case text(String, NSPoint, NSColor, CGFloat)

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
        }
    }

    func translated(by d: NSPoint) -> Annotation {
        func t(_ p: NSPoint) -> NSPoint { NSPoint(x: p.x + d.x, y: p.y + d.y) }
        switch self {
        case .pen(let pts, let c): return .pen(pts.map(t), c)
        case .arrow(let a, let b, let c): return .arrow(t(a), t(b), c)
        case .box(let r, let c): return .box(NSRect(origin: t(r.origin), size: r.size), c)
        case .text(let s, let p, let c, let f): return .text(s, t(p), c, f)
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
    var annotations: [Annotation] = [] { didSet { needsDisplay = true } }
    var tool: Tool = .pen
    var color: NSColor = .systemRed
    var onTextRequest: ((NSPoint) -> Void)?   // image-point where user clicked with text tool

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
        let lw = Self.strokeWidth(for: image)
        for a in annotations { a.draw(lineWidth: lw) }
        if currentPen.count > 1 { Annotation.pen(currentPen, color).draw(lineWidth: lw) }
        if let s = dragStart, let c = dragCurrent {
            let r = rect(from: s, to: c)
            switch tool {
            case .arrow: Annotation.arrow(s, c, color).draw(lineWidth: lw)
            case .box: Annotation.box(r, color).draw(lineWidth: lw)
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
        case .pen: currentPen = [p]
        default: dragStart = p; dragCurrent = p
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = toImage(event)
        if tool == .pen { currentPen.append(p) } else { dragCurrent = p }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { currentPen = []; dragStart = nil; dragCurrent = nil; needsDisplay = true }
        let p = toImage(event)
        switch tool {
        case .pen:
            if currentPen.count > 1 { annotations.append(.pen(currentPen, color)) }
        case .arrow:
            if let s = dragStart, hypot(p.x - s.x, p.y - s.y) * viewScale > 6 {
                annotations.append(.arrow(s, p, color))
            }
        case .box:
            if let s = dragStart {
                let r = rect(from: s, to: p)
                if r.width * viewScale > 6, r.height * viewScale > 6 { annotations.append(.box(r, color)) }
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

    func undo() {
        _ = annotations.popLast()
        needsDisplay = true
    }

    // Crop is immediate and destructive within the session (Cancel still discards all).
    private func applyCrop(imageRect r: NSRect) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let s = CGFloat(cg.width) / max(image.size.width, 1)
        let px = CGRect(x: r.minX * s, y: (image.size.height - r.maxY) * s,
                        width: r.width * s, height: r.height * s).integral
        guard px.width > 2, px.height > 2, let cropped = cg.cropping(to: px) else { return }
        image = NSImage(cgImage: cropped, size: NSSize(width: px.width / s, height: px.height / s))
        annotations = annotations.map { $0.translated(by: NSPoint(x: -r.minX, y: -r.minY)) }
    }

    private func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
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
        let lw = Self.strokeWidth(for: image)
        for a in annotations { a.draw(lineWidth: lw) }
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Editor window: centered, big, toolbar of tools + Done/Cancel

final class EditorController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let window: NSWindow
    private let canvas: EditorCanvas
    private let toolPicker: NSSegmentedControl
    private let colorWell = NSColorWell()
    private let onSave: (Data) -> Void
    private var activeField: NSTextField?
    private var pendingTextPoint = NSPoint.zero
    var onClosed: (() -> Void)?

    init(image: NSImage, tool: Tool, onSave: @escaping (Data) -> Void) {
        self.onSave = onSave
        canvas = EditorCanvas(image: image)
        canvas.tool = tool
        toolPicker = NSSegmentedControl(labels: ["Pen", "Arrow", "Box", "Text", "Crop"],
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
                                        barItems: [toolPicker, colorWell, undoBtn],
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

    private func saveAndClose() {
        commitActiveField()
        if let data = canvas.renderPNG() { onSave(data) }
        window.close()
    }

    @objc private func toolChanged() {
        commitActiveField()
        canvas.tool = Tool(rawValue: toolPicker.selectedSegment) ?? .pen
        window.makeFirstResponder(canvas)
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
        canvas.annotations.append(.text(text, pendingTextPoint, canvas.color,
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
    var onDismiss: (() -> Void)?
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
        if !dragging { onDismiss?() }   // click (no drag) dismisses
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
    private let cropBtn = ActionButton(title: "Crop")
    private let markupBtn = ActionButton(title: "Markup")
    private let closeBtn = ActionButton(title: "✕")
    private var watcher: DispatchSourceFileSystemObject?
    private var editor: EditorController?

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

        thumbView.onDismiss = { [weak self] in self?.close() }
        copyBtn.onClick = { [weak self] in self?.copyToClipboard() }
        cropBtn.onClick = { [weak self] in self?.openEditor(tool: .crop) }
        markupBtn.onClick = { [weak self] in self?.openEditor(tool: .pen) }
        closeBtn.onClick = { [weak self] in self?.close() }

        container.addSubview(thumbView)
        [copyBtn, cropBtn, markupBtn, closeBtn].forEach { bar.addSubview($0) }
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
        for btn in [copyBtn, cropBtn, markupBtn] {
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
        e.onClosed = { [weak self] in self?.editor = nil }
        editor = e
        e.show()
    }

    func close() {
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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var items: [ShelfItem] = []
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder",
                                           accessibilityDescription: "SnapShelf")
        let menu = NSMenu()
        let area = NSMenuItem(title: "Capture Area", action: #selector(captureArea), keyEquivalent: "2")
        area.keyEquivalentModifierMask = [.command, .shift]
        area.target = self
        let full = NSMenuItem(title: "Capture Full Screen", action: #selector(captureFull), keyEquivalent: "1")
        full.keyEquivalentModifierMask = [.command, .shift]
        full.target = self
        let clear = NSMenuItem(title: "Dismiss All Thumbnails", action: #selector(dismissAll), keyEquivalent: "")
        clear.target = self
        let restart = NSMenuItem(title: "Restart SnapShelf", action: #selector(restartApp), keyEquivalent: "r")
        restart.target = self
        loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(area)
        menu.addItem(full)
        menu.addItem(.separator())
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)

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
    }

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
