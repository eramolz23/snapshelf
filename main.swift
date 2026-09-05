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
private func capturedFiles(in directory: URL = saveDir) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(at: directory,
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

// File identity includes nanosecond timestamps: same-name replacements and rapid edits
// invalidate background OCR even when the file size or second-level mtime is unchanged.
private func fileRevision(_ url: URL) -> String? {
    var info = stat()
    guard stat(url.path, &info) == 0 else { return nil }
    return "\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
}

final class CaptureClipboard {
    private let pasteboard: NSPasteboard
    private var owner: URL?
    private var changeCount = -1
    var currentChangeCount: Int { pasteboard.changeCount }

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    func copy(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        pasteboard.clearContents()
        if pasteboard.writeObjects([image, url as NSURL]) {
            owner = url
            changeCount = pasteboard.changeCount
        } else { owner = nil }
    }

    func refreshAfterSave(_ url: URL) {
        guard owner == url, pasteboard.changeCount == changeCount else { return }
        copy(url)
    }

    func copyText(_ text: String, from url: URL? = nil) {
        pasteboard.clearContents()
        if pasteboard.setString(text, forType: .string) {
            owner = url
            changeCount = pasteboard.changeCount
        } else { owner = nil }
    }
}

private enum CaptureFiles {
    static func destination(in directory: URL, date: Date = Date()) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return directory.appendingPathComponent("Screenshot \(df.string(from: date)) \(UUID().uuidString).png")
    }

    static func succeeded(at url: URL, status: Int32, reason: Process.TerminationReason) -> Bool {
        status == 0 && reason == .exit && NSImage(contentsOf: url) != nil
    }

    static func save(_ data: Data, to url: URL) throws {
        // A deleted screenshot must not be silently resurrected by an open editor.
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        try data.write(to: url, options: .atomic)
    }
}

private enum LoginPreference {
    static let key = "startAtLogin"
    static func registerOnLaunch(defaults: UserDefaults, status: SMAppService.Status) -> Bool {
        if defaults.object(forKey: key) == nil {
            // An absent preference cannot distinguish first launch from an older
            // installation whose owner switched login off. Preserve the OS choice.
            let enabled = status == .enabled || status == .requiresApproval
            defaults.set(enabled, forKey: key)
        }
        return defaults.bool(forKey: key) && status == .notRegistered
    }
}

// Main-thread state; OCR workers return individual entries, never a stale disk snapshot.
final class CaptureIndex {
    private struct Entry: Codable { let revision: String; let text: String }
    private struct Cache: Codable { let version: Int; let entries: [String: Entry] }
    private let directory: URL
    private let indexURL: URL
    private let recognize: (URL) -> String?
    private let workerQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private var entries: [String: Entry] = [:]
    private var generations: [String: Int] = [:]
    private var pending: [String: Int] = [:]
    private var changeNotificationPending = false
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?
    var isIndexing: Bool { !pending.isEmpty }

