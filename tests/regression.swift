
// AppKit runs only against generated images, temporary files and a named pasteboard.
var failures = 0
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    do {
        if try condition() { print("PASS: \(message)") }
        else { failures += 1; print("FAIL: \(message)") }
    } catch { failures += 1; print("FAIL: \(message): \(error)") }
}

extension EditorController {
    func attemptTestSave() { saveAndClose() }
    func testMark(_ annotation: Annotation) { canvas.addMark(annotation) }
    var testHighlights: [NSRect] { canvas.searchHighlights }
    func testUndo() { canvas.undo() }
    func testCrop(_ rect: NSRect) { canvas.testCrop(rect) }
    func testButton(_ title: String) -> NSButton? { findButton(title, in: window.contentView) }
    func testBeginText(at point: NSPoint) { beginText(at: point) }
    var testActiveField: NSTextField? { activeField }
    var testMarkCount: Int { canvas.marks.count }
    var testCanvasFocused: Bool { window.firstResponder === canvas }
}

func findButton(_ title: String, in view: NSView?) -> NSButton? {
    guard let view else { return nil }
    if let button = view as? NSButton, button.title == title { return button }
    for sub in view.subviews { if let found = findButton(title, in: sub) { return found } }
    return nil
}

extension EditorCanvas {
    func testCrop(_ rect: NSRect) { applyCrop(imageRect: rect) }
    func testPixelTile(_ rect: NSRect) -> NSImage? { pixelTile(for: rect) }
}

extension ShelfItem {
    var testWatching: Bool { watcher != nil }
    var testClosed: Bool { closed }
    var testImageSize: NSSize { imageSize }
    var testBarMinWidth: CGFloat { barMinWidth }
    var testToolbarImages: [NSImage?] { buttons.map(\.image) }
    var testButtons: [ActionButton] { buttons }
    var testBar: HoverBar { bar }
    func testHover(_ on: Bool) { setHover(on) }
    func testHit(_ point: NSPoint) -> NSView? { panel.contentView?.hitTest(point) }
    var testThumb: NSView { thumbView }
}

extension AppDelegate {
    func testPin(_ url: URL) { showThumb(for: url) }
    func testEdit(_ url: URL) { openEditor(url: url, tool: .pen) }
    func testPreview(_ url: URL) { openSearchPreview(url: url, query: "synthetic") }
    func testDismiss() { dismissAll() }
    func testSave(_ data: Data, to url: URL) throws { try saveCapture(data, to: url) }
    var testEditors: [URL: EditorController] { editors }
    var testItems: [ShelfItem] { items }
    func testRestart() { restartApp() }
}

extension HistoryWindow {
    func testReload() { reload() }
    func testSearch(_ query: String) { search.stringValue = query; reload() }
    var testCells: [NSView] { grid.subviews }
}

func fixture(_ color: NSColor, size: NSSize = NSSize(width: 100, height: 80)) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                  pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = size
    let rgb = color.usingColorSpace(.genericRGB)!
    let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
        .map { UInt8((min(1, max(0, $0)) * 255).rounded()) }
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            for channel in 0..<4 { bitmap.bitmapData![y * bitmap.bytesPerRow + x * 4 + channel] = components[channel] }
        }
    }
    return bitmap.representation(using: .png, properties: [:])!
}

