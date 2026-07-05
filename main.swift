// SnapShelf — minimal screenshot shelf for macOS.
// Hotkeys: ⇧⌘2 or ⌃⇧2 area capture, ⇧⌘1 or ⌃⇧1 full screen. Also via menu bar icon.
// Thumbnail floats bottom-left, stays until clicked. Copy button. Drag it into any window.
// ponytail: capture delegates to /usr/sbin/screencapture — Apple's selection UI for free.

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
    }
    @objc private func clicked() { onClick?() }
}

final class ThumbView: NSView, NSDraggingSource {
    private let image: NSImage
    private let fileURL: URL
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
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging else { return }
        let p = event.locationInWindow
        guard hypot(p.x - downPoint.x, p.y - downPoint.y) > 4 else { return }
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panels: [NSPanel] = []
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

        let scale = min(1, maxThumbWidth / max(image.size.width, 1))
        let size = NSSize(width: max(image.size.width * scale, 60),
                          height: max(image.size.height * scale, 40))
        // ponytail: new thumbs stack upward from bottom-left; gaps after dismissals
        // aren't repacked — restack logic when it bothers you.
        let stackedHeight = panels.reduce(CGFloat(0)) { $0 + $1.frame.height + 8 }
        let origin = NSPoint(x: screen.visibleFrame.minX + screenMargin,
                             y: screen.visibleFrame.minY + screenMargin + stackedHeight)

        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let thumb = ThumbView(image: image, fileURL: url)
        thumb.frame = NSRect(origin: .zero, size: size)
        thumb.autoresizingMask = [.width, .height]
        thumb.onDismiss = { [weak self, weak panel] in
            guard let self, let panel else { return }
            panel.orderOut(nil)
            self.panels.removeAll { $0 === panel }
        }

        let copyBtn = ActionButton(title: "Copy")
        copyBtn.bezelStyle = .rounded
        copyBtn.controlSize = .small
        copyBtn.font = .systemFont(ofSize: 11)
        copyBtn.sizeToFit()
        copyBtn.frame.origin = NSPoint(x: size.width - copyBtn.frame.width - 6,
                                       y: size.height - copyBtn.frame.height - 6)
        copyBtn.autoresizingMask = [.minXMargin, .minYMargin]
        copyBtn.onClick = { [weak copyBtn] in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image, url as NSURL])
            copyBtn?.title = "Copied ✓"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copyBtn?.title = "Copy" }
        }

        thumb.addSubview(copyBtn)
        panel.contentView = thumb
        panel.orderFrontRegardless()
        panels.append(panel)
    }

    @objc private func dismissAll() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