    init(directory: URL, recognize: @escaping (URL) -> String? = HistoryWindow.recognizeText) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent(".ocr-index.json")
        self.recognize = recognize
        if let data = try? Data(contentsOf: indexURL),
           let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == 2 {
            entries = cache.entries
        }
        // Legacy filename-only caches cannot prove which pixels their text came from.
        // Rewrite immediately so previously removed secrets do not survive migration.
        do { try prune(); try save() }
        catch { report(error) }
    }

    func text(for url: URL) -> String? {
        guard let entry = entries[url.lastPathComponent], entry.revision == fileRevision(url) else { return nil }
        return entry.text
    }

    func indexFile(_ url: URL) {
        let name = url.lastPathComponent
        guard text(for: url) == nil, let revision = fileRevision(url) else { return }
        let generation = generations[name, default: 0]
        guard pending[name] != generation else { return }
        pending[name] = generation
        notifyChange()
        let recognize = self.recognize
        workerQueue.addOperation { [weak self] in
            let text = recognize(url)
            DispatchQueue.main.async {
                guard let self, self.generations[name, default: 0] == generation else { return }
                self.pending[name] = nil
                guard fileRevision(url) == revision else {
                    do { try self.reindex(url) }
                    catch { self.report(error) }
                    return
                }
                if let text { self.entries[name] = Entry(revision: revision, text: text) }
                do { try self.save() }
                catch { self.report(error) }
                self.notifyChange()
            }
        }
    }

    private func invalidate(_ url: URL) throws {
        let name = url.lastPathComponent
        generations[name, default: 0] += 1
        entries[name] = nil
        pending[name] = nil
        notifyChange()
        try save()
    }

    func reindex(_ url: URL) throws { try invalidate(url); indexFile(url) }

    func prune() throws {
        let names = Set(entries.keys).union(pending.keys)
        for name in names {
            let url = directory.appendingPathComponent(name)
            let revision = fileRevision(url)
            if revision == nil || (entries[name] != nil && entries[name]?.revision != revision) {
                try invalidate(url)
            }
        }
    }

    func build() {
        do { try prune() }
        catch { report(error); return }
        for url in capturedFiles(in: directory) { indexFile(url) }
    }

    private func notifyChange() {
        guard !changeNotificationPending else { return }
        changeNotificationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.changeNotificationPending = false
            self.onChange?()
        }
    }

    private func report(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            if let onError = self?.onError { onError(error) }
            else { NSLog("SnapShelf OCR cache privacy error: %@", error.localizedDescription) }
        }
    }

    private func save() throws {
        do {
            let data = try JSONEncoder().encode(Cache(version: 2, entries: entries))
            try data.write(to: indexURL, options: .atomic)
        } catch {
            // This file is rebuildable. A failed rewrite must not leave text from the
            // previous image on disk after the edited PNG has already been saved.
            do { try FileManager.default.removeItem(at: indexURL) }
            catch let purgeError as NSError where purgeError.domain == NSCocoaErrorDomain
                && purgeError.code == NSFileNoSuchFileError { return }
            catch {
                throw NSError(domain: "SnapShelf.OCRPrivacy", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "The previous OCR cache could not be cleared. Check disk space and permissions for \(indexURL.path), then try saving again.",
                    NSUnderlyingErrorKey: error,
                ])
            }
        }
    }
}

// Decode a downsampled copy straight from disk via ImageIO. `maxPixel` bounds the longer
// side. Used everywhere a preview is drawn so the full-res bitmap (60MB for a 5K shot)
// never sits in a layer or a menu.
private func downsampledImage(at url: URL, maxPixel: CGFloat) -> NSImage? {
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
    ]
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: .zero)
}

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

enum Tool: Int { case pen = 0, highlight, arrow, box, text, blur, redact, crop }

enum Annotation {
    case pen([NSPoint], NSColor)
    case highlight([NSPoint], NSColor)   // wide translucent multiply stroke
    case arrow(NSPoint, NSPoint, NSColor)
    case box(NSRect, NSColor)
    case text(String, NSPoint, NSColor, CGFloat)
    case blur(NSRect, NSImage)   // rect + prebuilt pixelated tile of that region
    case redact(NSRect)   // opaque pixels, unlike cosmetic pixelation

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
        case .redact(let r):
            NSColor.black.setFill()
            NSBezierPath(rect: r).fill()
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
        case .redact(let r): return .redact(NSRect(origin: t(r.origin), size: r.size))
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
    private(set) var editGeneration = 0

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
            case .blur, .redact:
                NSColor.black.withAlphaComponent(tool == .redact ? 1 : 0.35).setFill()
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
        case .redact:
            if let s = dragStart {
                let r = rect(from: s, to: p).intersection(NSRect(origin: .zero, size: image.size))
                if r.width * viewScale > 6, r.height * viewScale > 6 { addMark(.redact(r)) }
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
        editGeneration += 1
        searchHighlights = []
        var w = Self.strokeWidth(for: image) * widthScale
        if case .highlight = a { w *= 5 }
        marks.append(Mark(a: a, width: w))
        ops.append(.mark)
    }