func pixel(_ data: Data, x: Int? = nil, y: Int? = nil) -> NSColor {
    let bitmap = NSBitmapImageRep(data: data)!
    return bitmap.colorAt(x: x ?? bitmap.pixelsWide / 2, y: y ?? bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
}

func drain(_ seconds: TimeInterval = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

@discardableResult
func waitUntil(_ message: String, timeout: TimeInterval = 5, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline { drain(0.01) }
    let success = predicate()
    check(success, message)
    return success
}

// The OCR implementation is the one asynchronous boundary controlled by tests.
// Workers still read file revisions and complete through the production main queue.
final class OCRGate {
    final class Job {
        let ready = DispatchSemaphore(value: 0)
        var text = ""
    }
    private let lock = NSLock()
    private var jobs: [Job] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return jobs.count }
    func recognize(_ url: URL) -> String? {
        let job = Job()
        lock.lock(); jobs.append(job); lock.unlock()
        guard job.ready.wait(timeout: .now() + 10) == .success else { return nil }
        return job.text
    }
    func finish(_ index: Int, text: String) {
        lock.lock(); let job = jobs[index]; lock.unlock()
        job.text = text
        job.ready.signal()
    }
}

let testApp = NSApplication.shared
testApp.setActivationPolicy(.accessory)
var closedAfterFailedRender = false
let invalidEditor = EditorController(image: NSImage(size: .zero), tool: .pen) { _ in }
var renderErrorShown = false
invalidEditor.onSaveError = { _ in renderErrorShown = true }
invalidEditor.onClosed = { closedAfterFailedRender = true }
invalidEditor.testMark(.box(NSRect(x: 0, y: 0, width: 1, height: 1), .red))   // Done with no edits just closes
invalidEditor.attemptTestSave()
check(!closedAfterFailedRender, "failed rendering retains the editor")
check(renderErrorShown, "failed rendering reports the save error")
invalidEditor.close()

let tall = ShelfItem.thumbSize(for: NSSize(width: 100, height: 10000))
check(tall.height <= 165, "tall screenshots have a bounded thumbnail height")
check(ShelfItem.thumbSize(for: NSSize(width: 2000, height: 1000)).width <= 220,
      "wide screenshots retain the existing width bound")

let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnapShelf-regression-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let url = root.appendingPathComponent("fixture.png")
let other = root.appendingPathComponent("other.png")
let red = fixture(.red), blue = fixture(.blue)
let renderedRetina = EditorCanvas(image: NSImage(data: red)!).renderPNG()!
check(pixel(renderedRetina, x: 190, y: 10).redComponent > 0.9 && pixel(renderedRetina, x: 190, y: 10).alphaComponent > 0.99,
      "Retina rendering fills the full pixel bitmap, including the top-right corner")
try red.write(to: url)
try blue.write(to: other)
let pb = NSPasteboard(name: .init("SnapShelf-regression-\(UUID().uuidString)"))
defer { pb.releaseGlobally() }
let clipboard = CaptureClipboard(pasteboard: pb)

// Every SF Symbol main.swift uses (toolbar + transient states); a typo renders an empty button.
let toolbarSymbols = ["doc.on.doc", "text.viewfinder", "crop", "pencil.tip.crop.circle", "link", "xmark",
                      "checkmark", "ellipsis", "arrow.clockwise", "text.badge.xmark", "exclamationmark.triangle",
                      "arrow.up.circle.fill"]
for symbol in toolbarSymbols {
    check(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "SF Symbol \(symbol) resolves")
}
// Own subdirectory: the OCR-index tests below enumerate every PNG directly under root.
let thumbRoot = root.appendingPathComponent("thumbs")
try FileManager.default.createDirectory(at: thumbRoot, withIntermediateDirectories: true)
let wideURL = thumbRoot.appendingPathComponent("wide.png"), narrowURL = thumbRoot.appendingPathComponent("narrow.png")
let wideData = fixture(.green, size: NSSize(width: 1400, height: 880))
let narrowData = fixture(.green, size: NSSize(width: 80, height: 240))
try wideData.write(to: wideURL)
try narrowData.write(to: narrowURL)
let wideItem = ShelfItem(url: wideURL, image: NSImage(data: wideData)!, origin: .zero, clipboard: clipboard)
let narrowItem = ShelfItem(url: narrowURL, image: NSImage(data: narrowData)!, origin: .zero, clipboard: clipboard)
check(wideItem.testToolbarImages.allSatisfy { $0 != nil }, "every toolbar button shows a symbol")
check(wideItem.testBarMinWidth <= 220, "icon row fits within the maximum thumbnail width")
check(wideItem.panel.frame.width <= 220, "wide screenshot panel stays within 220pt")
check(wideItem.panel.frame.height <= 165, "wide screenshot card (no bar strip) stays within 165pt tall")
check(narrowItem.panel.frame.height <= 165, "tall screenshot card (no bar strip) stays within 165pt tall")
check(narrowItem.panel.frame.width >= max(170, narrowItem.testBarMinWidth), "narrow screenshot panel still fits the whole icon row")

// Hover controls: hidden when idle, fade in over the top of the card, buttons only take clicks.
HoverBar.fadeDuration = 0
let bar = wideItem.testBar, buttons = wideItem.testButtons, card = wideItem.panel.frame.size
check(bar.alphaValue == 0 && !bar.shown, "controls start hidden")
check(bar.frame.maxY == card.height && bar.frame.width == card.width && bar.frame.height == 58,
      "fade covers the top 58pt of the card at full width")
check(buttons.allSatisfy { bar.frame.contains(bar.convert($0.frame, to: wideItem.panel.contentView).insetBy(dx: 0.5, dy: 0.5)) }
      && buttons.last!.frame.maxX <= card.width, "all six icons sit inside the fade, ✕ at the right end")
let gradientGap = NSPoint(x: 6 + 26 + 2, y: card.height - 15)             // between Copy and OCR
let gradientLow = NSPoint(x: card.width / 2, y: card.height - 50)         // below the icon row
func center(_ b: NSView) -> NSPoint { wideItem.panel.contentView!.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), from: b) }
check(wideItem.testHit(center(buttons[0])) === wideItem.testThumb, "hidden controls never take clicks: the image does")
wideItem.testHover(true)
check(bar.shown && bar.alphaValue == 1, "mouse over the card shows the controls")
let fadeRep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds)!
bar.cacheDisplay(in: bar.bounds, to: fadeRep)
func fadeAlpha(_ y: Int) -> CGFloat { fadeRep.colorAt(x: fadeRep.pixelsWide / 2, y: y)!.alphaComponent }   // y 0 = top
check(fadeAlpha(0) > 0.78 && abs(fadeAlpha(fadeRep.pixelsHigh / 2) - 0.55) < 0.05 && fadeAlpha(fadeRep.pixelsHigh - 1) < 0.05,
      "fade is dark at the top of the card and transparent at the bottom of its band")
