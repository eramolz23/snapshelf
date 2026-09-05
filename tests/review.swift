
// A native review app with the real editor/shelf/history and synthetic files only.
// Deliberately does not call AppDelegate.applicationDidFinishLaunching: no hotkeys,
// capture, login registration, user capture directory, or general pasteboard access.
extension AppDelegate {
    func reviewPin(_ url: URL) { showThumb(for: url) }
    func reviewEdit(_ url: URL) { openEditor(url: url, tool: .pen) }
    func reviewDismiss() { dismissAll() }
    func reviewHistory() { history.open() }
}

final class ReviewLauncher: NSObject, NSApplicationDelegate {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SnapShelf-native-review-\(UUID().uuidString)")
    private let pasteboard = NSPasteboard(name: .init("SnapShelf-native-review-\(UUID().uuidString)"))
    private var controller: AppDelegate!
    private var normal: URL { directory.appendingPathComponent("Normal.png") }
    private var narrow: URL { directory.appendingPathComponent("Narrow.png") }
    private var tall: URL { directory.appendingPathComponent("Tall.png") }
    private var held: URL { directory.appendingPathComponent("Normal.held") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try fixture(size: NSSize(width: 900, height: 540), title: "Synthetic customer report").write(to: normal)
            try fixture(size: NSSize(width: 80, height: 240), title: "NARROW").write(to: narrow)
            try fixture(size: NSSize(width: 140, height: 2200), title: "TALL").write(to: tall)
            controller = AppDelegate(directory: directory, pasteboard: pasteboard)
            setupMenu()
            pinFixtures()
            editNormal()
            NSLog("SnapShelf review fixtures: %@; pasteboard: %@", directory.path, pasteboard.name.rawValue)
        } catch { NSLog("Review fixture setup failed: %@", error.localizedDescription); NSApp.terminate(nil) }
    }

    private func fixture(size: NSSize, title: String) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                      pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(calibratedRed: 0.12, green: 0.3, blue: 0.45, alpha: 1).setFill()
        NSRect(x: 0, y: size.height - 16, width: size.width, height: 16).fill()
        func text(_ string: String, x: CGFloat, y: CGFloat, font: CGFloat, color: NSColor = .black) {
            NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: font),
                                                           .foregroundColor: color]).draw(at: NSPoint(x: x, y: y))
        }
        if size.width > 300 {
            text("SNAPSHELF / NATIVE REVIEW", x: 40, y: size.height - 66, font: 15, color: .darkGray)
            text(title, x: 40, y: size.height - 115, font: 32)
            text("All content in this window is generated test data.", x: 40, y: size.height - 155, font: 21)
            NSColor.white.setFill()
            NSRect(x: 40, y: 160, width: size.width - 80, height: 155).fill()
            text("SYNTHETIC SECRET: ORANGE-42", x: 62, y: 260, font: 26)
            text("Use Redact to cover this line, then Done to save.", x: 62, y: 214, font: 22)
            text("Try Pen, Arrow, Box, Text, Blur, Crop and Undo.", x: 40, y: 108, font: 21)
            text("Review menu: History, dismiss, re-pin and a reversible save failure.", x: 40, y: 66, font: 19)
        } else {
            text(title, x: 8, y: size.height - 48, font: 13)
            for y in stride(from: 20, to: Int(size.height - 70), by: 45) {
                NSColor(calibratedRed: 0.2, green: 0.5, blue: 0.7, alpha: 1).setFill()
                NSRect(x: 8, y: CGFloat(y), width: size.width - 16, height: 18).fill()
            }
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }

    private func setupMenu() {
        let menu = NSMenu()
        let appMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "Quit SnapShelf Review", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.addItem(appItem)
        let controls = NSMenu(title: "Review")
        let controlsItem = NSMenuItem(title: "Review", action: nil, keyEquivalent: "")
        controlsItem.submenu = controls
        let actions: [(String, Selector)] = [
            ("Open Normal Editor", #selector(editNormal)),
            ("Open Narrow Editor", #selector(editNarrow)),
            ("Open Tall Editor", #selector(editTall)),
            ("Re-pin Fixtures", #selector(pinFixtures)),
            ("Dismiss All Thumbnails", #selector(dismiss)),
            ("History", #selector(history)),
            ("Make Normal Save Fail (move fixture aside)", #selector(failSave)),
            ("Restore Normal Save Destination", #selector(restoreSave)),
        ]
        for (title, action) in actions {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            controls.addItem(item)
        }
        menu.addItem(controlsItem)
        NSApp.mainMenu = menu
    }

    @objc private func editNormal() { controller.reviewEdit(normal) }
    @objc private func editNarrow() { controller.reviewEdit(narrow) }
    @objc private func editTall() { controller.reviewEdit(tall) }
    @objc private func pinFixtures() {
        [normal, narrow, tall].forEach { controller.reviewPin($0) }
    }
    @objc private func dismiss() { controller.reviewDismiss() }
    @objc private func history() { controller.reviewHistory() }
    @objc private func failSave() {
        editNormal()
        do { try FileManager.default.moveItem(at: normal, to: held) }
        catch { NSLog("Review move failed: %@", error.localizedDescription) }
    }
    @objc private func restoreSave() {
        do { try FileManager.default.moveItem(at: held, to: normal) }
        catch { NSLog("Review restore failed: %@", error.localizedDescription) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.reviewDismiss()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }
}

let reviewApp = NSApplication.shared
let reviewLauncher = ReviewLauncher()
reviewApp.delegate = reviewLauncher
reviewApp.setActivationPolicy(.regular)
reviewApp.run()
