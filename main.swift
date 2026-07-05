// SnapShelf — minimal screenshot shelf for macOS.
// Hotkeys: ⇧⌘2 or ⌃⇧2 area capture, ⇧⌘1 or ⌃⇧1 full screen. Also via menu bar icon.
// Thumbnail floats bottom-left with a toolbar (Copy / Crop / Markup / ✕), stays until
// clicked. Drag the image into any window to drop the PNG.
// ponytail: capture delegates to /usr/sbin/screencapture, markup delegates to Preview —
// Apple's selection UI and markup editor for free. File watcher keeps the thumb in sync.

import Cocoa
import Carbon.HIToolbox

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

// MARK: - Image view: drag out, click to dismiss, crop selection

final class ThumbView: NSView, NSDraggingSource {
    var image: NSImage { didSet { layer?.contents = image } }
    let fileURL: URL
    var onDismiss: (() -> Void)?
    var onCrop: ((NSRect) -> Void)?
    var cropMode = false {
        didSet {
            selectionBox.isHidden = true
            window?.invalidateCursorRects(for: self)
        }
    }
    private let selectionBox = NSView()
    private var downPoint = NSPoint.zero
    private var dragging = false

    init(image: NSImage, fileURL: URL) {
        self.image = image
        self.fileURL = fileURL
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resizeAspectFill
        selectionBox.wantsLayer = true
        selectionBox.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        selectionBox.layer?.borderColor = NSColor.controlAccentColor.cgColor
        selectionBox.layer?.borderWidth = 1
        selectionBox.isHidden = true
        addSubview(selectionBox)
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if cropMode { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        dragging = false
        if cropMode {
            selectionBox.frame = NSRect(origin: downPoint, size: .zero)
            selectionBox.isHidden = false
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if cropMode {
            selectionBox.frame = rect(from: downPoint, to: p)
            return
        }
        guard !dragging, hypot(p.x - downPoint.x, p.y - downPoint.y) > 4 else { return }
        dragging = true
        // ponytail: drag payload is the file URL only — covers Finder, Slack, browsers,
        // mail, chat. Add an NSImage writer too if some app refuses file drops.
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if cropMode {
            let sel = selectionBox.frame
            selectionBox.isHidden = true
            if sel.width > 8, sel.height > 8 { onCrop?(sel) }
            return
        }
        if !dragging { onDismiss?() }   // click (no drag) dismisses
    }

    private func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
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
        thumbView.onCrop = { [weak self] r in self?.crop(viewRect: r) }

        copyBtn.onClick = { [weak self] in self?.copyToClipboard() }
        cropBtn.onClick = { [weak self] in self?.toggleCropMode() }
        markupBtn.onClick = { [weak self] in self?.openInPreview() }
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
        // Read from disk so markup edits saved in Preview are what gets copied.
        let current = NSImage(contentsOf: url) ?? image
        pb.writeObjects([current, url as NSURL])
        copyBtn.title = "Copied ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.copyBtn.title = "Copy"
            self?.copyBtn.sizeToFit()
        }
        copyBtn.sizeToFit()
    }

    private func toggleCropMode() {
        thumbView.cropMode.toggle()
        cropBtn.title = thumbView.cropMode ? "Cancel" : "Crop"
        cropBtn.sizeToFit()
    }

    private func openInPreview() {
        NSWorkspace.shared.open([url],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Preview.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private func crop(viewRect r: NSRect) {
        thumbView.cropMode = false
        cropBtn.title = "Crop"
        cropBtn.sizeToFit()

        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let vs = thumbView.bounds.size
        let sx = CGFloat(cg.width) / max(vs.width, 1)
        let sy = CGFloat(cg.height) / max(vs.height, 1)
        // View coords are bottom-left origin, CGImage crop is top-left origin — flip y.
        let pixelRect = CGRect(x: r.minX * sx,
                               y: (vs.height - r.maxY) * sy,
                               width: r.width * sx,
                               height: r.height * sy).integral
        guard pixelRect.width > 4, pixelRect.height > 4, let cropped = cg.cropping(to: pixelRect),
              let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)   // watcher picks this up → thumb reloads + panel refits
    }

    private func close() {
        watcher?.cancel()
        watcher = nil
        panel.orderOut(nil)
        onClosed?(self)
    }

    // MARK: File watcher — Preview saves land back on the thumbnail

    private func startWatching() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, let w = self.watcher else { return }
            let flags = w.data
            // Atomic saves (Preview) replace the file: re-arm the watch on the new inode.
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
        menu.addItem(area)
        menu.addItem(full)
        menu.addItem(.separator())
        menu.addItem(clear)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SnapShelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        registerHotkeys()
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