check(wideItem.testHit(gradientGap) === wideItem.testThumb, "click in the fade between icons reaches the image")
check(wideItem.testHit(gradientLow) === wideItem.testThumb, "click low in the fade reaches the image")
check(buttons.indices.allSatisfy { wideItem.testHit(center(buttons[$0])) === buttons[$0] }, "icon centers hit their buttons")
wideItem.testHover(false)
check(!bar.shown && bar.alphaValue == 0, "mouse leaving hides the controls")
// Feedback keeps the controls up after the mouse leaves; Retry is a standing state, not feedback.
wideItem.testHover(true)
buttons[0].setSymbol("checkmark", label: "Copied")
wideItem.testHover(false)
check(bar.shown, "copy feedback keeps the controls visible after the mouse leaves")
buttons[4].setSymbol("ellipsis", label: "Working…")
buttons[0].setSymbol("doc.on.doc", label: "Copy")
check(bar.shown, "controls stay while another button still shows feedback")
buttons[4].setSymbol("link", label: "Share Link (72h)")
check(!bar.shown && bar.alphaValue == 0, "controls hide once all feedback has reset and the mouse is outside")
buttons[1].setSymbol("arrow.clockwise", label: "Retry OCR")
check(!bar.shown, "the standing Retry OCR icon does not pin the controls")
buttons[1].setSymbol("text.viewfinder", label: "Copy Text (OCR)")
wideItem.testHover(true)
buttons[0].setSymbol("checkmark", label: "Copied")
buttons[0].setSymbol("doc.on.doc", label: "Copy")
check(bar.shown, "feedback ending while the mouse is over the card leaves the controls up")
wideItem.testHover(false)
// Share Link is two-step: the first click only arms; a second click while armed uploads.
ShelfItem.linkArmSeconds = 0.2
var linkUploads = 0
let linkButton = buttons[4]
wideItem.uploadLink = { linkUploads += 1; linkButton.setSymbol("link", label: "Share Link (72h)") }
linkButton.performClick(nil)
check(linkUploads == 0 && linkButton.symbol == ShelfItem.armedLinkSymbol
      && linkButton.toolTip == "Click again to upload a public link", "one Share Link click arms without uploading")
check(bar.shown, "armed Share Link keeps the controls visible after the mouse leaves")
linkButton.performClick(nil)
check(linkUploads == 1, "a second Share Link click while armed uploads")
linkButton.performClick(nil)
waitUntil("Share Link arming expires back to the idle icon", { linkButton.symbol == "link" })
check(linkUploads == 1 && !bar.shown, "an expired arm uploads nothing and releases the controls")
linkButton.performClick(nil)
check(linkUploads == 1 && linkButton.symbol == ShelfItem.armedLinkSymbol, "a click after the arm expired only re-arms")
waitUntil("re-armed Share Link expires", { linkButton.symbol == "link" })
let linkOK = ShelfItem.shareResult(link: "https://x.test/a.png", status: 200, fileUnchanged: true, clipboardUnchanged: true)
check(linkOK.copy && linkOK.symbol == "checkmark", "unchanged file and clipboard copy the uploaded link")
let linkChanged = ShelfItem.shareResult(link: "https://x.test/a.png", status: 200, fileUnchanged: false, clipboardUnchanged: true)
check(!linkChanged.copy && linkChanged.symbol == "exclamationmark.triangle"
      && linkChanged.label == "File changed during upload — link not copied", "file changed during upload says so and copies nothing")
let linkFailed = ShelfItem.shareResult(link: nil, status: nil, fileUnchanged: true, clipboardUnchanged: true)
check(!linkFailed.copy && linkFailed.label == "Upload failed", "network failure still reports Upload failed")
wideItem.close()
narrowItem.close()
clipboard.copy(url)
let oldCount = pb.changeCount
try CaptureFiles.save(blue, to: url)
clipboard.refreshAfterSave(url)
check(pb.changeCount > oldCount, "successful save replaces the owned image pasteboard")
check(pixel(pb.data(forType: .tiff)!).blueComponent > 0.9, "clipboard pixels are the edited blue image")
clipboard.copy(other)
let otherCount = pb.changeCount
try CaptureFiles.save(red, to: url)
clipboard.refreshAfterSave(url)
check(pb.changeCount == otherCount, "editing an older capture preserves a newer capture clipboard")
clipboard.copy(url)
pb.clearContents(); pb.setString("another app", forType: .string)
clipboard.refreshAfterSave(url)
check(pb.string(forType: .string) == "another app", "saving preserves an intervening application clipboard")
clipboard.copyText("OCR secret", from: url)
try CaptureFiles.save(blue, to: url)
clipboard.refreshAfterSave(url)
check(pb.string(forType: .string) != "OCR secret", "owned OCR text is cleared after the capture changes")

var saveFailed = false
var closedAfterFailedWrite = false
let failedEditor = EditorController(image: NSImage(data: red)!, tool: .pen) { data in
    try CaptureFiles.save(data, to: root.appendingPathComponent("missing.png"))
}
failedEditor.onSaveError = { _ in saveFailed = true }
failedEditor.onClosed = { closedAfterFailedWrite = true }
failedEditor.testMark(.box(NSRect(x: 10, y: 10, width: 20, height: 20), .blue))   // Done with no edits just closes
failedEditor.attemptTestSave()
check(saveFailed && !closedAfterFailedWrite, "missing destination reports failure and keeps the editor open")
check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing.png").path),
      "saving a deleted screenshot does not resurrect it")
failedEditor.close()

let readOnly = root.appendingPathComponent("readonly", isDirectory: true)
try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
let protectedFile = readOnly.appendingPathComponent("original.png")
try red.write(to: protectedFile)
try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
do {
    try CaptureFiles.save(blue, to: protectedFile)
    check(false, "atomic write fails in an unwritable directory")
} catch {
    check((try? Data(contentsOf: protectedFile)) == red, "failed atomic replacement preserves original PNG bytes")
}
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path)

let area = NSRect(x: -1920, y: 200, width: 1000, height: 700)
let sizes = [NSSize](repeating: NSSize(width: 320, height: 190), count: 3)
let before = ShelfItem.frames(for: sizes, in: area).compactMap { $0 }
let after = ShelfItem.frames(for: [sizes[0], sizes[2]], in: area).compactMap { $0 }
check(before.count == 3 && after.count == 2 && after[1].minY == after[0].maxY + 8,
      "dismissing a middle thumbnail packs the remaining shelf without gaps")
let overflow = ShelfItem.frames(for: Array(repeating: sizes[0], count: 20), in: area)
check(overflow.compactMap { $0 }.allSatisfy { area.contains($0) } && overflow.last! != nil,
      "overflow hides older thumbnails while keeping the latest on screen")