    func undo() {
        editGeneration += 1
        searchHighlights = []
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
        let r = r.intersection(NSRect(origin: .zero, size: image.size)).integral
        guard !r.isEmpty else { return }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let s = CGFloat(cg.width) / max(image.size.width, 1)
        let px = CGRect(x: r.minX * s, y: (image.size.height - r.maxY) * s,
                        width: r.width * s, height: r.height * s).integral
        guard px.width > 2, px.height > 2, let cropped = cg.cropping(to: px) else { return }
        ops.append(.crop(image, marks))
        editGeneration += 1
        searchHighlights = []
        image = NSImage(cgImage: cropped, size: NSSize(width: px.width / s, height: px.height / s))
        let d = NSPoint(x: -r.minX, y: -r.minY)
        marks = marks.map { Mark(a: $0.a.translated(by: d), width: $0.width) }
    }

    private func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // Downscale the region to ~12pt blocks; drawn back up with interpolation off = pixelate.
    private func pixelTile(for r: NSRect) -> NSImage? {
        // Sample visible edits as well as the original image. Sampling the original
        // could bring a secret back when Blur is applied over an existing redaction.
        guard let data = renderPNG(), let rendered = NSImage(data: data),
              let cg = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
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
        ctx.cgContext.scaleBy(x: CGFloat(cg.width) / max(image.size.width, 1),
                              y: CGFloat(cg.height) / max(image.size.height, 1))
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
    private let onSave: (Data) throws -> Void
    private var activeField: NSTextField?
    private var pendingTextPoint = NSPoint.zero
    var onClosed: (() -> Void)?
    var onSaveError: ((Error) -> Void)?
    var editGeneration: Int { canvas.editGeneration }

    init(image: NSImage, tool: Tool, onSave: @escaping (Data) throws -> Void) {
        self.onSave = onSave
        canvas = EditorCanvas(image: image)
        canvas.tool = tool
        toolPicker = NSSegmentedControl(labels: ["Pen", "Highlight", "Arrow", "Box", "Text", "Blur", "Redact", "Crop"],
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

        // Never narrower than the toolbar: a narrow capture used to open a 480pt window
        // with Undo past the right edge and Cancel/Done drawn over the S/M/L picker.
        let barMin = 12 + toolPicker.frame.width + 10 + widthPicker.frame.width + 10 + 44 + 10
            + undoBtn.frame.width + 10 + 24 + cancelBtn.frame.width + 8 + doneBtn.frame.width + 12
        if content.width < barMin {
            window.setContentSize(NSSize(width: barMin, height: content.height))
        }
        window.minSize = NSSize(width: barMin, height: barH + 160)

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
        do {
            guard let data = canvas.renderPNG() else { throw CocoaError(.fileWriteUnknown) }
            try onSave(data)
            window.close()
        } catch {
            if let onSaveError { onSaveError(error); return }
            let alert = NSAlert()
            alert.messageText = "Screenshot could not be saved"
            alert.informativeText = "Your edits are still open. \(error.localizedDescription)"
            alert.beginSheetModal(for: window)
        }
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
    // Downsampled preview only — the full-res capture stays on disk.
    var preview: NSImage { didSet { layer?.contents = preview } }
    let fileURL: URL
    var onClick: (() -> Void)?
    private var downPoint = NSPoint.zero
    private var dragging = false

    init(preview: NSImage, fileURL: URL) {
        self.preview = preview
        self.fileURL = fileURL
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = preview
        // Aspect-fit, not fill: a narrow capture sits centered in a panel that is
        // as wide as the toolbar needs, instead of being cropped to fill it.
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
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
        item.setDraggingFrame(bounds, contents: preview)
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
    var onSaved: ((URL) -> Void)?   // editor wrote a new version of the file
    var onEdit: ((URL, Tool) -> Void)?
    var onLayoutChanged: (() -> Void)?
    var isEditing = false
    private let clipboard: CaptureClipboard

    // Only the point size is kept; the pixels live on disk and in the downsampled preview.
    private var imageSize: NSSize
    private let thumbView: ThumbView
    private let bar = NSVisualEffectView()
    private let copyBtn = ActionButton(title: "Copy")
    private let ocrBtn = ActionButton(title: "OCR")
    private let cropBtn = ActionButton(title: "Crop")
    private let markupBtn = ActionButton(title: "Markup")
    private let linkBtn = ActionButton(title: "Link")
    private let closeBtn = ActionButton(title: "✕")
    private var watcher: DispatchSourceFileSystemObject?
    private var closed = false
    private var visibleFrame: NSRect

    static func thumbSize(for imageSize: NSSize, maximum: NSSize = NSSize(width: 320, height: 240)) -> NSSize {
        let scale = min(1, maximum.width / max(imageSize.width, 1), maximum.height / max(imageSize.height, 1))
        return NSSize(width: max(imageSize.width * scale, 60),
                      height: max(imageSize.height * scale, 40))
    }

    // The newest suffix that fits remains visible; overflow remains in History/Recent.
    static func frames(for sizes: [NSSize], in visibleFrame: NSRect) -> [NSRect?] {
        let area = visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
        var result = [NSRect?](repeating: nil, count: sizes.count)
        var used: CGFloat = 0
        var first = sizes.count
        for i in sizes.indices.reversed() {
            let extra = sizes[i].height + (first == sizes.count ? 0 : 8)
            guard sizes[i].width <= area.width, used + extra <= area.height else { break }
            used += extra
            first = i
        }
        var y = area.minY
        for i in first..<sizes.count {
            result[i] = NSRect(origin: NSPoint(x: area.minX, y: y), size: sizes[i])
            y += sizes[i].height + 8
        }
        return result
    }

    // Retina-sharp at thumb size, nothing bigger. Falls back to the full image only if
    // ImageIO can't read the file (then it's the old behavior, not a blank thumb).
    private static func preview(for url: URL, imageSize: NSSize, fallback: NSImage) -> NSImage {
        let size = thumbSize(for: imageSize)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return downsampledImage(at: url, maxPixel: max(size.width, size.height) * scale) ?? fallback
    }

    init(url: URL, image: NSImage, origin: NSPoint, clipboard: CaptureClipboard = CaptureClipboard()) {
        self.url = url
        self.clipboard = clipboard
        self.visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        self.imageSize = image.size
        self.thumbView = ThumbView(preview: ShelfItem.preview(for: url, imageSize: image.size, fallback: image),
                                   fileURL: url)

        let size = ShelfItem.thumbSize(for: image.size)
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

    // The toolbar's natural width. The panel never goes narrower, so a narrow capture
    // can't push Link/✕ off the edge (✕ used to land on top of Crop).
    private var barMinWidth: CGFloat {
        let left = [copyBtn, ocrBtn, cropBtn, markupBtn, linkBtn].reduce(CGFloat(6)) { $0 + $1.frame.width + 4 }
        return left + 4 + closeBtn.frame.width + 6
    }

    private func layout() {
        let maximum = NSSize(width: min(maxThumbWidth, max(60, visibleFrame.width - 2 * screenMargin)),
                             height: min(240, max(40, visibleFrame.height - 2 * screenMargin - Self.barHeight)))
        let fit = ShelfItem.thumbSize(for: imageSize, maximum: maximum)
        let size = NSSize(width: max(fit.width, barMinWidth), height: fit.height)
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
        onLayoutChanged?()
    }

    func fit(to frame: NSRect) { visibleFrame = frame; layout() }

    // MARK: Actions

    private func copyToClipboard() {
        clipboard.copy(url)
        copyBtn.title = "Copied ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.copyBtn.title = "Copy"
            self?.copyBtn.sizeToFit()
            self?.layout()
        }
        copyBtn.sizeToFit()
        layout()
    }

    // On-device text recognition → clipboard.
    private func runOCR() {
        ocrBtn.title = "…"
        ocrBtn.sizeToFit()
        let u = url
        let revision = fileRevision(u)
        let clipboardCount = clipboard.currentChangeCount
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
                guard let self, !self.closed else { return }
                guard revision != nil, fileRevision(u) == revision else {
                    self.ocrBtn.title = "Retry OCR"
                    self.ocrBtn.sizeToFit()
                    self.layout()
                    return
                }
                if text.isEmpty {
                    self.ocrBtn.title = "No text"
                } else if self.clipboard.currentChangeCount == clipboardCount {
                    self.clipboard.copyText(text, from: u)
                    self.ocrBtn.title = "Copied ✓"
                } else {
                    self.ocrBtn.title = "Retry OCR"
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
    // Anyone with the link can view it, so redact secrets first; expires after 72 hours.
    private func shareLink() {
        linkBtn.title = "…"
        linkBtn.sizeToFit()
        layout()
        guard let fileData = try? Data(contentsOf: url) else {
            linkBtn.title = "Failed"; linkBtn.sizeToFit(); layout(); return
        }
        let revision = fileRevision(url)
        let clipboardCount = clipboard.currentChangeCount
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
                guard let self, !self.closed else { return }
                let link = data.flatMap { String(data: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let link, link.hasPrefix("http"),
                   revision != nil, fileRevision(self.url) == revision,
                   self.clipboard.currentChangeCount == clipboardCount,
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    self.clipboard.copyText(link)
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
        onEdit?(url, tool)
    }

    func close() {
        guard !closed else { return }
        closed = true
        watcher?.cancel()
        watcher = nil
        panel.orderOut(nil)
        onClosed?(self)
    }

    deinit { watcher?.cancel() }

    // MARK: File watcher — editor saves land back on the thumbnail

    private func startWatching() {
        guard !closed, watcher == nil else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, !self.closed, let w = self.watcher else { return }
            let flags = w.data
            // Atomic saves replace the file: re-arm the watch on the new inode.
            if flags.contains(.delete) || flags.contains(.rename) {
                w.cancel()
                self.watcher = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, !self.closed else { return }
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

    func reloadFromDisk() {
        guard !closed else { return }
        guard let img = NSImage(contentsOf: url) else {
            onSaved?(url)
            if !FileManager.default.fileExists(atPath: url.path) { close() }
            return
        }
        imageSize = img.size
        thumbView.preview = ShelfItem.preview(for: url, imageSize: img.size, fallback: img)
        layout()
        onSaved?(url)
    }
}

// MARK: - History window: searchable grid of every capture

final class HistoryCell: NSView, NSDraggingSource {
    let url: URL
    let revision: String?
    var onPin: ((URL) -> Void)?
    private var downPoint = NSPoint.zero
    private var dragging = false

    init(url: URL) {
        self.url = url
        self.revision = fileRevision(url)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        toolTip = url.deletingPathExtension().lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let img = downsampledImage(at: url, maxPixel: 400) else { return }
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
        let existing = Dictionary(uniqueKeysWithValues: subviews.compactMap { view -> (URL, HistoryCell)? in
            guard let cell = view as? HistoryCell else { return nil }
            return (cell.url, cell)
        })
        subviews = urls.map { u -> NSView in
            if let cell = existing[u], cell.revision == fileRevision(u) { return cell }
            let c = HistoryCell(url: u)
            c.onPin = { [weak self] in self?.onPin?($0) }
            return c
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
    private let index: CaptureIndex
    private let directory: URL
    private var displayedFiles: [String] = []

    init(directory: URL = saveDir) {
        self.directory = directory
        self.index = CaptureIndex(directory: directory)
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
        index.onChange = { [weak self] in
            guard let self else { return }
            self.window.title = self.index.isIndexing ? "SnapShelf History — indexing…" : "SnapShelf History"
            if self.window.isVisible { self.reload() }
        }
        index.onError = { [weak self] error in self?.showIndexError(error) }
    }

    func open() {
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        prune()
        reload()
        buildIndex()
    }

    @objc private func searchChanged() { reload() }

    private func reload() {
        let q = search.stringValue.lowercased()
        var urls = capturedFiles(in: directory)
        if !q.isEmpty {
            urls = urls.filter {
                $0.lastPathComponent.lowercased().contains(q)
                    || (index.text(for: $0)?.lowercased().contains(q) ?? false)
            }
        }
        let files = urls.map { "\($0.path)|\(fileRevision($0) ?? "missing")" }
        guard files != displayedFiles else { return }
        displayedFiles = files
        grid.show(urls: urls)
    }

    // Image-point rects of every occurrence of query, via Vision word boxes.
    static func matchRects(in url: URL, query: String) -> [NSRect] {
        guard !query.isEmpty, let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        do { try VNImageRequestHandler(cgImage: cg).perform([req]) } catch { return [] }
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
        do { try VNImageRequestHandler(cgImage: cg).perform([req]) } catch { return nil }
        return (req.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
    }

    // Called on every new capture so search is current without reopening the window.
    func indexFile(_ url: URL) {
        index.indexFile(url)
    }

    // The file changed under an existing entry (editor save). Drop the old text NOW so a
    // blurred secret is unsearchable immediately, then OCR the new pixels.
    func reindex(_ url: URL) throws {
        try index.reindex(url)
    }

    func fileChanged(_ url: URL) {
        do { try reindex(url) }
        catch { showIndexError(error) }
    }

    // Text must not outlive its screenshot (60-day cleanup, manual deletes in Finder).
    func prune() {
        do { try index.prune() }
        catch { showIndexError(error) }
    }

    // OCR every un-indexed capture in the background so search-by-content works.
    private func buildIndex() {
        index.build()
    }

    private func showIndexError(_ error: Error) {
        // The save path already presents its error on the editor. Avoid stacking a
        // second alert if a watcher reports the same failed cache purge afterward.
        guard NSApp.keyWindow?.attachedSheet == nil else { return }
        let alert = NSAlert(error: error)
        if let parent = NSApp.keyWindow { alert.beginSheetModal(for: parent) }
        else { alert.runModal() }
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
    private let history: HistoryWindow
    private let directory: URL
    private let clipboard: CaptureClipboard
    private var editors: [URL: EditorController] = [:]
    private var isReflowing = false
    // Recent Captures icons. Keyed on path + mtime so an editor save invalidates the entry.
    private var menuThumbs: [String: NSImage] = [:]

    init(directory: URL = saveDir, pasteboard: NSPasteboard = .general) {
        self.directory = directory
        self.history = HistoryWindow(directory: directory)
        self.clipboard = CaptureClipboard(pasteboard: pasteboard)
        super.init()
    }

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

        if LoginPreference.registerOnLaunch(defaults: .standard, status: SMAppService.mainApp.status) {
            do { try SMAppService.mainApp.register() }
            catch { NSLog("SnapShelf login registration failed: %@", error.localizedDescription) }
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        history.onPin = { [weak self] url in self?.showThumb(for: url) }
        history.onPreview = { [weak self] url, query in self?.openSearchPreview(url: url, query: query) }
        NotificationCenter.default.addObserver(self, selector: #selector(reflowShelf),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        cleanupOldCaptures()
    }

    @objc private func openHistory() { history.open() }

    private func openSearchPreview(url: URL, query: String) {
        openEditor(url: url, tool: .pen, query: query)
    }

    private func saveCapture(_ data: Data, to url: URL) throws {
        try CaptureFiles.save(data, to: url)
        clipboard.refreshAfterSave(url)
        try history.reindex(url)
        for item in items where item.url == url { item.reloadFromDisk() }
        reflowShelf()
    }

    private func openEditor(url: URL, tool: Tool, query: String? = nil) {
        if let existing = editors[url] { existing.show(); return }
        guard let image = NSImage(contentsOf: url) else { return }
        let e = EditorController(image: image, tool: tool) { [weak self] data in
            guard let self else { throw CocoaError(.fileWriteUnknown) }
            try self.saveCapture(data, to: url)
        }
        e.onClosed = { [weak self, weak e] in
            guard let self, self.editors[url] === e else { return }
            self.editors[url] = nil
            for item in self.items where item.url == url { item.isEditing = false }
            self.reflowShelf()
        }
        editors[url] = e
        for item in items where item.url == url { item.isEditing = true }
        reflowShelf()
        e.show()
        guard let query else { return }
        e.window.title = "Finding “\(query)”…"
        let revision = fileRevision(url)
        let generation = e.editGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak e] in
            let rects = HistoryWindow.matchRects(in: url, query: query)
            DispatchQueue.main.async {
                guard let self, let e, self.editors[url] === e,
                      e.editGeneration == generation, fileRevision(url) == revision else { return }
                e.showSearchHighlights(rects, query: query)
            }
        }
    }

    private func cleanupOldCaptures() {
        let directory = self.directory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let cutoff = Date().addingTimeInterval(-Double(autoCleanupDays) * 86400)
            let old = capturedFiles(in: directory).filter { f in
                let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return d.map { $0 < cutoff } ?? false
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for f in old where self.editors[f] == nil {
                    let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    if let date, date < cutoff { try? FileManager.default.removeItem(at: f) }
                }
                self.history.prune()
            }
        }
    }

    @objc private func toggleLogin() {
        let enabled = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
        // Record intent first, including if the OS rejects the requested operation.
        UserDefaults.standard.set(!enabled, forKey: LoginPreference.key)
        do {
            if enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Start at Login could not be changed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
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
        let url = CaptureFiles.destination(in: directory)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = (interactive ? ["-i"] : ["-m"]) + [url.path]
        p.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard CaptureFiles.succeeded(at: url, status: process.terminationStatus,
                                             reason: process.terminationReason) else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                self?.showThumb(for: url)
            }
        }
        do { try p.run() }
        catch { NSLog("SnapShelf capture could not start: %@", error.localizedDescription) }
    }

    // MARK: - Thumbnail shelf

    private func showThumb(for url: URL) {
        if let existing = items.first(where: { $0.url == url }) {
            items.removeAll { $0 === existing }
            items.append(existing)
            reflowShelf()
            return
        }
        guard let image = NSImage(contentsOf: url), NSScreen.main != nil else { return }
        let item = ShelfItem(url: url, image: image, origin: .zero, clipboard: clipboard)
        item.onClosed = { [weak self] it in
            self?.items.removeAll { $0 === it }
            self?.reflowShelf()
        }
        item.onSaved = { [weak self] in self?.history.fileChanged($0) }
        item.onEdit = { [weak self] url, tool in self?.openEditor(url: url, tool: tool) }
        item.onLayoutChanged = { [weak self] in self?.reflowShelf() }
        item.isEditing = editors[url] != nil
        items.append(item)
        reflowShelf()

        // Auto-copy: capture is on the clipboard immediately, no button needed.
        clipboard.copy(url)

        history.indexFile(url)   // searchable right away, no window reopen needed
        loadMenuThumb(for: url, into: nil)   // warm the Recent Captures icon off the main thread
    }

    @objc private func reflowShelf() {
        guard !isReflowing, let screen = NSScreen.main else { return }
        isReflowing = true
        defer { isReflowing = false }
        for item in items { item.fit(to: screen.visibleFrame) }
        let visible = items.filter { !$0.isEditing }
        let frames = ShelfItem.frames(for: visible.map { $0.panel.frame.size }, in: screen.visibleFrame)
        for item in items where item.isEditing { item.panel.orderOut(nil) }
        for (item, frame) in zip(visible, frames) {
            if let frame {
                item.panel.setFrame(frame, display: true)
                item.panel.orderFrontRegardless()
            } else { item.panel.orderOut(nil) }
        }
    }

    private func menuThumbKey(_ f: URL) -> String {
        "\(f.path)|\(fileRevision(f) ?? "missing")"
    }

    // ImageIO thumbnail on a background queue, cached; the menu item (if any) is filled in
    // when it lands. The old path decoded ten full-res PNGs on the main thread per menu open.
    private func loadMenuThumb(for f: URL, into item: NSMenuItem?) {
        let key = menuThumbKey(f)
        if let cached = menuThumbs[key] { item?.image = cached; return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let img = downsampledImage(at: f, maxPixel: 128) else { return }
            let h: CGFloat = 32
            img.size = NSSize(width: max(h * img.size.width / max(img.size.height, 1), 8), height: h)
            DispatchQueue.main.async {
                guard let self, self.menuThumbKey(f) == key else { return }
                self.menuThumbs[key] = img
                item?.image = img
            }
        }
    }

    // MARK: - Recent captures submenu (rebuilt each time the menu opens)

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let files = capturedFiles(in: directory).prefix(10)
        if files.isEmpty {
            menu.addItem(NSMenuItem(title: "No captures yet", action: nil, keyEquivalent: ""))
        }
        for f in files {
            let mi = NSMenuItem(title: f.deletingPathExtension().lastPathComponent,
                                action: #selector(rePin(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = f
            loadMenuThumb(for: f, into: mi)
            menu.addItem(mi)
        }
        let live = Set(files.map(menuThumbKey))
        menuThumbs = menuThumbs.filter { live.contains($0.key) }
        menu.addItem(.separator())
        let folder = NSMenuItem(title: "Open Captures Folder", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
    }

    @objc private func rePin(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        showThumb(for: url)
    }

    @objc private func openFolder() { NSWorkspace.shared.open(directory) }

    @objc private func dismissAll() {
        for item in items { item.close() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