check(zip(before, before.dropFirst()).allSatisfy { !$0.intersects($1) }, "shelf thumbnails never overlap")
check(ShelfItem.frames(for: [], in: area).isEmpty, "empty shelf layout is safe")

let date = Date(timeIntervalSince1970: 1000)
let destinations = (0..<100).map { _ in CaptureFiles.destination(in: root, date: date) }
check(Set(destinations).count == destinations.count, "100 captures in the same second have unique filenames")
check(!CaptureFiles.succeeded(at: url, status: 1, reason: .exit), "failed capture cannot show an existing PNG")
check(!CaptureFiles.succeeded(at: url, status: 0, reason: .uncaughtSignal), "terminated capture is rejected")
check(!CaptureFiles.succeeded(at: destinations[0], status: 0, reason: .exit), "canceled capture with no output is rejected")
check(CaptureFiles.succeeded(at: url, status: 0, reason: .exit), "successful capture requires a readable image")

let suiteName = "SnapShelf-regression-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defer { defaults.removePersistentDomain(forName: suiteName) }
check(!LoginPreference.registerOnLaunch(defaults: defaults, status: .notRegistered),
      "migration preserves an existing Start at Login off state")
defaults.set(true, forKey: LoginPreference.key)
check(LoginPreference.registerOnLaunch(defaults: defaults, status: .notRegistered), "explicit login opt-in is restored on launch")
defaults.set(false, forKey: LoginPreference.key)
let relaunchedDefaults = UserDefaults(suiteName: suiteName)!
check(!LoginPreference.registerOnLaunch(defaults: relaunchedDefaults, status: .notRegistered),
      "explicit login opt-out survives a new defaults instance")

let canvas = EditorCanvas(image: NSImage(data: red)!)
canvas.addMark(.redact(NSRect(x: 20, y: 20, width: 60, height: 40)))
let masked = pixel(canvas.renderPNG()!)
check(masked.redComponent < 0.01 && masked.greenComponent < 0.01 && masked.blueComponent < 0.01 && masked.alphaComponent > 0.99,
      "redaction produces opaque black pixels")
let redactedRegion = NSRect(x: 20, y: 20, width: 60, height: 40)
let afterBlur = canvas.testPixelTile(redactedRegion)!
check(pixel(afterBlur.tiffRepresentation!).redComponent < 0.01,
      "blurring a redacted region samples the redaction instead of revealing the original")
canvas.testCrop(NSRect(x: 10, y: 10, width: 80, height: 60))
if case .redact(let rect) = canvas.marks[0].a {
    check(rect.origin == NSPoint(x: 10, y: 10), "crop translates redaction coordinates with other marks")
} else { check(false, "redaction annotation survives crop") }
canvas.undo()
check(canvas.image.size == NSImage(data: red)!.size && canvas.marks.count == 1, "crop undo restores image and annotations")
canvas.undo()
check(canvas.marks.isEmpty && pixel(canvas.renderPNG()!).redComponent > 0.9, "redaction undo restores the original pixels")
let beforeHighlight = canvas.renderPNG()!
canvas.searchHighlights = [NSRect(x: 0, y: 0, width: 100, height: 80)]
check(canvas.renderPNG() == beforeHighlight,
      "search highlighting remains absent from saved PNGs")
let plain = EditorCanvas(image: NSImage(data: red)!)
let plainData = plain.renderPNG()!
let oldTools: [(String, Annotation)] = [
    ("pen", .pen([NSPoint(x: 5, y: 5), NSPoint(x: 90, y: 70)], .black)),
    ("highlight", .highlight([NSPoint(x: 5, y: 40), NSPoint(x: 90, y: 40)], .yellow)),
    ("arrow", .arrow(NSPoint(x: 5, y: 5), NSPoint(x: 90, y: 70), .black)),
    ("box", .box(NSRect(x: 10, y: 10, width: 80, height: 60), .black)),
    ("text", .text("Test", NSPoint(x: 20, y: 30), .black, 18)),
    ("blur", .blur(NSRect(x: 20, y: 20, width: 60, height: 40), NSImage(data: blue)!)),
]
for (name, mark) in oldTools {
    plain.addMark(mark)
    check(plain.renderPNG() != plainData, "existing \(name) tool changes saved pixels")
    plain.undo()
    check(plain.renderPNG() == plainData, "existing \(name) undo restores the original PNG")
}
plain.addMark(.box(NSRect(x: 5, y: 5, width: 20, height: 20), .black))
plain.testCrop(NSRect(x: -20, y: -20, width: 80, height: 80))
if case .box(let rect, _) = plain.marks[0].a {
check(plain.image.size == NSSize(width: 60, height: 60) && rect.origin == NSPoint(x: 5, y: 5),
          "crop beyond the image clamps coordinates without shifting annotations")
}

let batchDir = root.appendingPathComponent("batch", isDirectory: true)
try FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)
for i in 0..<6 { try red.write(to: batchDir.appendingPathComponent("\(i).png")) }
let batchGate = OCRGate()
let batchIndex = CaptureIndex(directory: batchDir, recognize: batchGate.recognize)
var batchNotifications = 0
batchIndex.onChange = { batchNotifications += 1 }
batchIndex.build()
if waitUntil("large batch starts its first two OCR workers", { batchGate.count == 2 }) {
    drain()
    check(batchGate.count == 2, "history indexing bounds concurrent image decoding to two workers")
    check(batchNotifications == 1, "batch scheduling coalesces repeated history refresh notifications")
    for i in 0..<6 {
        if waitUntil("batch worker \(i) is ready", { batchGate.count > i }) {
            batchGate.finish(i, text: "batch pixels")
        }
    }
    waitUntil("bounded batch indexing completes", { !batchIndex.isIndexing })
}
let batchHistory = HistoryWindow(directory: batchDir)
batchHistory.testReload()
let originalCells = batchHistory.testCells
batchHistory.testReload()
check(zip(originalCells, batchHistory.testCells).allSatisfy { $0 === $1 },
      "unchanged history results reuse cells instead of re-decoding every thumbnail")
try CaptureFiles.save(blue, to: batchDir.appendingPathComponent("0.png"))
batchHistory.testReload()
check(zip(originalCells, batchHistory.testCells).contains { $0 !== $1 },
      "changed file revision invalidates history thumbnails")
check(originalCells.filter { old in batchHistory.testCells.contains { $0 === old } }.count == 5,
      "one changed capture preserves the five other cached thumbnail cells")
batchHistory.testSearch("0.png")
check(batchHistory.testCells.count == 1, "changed search results refresh the visible URL list")
let matchingCell = batchHistory.testCells[0]
batchHistory.testSearch("")
check(batchHistory.testCells.count == 6 && batchHistory.testCells.contains { $0 === matchingCell },
      "expanding search results reuses already decoded matching cells")

let cacheURL = root.appendingPathComponent(".ocr-index.json")
try JSONEncoder().encode(["fixture.png": "legacy secret"]).write(to: cacheURL)
let gate = OCRGate()
let index = CaptureIndex(directory: root, recognize: gate.recognize)
check(try index.text(for: url) == nil && !String(contentsOf: cacheURL).contains("legacy secret"),
      "legacy OCR cache is invalidated on migration")
index.indexFile(url)
if waitUntil("old OCR request started", { gate.count == 1 }) {
    try CaptureFiles.save(red, to: url)
    try index.reindex(url)
    index.build()
    // Build also indexes other.png; the edited fixture was already requested first.
    if waitUntil("edited OCR request started", { gate.count >= 2 }) {
        gate.finish(0, text: "old secret")
        drain()
        check(try index.text(for: url) == nil && !String(contentsOf: cacheURL).contains("old secret"),
              "old OCR finishing during reindex cannot restore removed text")
        gate.finish(1, text: "safe pixels")
        waitUntil("fresh OCR result becomes searchable", { index.text(for: url) == "safe pixels" })
    }
}
for i in 2..<gate.count { gate.finish(i, text: "other pixels") }
waitUntil("batch and per-file indexing drain", { !index.isIndexing })

let reverseGate = OCRGate()
let raceDir = root.appendingPathComponent("race", isDirectory: true)
try FileManager.default.createDirectory(at: raceDir, withIntermediateDirectories: true)
let raceURL = raceDir.appendingPathComponent("race.png")
try red.write(to: raceURL)
let reverseIndex = CaptureIndex(directory: raceDir, recognize: reverseGate.recognize)
reverseIndex.build()
if waitUntil("batch OCR started", { reverseGate.count == 1 }) {
    try CaptureFiles.save(blue, to: raceURL)
    try reverseIndex.reindex(raceURL)
    if waitUntil("replacement OCR started", { reverseGate.count == 2 }) {
        reverseGate.finish(1, text: "replacement")
        waitUntil("replacement finishes before old batch", { reverseIndex.text(for: raceURL) == "replacement" })
        reverseGate.finish(0, text: "late secret")
        drain()
        check(reverseIndex.text(for: raceURL) == "replacement", "late batch completion cannot overwrite replacement OCR")
    }
}
// One editor save reindexes twice (the save path, then the thumbnail's file watcher).
let dedupeDir = root.appendingPathComponent("dedupe", isDirectory: true)
try FileManager.default.createDirectory(at: dedupeDir, withIntermediateDirectories: true)
let dedupeURL = dedupeDir.appendingPathComponent("dedupe.png")
try red.write(to: dedupeURL)
let dedupeGate = OCRGate()
let dedupeIndex = CaptureIndex(directory: dedupeDir, recognize: dedupeGate.recognize)
dedupeIndex.indexFile(dedupeURL)
if waitUntil("dedupe fixture starts its first OCR", { dedupeGate.count == 1 }) {
    dedupeGate.finish(0, text: "before edit")
    waitUntil("dedupe fixture stores its first text", { dedupeIndex.text(for: dedupeURL) == "before edit" })
    let mode = (try FileManager.default.attributesOfItem(atPath: dedupeDir.appendingPathComponent(".ocr-index.json").path)[.posixPermissions] as? NSNumber)?.intValue
    check(mode == 0o600, "OCR index file is written owner-only (0600)")
    try CaptureFiles.save(blue, to: dedupeURL)
    try dedupeIndex.reindex(dedupeURL)
    check(dedupeIndex.text(for: dedupeURL) == nil, "first reindex after a save still drops the old text immediately")
    try dedupeIndex.reindex(dedupeURL)
    waitUntil("saved pixels start OCR", { dedupeGate.count == 2 })
    drain()
    check(dedupeGate.count == 2, "one save reindexed twice runs the recognizer exactly once")
    try CaptureFiles.save(red, to: dedupeURL)
    try dedupeIndex.reindex(dedupeURL)
    if waitUntil("a further change restarts OCR", { dedupeGate.count == 3 }) {
        dedupeGate.finish(1, text: "stale pixels")
        drain()
        check(dedupeIndex.text(for: dedupeURL) == nil, "superseded OCR cannot write text for older pixels")
        dedupeGate.finish(2, text: "after edit")
        waitUntil("restarted OCR stores the latest text", { dedupeIndex.text(for: dedupeURL) == "after edit" })
    }
}

let reopened = CaptureIndex(directory: raceDir, recognize: { _ in nil })
check(reopened.text(for: raceURL) == "replacement", "versioned cache reopens when file identity matches")
try CaptureFiles.save(red, to: raceURL)
let changed = CaptureIndex(directory: raceDir, recognize: { _ in nil })
check(changed.text(for: raceURL) == nil, "offline file changes invalidate persisted OCR on next launch")

let privacyDir = root.appendingPathComponent("privacy", isDirectory: true)
try FileManager.default.createDirectory(at: privacyDir, withIntermediateDirectories: true)
let privateCapture = privacyDir.appendingPathComponent("private.png")
let largeTextCapture = privacyDir.appendingPathComponent("other.png")
let privacyCache = privacyDir.appendingPathComponent(".ocr-index.json")
try red.write(to: privateCapture)
try blue.write(to: largeTextCapture)
let privacyIndex = CaptureIndex(directory: privacyDir, recognize: { file in
    if file.lastPathComponent == "other.png" { return String(repeating: "other text ", count: 400) }
    return (try? Data(contentsOf: file)) == red ? "synthetic-secret" : "safe"
})
privacyIndex.build()
waitUntil("privacy fixture starts with a persisted secret", {
    !privacyIndex.isIndexing && privacyIndex.text(for: privateCapture) == "synthetic-secret"
})
var originalLimit = rlimit()
check(getrlimit(RLIMIT_FSIZE, &originalLimit) == 0, "read process-local file size limit")
let originalSignal = signal(SIGXFSZ, SIG_IGN)
var restrictedLimit = originalLimit
restrictedLimit.rlim_cur = 4096
check(try blue.count < 4096 && Data(contentsOf: privacyCache).count > 4096,
      "file-size limit allows the PNG while rejecting the larger OCR cache")
do {
    defer { _ = setrlimit(RLIMIT_FSIZE, &originalLimit); _ = signal(SIGXFSZ, originalSignal) }
    check(setrlimit(RLIMIT_FSIZE, &restrictedLimit) == 0, "apply temporary file-size limit to test process only")
    try CaptureFiles.save(blue, to: privateCapture)
    try privacyIndex.reindex(privateCapture)
    check(!FileManager.default.fileExists(atPath: privacyCache.path)
          || !((try? String(contentsOf: privacyCache))?.contains("synthetic-secret") ?? true),
          "failed OCR rewrite removes the stale rebuildable cache after successful image save")
}
waitUntil("privacy cache rebuild completes after restoring process limit", { !privacyIndex.isIndexing })
try CaptureFiles.save(red, to: privateCapture)
try privacyIndex.reindex(privateCapture)
waitUntil("privacy fixture restores the secret before testing a blocked cache purge", {
    !privacyIndex.isIndexing && privacyIndex.text(for: privateCapture) == "synthetic-secret"
})
let privacyApp = AppDelegate(directory: privacyDir, pasteboard: pb)
privacyApp.testEdit(privateCapture)
let privacyEditor = privacyApp.testEditors[privateCapture]!
privacyEditor.testMark(.redact(NSRect(x: 0, y: 0, width: 100, height: 80)))
var privacyError: Error?
privacyEditor.onSaveError = { privacyError = $0 }
do {
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: privacyCache.path)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: privacyCache.path) }
    privacyEditor.attemptTestSave()
    check((privacyError as NSError?)?.domain == "SnapShelf.OCRPrivacy"
          && privacyApp.testEditors[privateCapture] === privacyEditor && privacyEditor.window.isVisible,
          "failed cache rewrite and purge propagates a privacy error and retains the real editor")
    check(pixel(try Data(contentsOf: privateCapture)).redComponent < 0.01,
          "cache purge failure still preserves the successfully redacted image")
    check((try String(contentsOf: privacyCache)).contains("synthetic-secret"),
          "blocked-purge fixture confirms stale text is present when reporting the privacy failure")
    try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: privacyCache.path)
    privacyEditor.attemptTestSave()
    check(try privacyApp.testEditors.isEmpty && !String(contentsOf: privacyCache).contains("synthetic-secret"),
          "retry after restoring cache permissions clears stale text and closes the editor")
}

let deleteGate = OCRGate()
let deletedIndex = CaptureIndex(directory: raceDir, recognize: deleteGate.recognize)
deletedIndex.build()
if waitUntil("OCR started before deletion", { deleteGate.count == 1 }) {
    try FileManager.default.removeItem(at: raceURL)
    try deletedIndex.prune()
    deleteGate.finish(0, text: "deleted secret")
    drain()
    check(deletedIndex.text(for: raceURL) == nil && !deletedIndex.isIndexing,
          "delete/prune invalidates in-flight OCR without leaving indexing stuck")
    check(!(try String(contentsOf: raceDir.appendingPathComponent(".ocr-index.json"))).contains("deleted secret"),
          "deleted OCR text never returns to disk")
}

let appDelegate = AppDelegate(directory: root, pasteboard: pb)
appDelegate.testPin(url)
let retainedThumb = appDelegate.testItems.first!
appDelegate.testEdit(url)
let firstEditor = appDelegate.testEditors[url]!
appDelegate.testPreview(url)
check(appDelegate.testEditors.count == 1 && appDelegate.testEditors[url] === firstEditor,
      "thumbnail and search preview share one editor per file")
appDelegate.testDismiss()
check(appDelegate.testItems.isEmpty && retainedThumb.testClosed && !retainedThumb.testWatching,
      "dismiss all releases thumbnails and stops their file watchers")
check(appDelegate.testEditors[url] === firstEditor && firstEditor.window.isVisible,
      "dismiss all preserves the independently owned editor")
firstEditor.testMark(.redact(NSRect(x: 0, y: 0, width: 100, height: 80)))
firstEditor.attemptTestSave()
check(try appDelegate.testEditors.isEmpty && pixel(Data(contentsOf: url)).redComponent < 0.01,
      "editor can still save after all thumbnails are dismissed")
check(pixel(pb.data(forType: .tiff)!).blueComponent < 0.01, "save after dismiss still refreshes the owned clipboard")
drain(0.3)
check(!retainedThumb.testWatching, "dismissed item cannot re-arm its watcher later")

try red.write(to: url, options: .atomic)
let watched = ShelfItem(url: url, image: NSImage(data: red)!, origin: .zero, clipboard: clipboard)
let narrow = fixture(.blue, size: NSSize(width: 40, height: 160))
try CaptureFiles.save(narrow, to: url)
waitUntil("atomic replacement refreshes thumbnail and re-arms watcher", {
    watched.testImageSize == NSImage(data: narrow)!.size && watched.testWatching
})
try CaptureFiles.save(red, to: url)
waitUntil("re-armed watcher observes a second atomic save", {
    watched.testImageSize == NSImage(data: red)!.size && watched.testWatching
})
try CaptureFiles.save(blue, to: url)
watched.close()
drain(0.4)
check(!watched.testWatching, "close during atomic-save notification cancels watcher rearm")

// Unsaved-edit protection: Cancel, Esc and the red close button ask only when dirty.
var discardAsked = 0
var discardAnswer = false
var unsavedClosed = 0
var unsavedSaves = 0
func unsavedEditor() -> EditorController {
    let e = EditorController(image: NSImage(data: red)!, tool: .pen) { _ in unsavedSaves += 1 }
    e.confirmDiscard = { decide in discardAsked += 1; decide(discardAnswer) }
    e.onClosed = { unsavedClosed += 1 }
    return e
}
let cleanEditor = unsavedEditor()
check(!cleanEditor.hasUnsavedChanges && cleanEditor.windowShouldClose(cleanEditor.window) && discardAsked == 0,
      "a clean editor closes without asking")
cleanEditor.testMark(.box(NSRect(x: 10, y: 10, width: 20, height: 20), .red))
cleanEditor.testUndo()
check(!cleanEditor.hasUnsavedChanges, "adding then undoing a mark leaves the editor clean")
cleanEditor.testCrop(NSRect(x: 10, y: 10, width: 40, height: 40))
check(cleanEditor.hasUnsavedChanges, "a crop marks the editor dirty")
cleanEditor.testUndo()
check(!cleanEditor.hasUnsavedChanges, "undoing the crop leaves the editor clean")
cleanEditor.testButton("Cancel")?.performClick(nil)
check(unsavedClosed == 1 && discardAsked == 0, "Cancel on a clean editor closes immediately")

let dirtyEditor = unsavedEditor()
dirtyEditor.testMark(.box(NSRect(x: 10, y: 10, width: 20, height: 20), .red))
discardAnswer = false
dirtyEditor.testButton("Cancel")?.performClick(nil)
check(discardAsked == 1 && unsavedClosed == 1, "Cancel on a dirty editor asks and Keep Editing keeps it open")
check(dirtyEditor.testButton("Cancel")?.keyEquivalent == "\u{1b}", "Esc still triggers the guarded Cancel button")
dirtyEditor.window.performClose(nil)
check(discardAsked == 2 && unsavedClosed == 1, "the red close button on a dirty editor asks first")
discardAnswer = true
dirtyEditor.window.performClose(nil)
check(discardAsked == 3 && unsavedClosed == 2 && unsavedSaves == 0, "Discard closes the dirty editor without saving")

let untouchedEditor = unsavedEditor()
untouchedEditor.testButton("Done")?.performClick(nil)
check(unsavedClosed == 3 && unsavedSaves == 0, "Done with no changes closes without re-encoding")

let unsavedDir = root.appendingPathComponent("unsaved", isDirectory: true)
try FileManager.default.createDirectory(at: unsavedDir, withIntermediateDirectories: true)
let unsavedURL = unsavedDir.appendingPathComponent("untouched.png")
try red.write(to: unsavedURL)
let untouchedRevision = fileRevision(unsavedURL)
let quitApp = AppDelegate(directory: unsavedDir, pasteboard: pb)
quitApp.testEdit(unsavedURL)
quitApp.testEditors[unsavedURL]!.testButton("Done")?.performClick(nil)
check(quitApp.testEditors.isEmpty && fileRevision(unsavedURL) == untouchedRevision,
      "Done with no changes leaves the capture file untouched")

var quitAsked = 0
var quitAnswer = false
var relaunches = 0
quitApp.confirmQuit = { _ in quitAsked += 1; return quitAnswer }
quitApp.relaunch = { relaunches += 1 }
check(quitApp.applicationShouldTerminate(testApp) == .terminateNow && quitAsked == 0,
      "quitting without open edits does not ask")
quitApp.testEdit(unsavedURL)
let quitEditor = quitApp.testEditors[unsavedURL]!
check(quitApp.applicationShouldTerminate(testApp) == .terminateNow && quitAsked == 0,
      "quitting with a clean editor open does not ask")
quitEditor.testMark(.box(NSRect(x: 10, y: 10, width: 20, height: 20), .red))
check(quitApp.applicationShouldTerminate(testApp) == .terminateCancel && quitAsked == 1
      && quitApp.testEditors[unsavedURL] === quitEditor && quitEditor.window.isVisible,
      "Cancel on the quit prompt keeps the app and the dirty editor")
quitApp.testRestart()
check(quitAsked == 2 && relaunches == 0, "cancelled restart never spawns the relaunch helper")
quitAnswer = true
check(quitApp.applicationShouldTerminate(testApp) == .terminateNow && quitAsked == 3,
      "Quit Anyway lets termination proceed")
quitApp.testRestart()
check(quitAsked == 4 && relaunches == 1, "confirmed restart relaunches once")
check(quitApp.applicationShouldTerminate(testApp) == .terminateNow && quitAsked == 4,
      "termination after a confirmed restart does not ask twice")
quitEditor.close()

// Main menu + text tool keys: real key events through AppKit's key-equivalent routing.
testApp.mainMenu = makeMainMenu()
func allItems(_ menu: NSMenu?) -> [NSMenuItem] {
    (menu?.items ?? []).flatMap { [$0] + allItems($0.submenu) }
}
let menuKeyItems = allItems(testApp.mainMenu).filter { !$0.keyEquivalent.isEmpty }
check(Set(menuKeyItems.map(\.keyEquivalent)) == ["x", "c", "v", "a", "w"]
      && menuKeyItems.allSatisfy { $0.keyEquivalentModifierMask == .command },
      "main menu has only ⌘X/C/V/A/W: no Undo, no Quit, nothing shared with the status menu")
check(menuKeyItems.map { $0.action.map(NSStringFromSelector) ?? "" }
      == ["cut:", "copy:", "paste:", "selectAll:", "performClose:"], "main menu items send the standard actions")
func key(_ chars: String, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                     context: nil, characters: chars, charactersIgnoringModifiers: chars,
                     isARepeat: false, keyCode: keyCode)!
}
// NSApplication.sendEvent order: the key window's views, then the main menu, then the window.
func press(_ event: NSEvent, in window: NSWindow) {
    if window.performKeyEquivalent(with: event) { return }
    if testApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
    window.sendEvent(event)
}
let keysURL = unsavedDir.appendingPathComponent("keys.png")
try red.write(to: keysURL)
let keysApp = AppDelegate(directory: unsavedDir, pasteboard: pb)
keysApp.testEdit(keysURL)
let keysEditor = keysApp.testEditors[keysURL]!
let keysWindow = keysEditor.window
var keysAsked = 0
keysEditor.confirmDiscard = { _ in keysAsked += 1 }
keysWindow.makeKeyAndOrderFront(nil)
keysEditor.testMark(.box(NSRect(x: 10, y: 10, width: 20, height: 20), .red))
keysWindow.makeFirstResponder(keysWindow.initialFirstResponder)
press(key("z", 6, .command, in: keysWindow), in: keysWindow)
check(keysEditor.testMarkCount == 0 && !keysEditor.hasUnsavedChanges, "⌘Z still undoes in the editor with the main menu installed")

keysEditor.testBeginText(at: NSPoint(x: 20, y: 20))
for (c, code) in [("h", UInt16(4)), ("i", UInt16(34))] { press(key(c, code, in: keysWindow), in: keysWindow) }
let typedField = keysEditor.testActiveField
check(typedField?.stringValue == "hi" && keysEditor.hasUnsavedChanges, "typed text in an open field counts as unsaved")
// The test process is never the active app, so there is no key window for a nil-target
// menu action to reach: send the ⌘A item's action up the focused responder chain instead.
let fieldEditor = typedField?.currentEditor() as? NSTextView
let selectAllItem = menuKeyItems.first { $0.keyEquivalent == "a" && $0.keyEquivalentModifierMask == .command }
check(selectAllItem.flatMap { item in fieldEditor?.tryToPerform(item.action!, with: item) } == true
      && fieldEditor?.selectedRange() == NSRange(location: 0, length: 2),
      "⌘A in a text field selects all through the main menu")
press(key("\r", 36, in: keysWindow), in: keysWindow)
check(keysEditor.testActiveField == nil && keysEditor.testMarkCount == 1 && keysWindow.isVisible
      && keysApp.testEditors[keysURL] === keysEditor && keysEditor.testCanvasFocused,
      "Return in the text field commits the annotation without closing the editor")
check(fileRevision(keysURL) != nil && keysAsked == 0, "Return in the text field does not trigger Done or Cancel")

keysEditor.testBeginText(at: NSPoint(x: 30, y: 30))
press(key("x", 7, in: keysWindow), in: keysWindow)
press(key("\u{1b}", 53, in: keysWindow), in: keysWindow)
check(keysEditor.testActiveField == nil && keysEditor.testMarkCount == 1 && keysWindow.isVisible
      && keysAsked == 0 && keysEditor.testCanvasFocused,
      "Esc in the text field drops it without committing or closing the editor")

press(key("\u{1b}", 53, in: keysWindow), in: keysWindow)
check(keysAsked == 1 && keysWindow.isVisible, "Esc with no open field is Cancel and asks about unsaved edits")
let closeItem = menuKeyItems.first { $0.keyEquivalent == "w" }
check(closeItem.flatMap { item in (keysWindow.firstResponder as NSResponder?)?.tryToPerform(item.action!, with: item) } == true
      && keysAsked == 2 && keysWindow.isVisible, "⌘W on a dirty editor goes through the discard prompt")
let keysBefore = fileRevision(keysURL)
press(key("\r", 36, in: keysWindow), in: keysWindow)
check(keysApp.testEditors.isEmpty && fileRevision(keysURL) != keysBefore, "Return with no open field is Done and saves")

if failures > 0 { exit(1) }
print("All regression checks passed")
