import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp

/// The opt-in gallery that renders every screen and popup to PNG so a reviewer
/// can look at all of it at once.
///
/// None of this runs under a normal `swift test`: a gallery suite is enabled
/// only when `AGENT_TOOLING_SCREEN_GALLERY` names an output folder, so the
/// files, the slow run-loop turns and the window chrome stay out of the way of
/// the fast blank-frame checks the other render suites make.
///
/// The machinery here is additive to `ShellRenderHarness.swift`: the gallery
/// rasterizes through the same `rasterize(…)` every section test uses (now with
/// a size and an appearance), writes the bitmap as a PNG, and appends one row to
/// a shared index. The index is written once, when the process exits, because a
/// `.serialized` suite cannot know which test is last.

/// Where the gallery writes, or nil when the gallery is switched off. A test
/// suite gates on this through `.enabled(if: GalleryOutput.isOn)`.
enum GalleryOutput {
    static let folder: URL? = {
        guard let path = ProcessInfo.processInfo.environment["AGENT_TOOLING_SCREEN_GALLERY"],
            !path.isEmpty
        else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }()

    static var isOn: Bool { folder != nil }
}

/// The two window sizes the gallery renders at: the default window and the
/// smallest a person can shrink it to. A screen that only lays out at one is a
/// bug a reviewer should see.
enum GallerySize {
    static let standard = CGSize(width: 1_440, height: 900)
    static let minimum = CGSize(width: 1_180, height: 760)
}

/// One row of the index: enough for a reviewer to find the file, know what they
/// are looking at, and jump to the view that drew it.
struct GalleryIndexRow: Sendable {
    let area: String
    let file: String
    let screen: String
    let state: String
    let size: String
    let appearance: String
    /// `path:line` of the view this image came from.
    let source: String
    /// Set when the title bar could not be captured and only the content drew.
    let note: String?
}

/// Collects every row and every unrenderable note, then writes `index.md` once
/// at process exit. Shared across a `.serialized` suite, so it locks.
final class GalleryIndex: @unchecked Sendable {
    static let shared = GalleryIndex()

    private let lock = NSLock()
    private var rows: [GalleryIndexRow] = []
    private var unrenderable: [(control: String, text: String, source: String)] = []
    private var notes: [String] = []
    private var installed = false

    /// Area order on the page, so the index reads top to bottom the way the
    /// sidebar does rather than in the order the suites happened to run.
    static let areaOrder = [
        "Home", "Discover",
        "Library · Skills", "Library · Plugins", "Library · Connections", "Library · Presets",
        "Insights",
        "Apps · Clients", "Apps · Accounts", "Apps · Checkup", "Apps · App settings", "Apps · Health",
        "Projects",
        "Activity", "History",
        "Settings", "Sync",
        "First run and wizards",
        "Command palette",
    ]

    func add(_ row: GalleryIndexRow) {
        lock.withLock {
            rows.append(row)
            installFlushHookIfNeeded()
        }
    }

    /// A system-drawn surface the gallery does not screenshot, listed instead
    /// with its exact text so the index still accounts for it.
    func addUnrenderable(control: String, text: String, source: String) {
        lock.withLock {
            unrenderable.append((control, text, source))
            installFlushHookIfNeeded()
        }
    }

    /// Anything that could not be rendered, and why.
    func addNote(_ note: String) {
        lock.withLock {
            notes.append(note)
            installFlushHookIfNeeded()
        }
    }

    /// Registers an at-exit flush the first time anything is recorded. The
    /// gallery is a `.serialized` suite with no "last test" hook, so the index
    /// is written when the process winds down instead.
    private func installFlushHookIfNeeded() {
        guard !installed else { return }
        installed = true
        atexit { GalleryIndex.shared.flush() }
    }

    func flush() {
        guard let folder = GalleryOutput.folder else { return }
        let (rows, unrenderable, notes) = lock.withLock { (self.rows, self.unrenderable, self.notes) }
        guard !rows.isEmpty || !unrenderable.isEmpty || !notes.isEmpty else { return }

        var out = "# Agent Tooling screen gallery\n\n"
        out += "\(rows.count) images, grouped by area. Each row names the file, "
        out += "what it shows, its state, size, appearance, and the `path:line` of the view that drew it.\n\n"

        let grouped = Dictionary(grouping: rows, by: \.area)
        let orderedAreas =
            Self.areaOrder.filter { grouped[$0] != nil }
            + grouped.keys.filter { !Self.areaOrder.contains($0) }.sorted()

        for area in orderedAreas {
            guard let areaRows = grouped[area] else { continue }
            out += "## \(area)\n\n"
            out += "| File | Screen or popup | State | Size | Appearance | Source |\n"
            out += "|---|---|---|---|---|---|\n"
            for row in areaRows.sorted(by: { $0.file < $1.file }) {
                let screen = row.note.map { "\(row.screen) — \($0)" } ?? row.screen
                out += "| `\(row.file)` | \(screen) | \(row.state) | \(row.size) | \(row.appearance) | `\(row.source)` |\n"
            }
            out += "\n"
        }

        out += "## Not rendered: system-drawn surfaces\n\n"
        out += "Menus, alerts, confirmation dialogs and open panels are drawn by "
        out += "macOS, not by a view the gallery can host. Each is listed with its "
        out += "exact text from the source instead.\n\n"
        out += "| Control | Text | Source |\n|---|---|---|\n"
        for entry in unrenderable.sorted(by: { $0.source < $1.source }) {
            let text = entry.text.replacingOccurrences(of: "\n", with: " · ")
            out += "| \(entry.control) | \(text) | `\(entry.source)` |\n"
        }
        out += "\n"

        if !notes.isEmpty {
            out += "## Could not render\n\n"
            for note in notes { out += "- \(note)\n" }
            out += "\n"
        }

        try? out.write(to: folder.appending(path: "index.md"), atomically: true, encoding: .utf8)
    }
}

/// Renders one view, writes it as a PNG into the gallery, and records its row.
///
/// It rasterizes through the same `rasterize(…)` the section tests use, so a
/// gallery image is the screen those tests already guard, captured rather than
/// only checked.
@MainActor
func gallerySnapshot(
    _ view: some View,
    area: String,
    screen: String,
    state: String,
    size: CGSize = GallerySize.standard,
    appearance: RenderAppearance = .light,
    source: String
) throws {
    guard let folder = GalleryOutput.folder else { return }
    // A sheet or popover carries no window of its own, so off-screen it draws
    // on the transparent ground the host clears to. In dark mode its white text
    // then lands on the image viewer's own white and the picture reads blank.
    // Standing it on an opaque window-background colour reproduces the sheet
    // window a person actually sees. The colour is dynamic, so it resolves to
    // the light or dark face from the appearance the capture renders under.
    let grounded = ZStack {
        Color(nsColor: .windowBackgroundColor)
        view
    }
    .ignoresSafeArea()
    let bitmap = try rasterize(grounded, size: size, appearance: appearance)
    try writeGalleryPNG(
        bitmap, folder: folder, area: area, screen: screen, state: state,
        size: size, appearance: appearance, source: source, note: nil)
}

/// The default-window shell, drawn in a titled window so the title bar and any
/// toolbar show, captured off the window's frame view. When the frame view does
/// not draw off-screen it falls back to the content and records that in the
/// index, so a reviewer is never shown a clipped frame without being told.
@MainActor
func galleryShellSnapshot(
    _ view: some View,
    area: String,
    screen: String,
    state: String,
    size: CGSize = GallerySize.standard,
    appearance: RenderAppearance = .light,
    source: String
) throws {
    guard let folder = GalleryOutput.folder else { return }
    // The shell's sidebar sits on a behind-window material that composites over
    // the desktop on a real Mac. Off-screen there is no desktop, so the band
    // comes back white. Standing the shell on the app's own opaque content
    // ground plus its canvas wash reproduces what a person sees — a sidebar in
    // the same tinted canvas as the rest — rather than a white gap. This is a
    // backing behind the shell, not a change to it.
    let grounded = ZStack {
        AgentTheme.contentBackground
        AgentTheme.canvasGradient
        view
    }
    .ignoresSafeArea()
    let (bitmap, note) = try rasterizeTitledWindow(grounded, size: size, appearance: appearance)
    try writeGalleryPNG(
        bitmap, folder: folder, area: area, screen: screen, state: state,
        size: size, appearance: appearance, source: source, note: note)
}

/// Lays a screen out in a titled, full-size-content window with a toolbar, the
/// way the app shows it, and captures the whole frame view so the title bar is
/// in the image. Returns a note when only the content could be captured.
@MainActor
func rasterizeTitledWindow(
    _ view: some View,
    size: CGSize = GallerySize.standard,
    appearance: RenderAppearance = .light
) throws -> (bitmap: NSBitmapImageRep, note: String?) {
    let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(
        contentRect: host.frame,
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.toolbar = NSToolbar(identifier: "gallery")
    window.toolbarStyle = .unifiedCompact
    window.isReleasedWhenClosed = false
    if let nsAppearance = appearance.nsAppearance {
        window.appearance = nsAppearance
        host.appearance = nsAppearance
    }
    // The shell's backdrop is a behind-window material. Off-screen there is no
    // desktop behind it to sample, so the sidebar band comes back clear unless
    // the window gives the material a solid ground to composite over. A real
    // window has the desktop; here the window background colour stands in, so
    // the sidebar draws its glass rather than a white gap. The colour resolves
    // to the right face from the window's own appearance.
    window.isOpaque = true
    window.backgroundColor = .windowBackgroundColor
    window.contentView = host
    window.orderFrontRegardless()
    // A titled window with a toolbar needs more than one turn to settle its
    // chrome and let the glass controls composite; the palette layout test uses
    // the same 0.4s wait against the same window shape.
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    host.layoutSubtreeIfNeeded()

    // The frame view is the whole window, so capturing it keeps the title bar
    // and the toolbar in the image along with the detail. One material cannot
    // follow: the sidebar column's glass is composited by the window server,
    // not by the view's own layer, so a layer cache reads that band back as the
    // window's ground rather than the blurred glass a person sees on a Mac. The
    // ground is the app's own canvas (set below), not a white gap, and the
    // index records the limitation. Everything else — title bar, toolbar, and
    // every pixel of the screen's own content — is captured faithfully.
    let sidebarNote =
        "sidebar column drawn on the app canvas; its behind-window glass does not composite in an off-screen capture"
    if let frameView = window.contentView?.superview,
        frameView.bounds.width > 0, frameView.bounds.height > 0,
        let frame = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
    {
        frameView.cacheDisplay(in: frameView.bounds, to: frame)
        window.orderOut(nil)
        if distinctColours(in: frame) > 4 {
            return (frame, sidebarNote)
        }
    }

    let bitmap = try #require(
        host.bitmapImageRepForCachingDisplay(in: host.bounds),
        "the screen produced no drawable area")
    host.cacheDisplay(in: host.bounds, to: bitmap)
    window.orderOut(nil)
    return (bitmap, "title bar did not draw off-screen; content captured")
}

/// Writes a bitmap as a PNG under `<area>/<file>.png` and records its index row.
/// The file name is `<screen>-<state>-<appearance>-<width>.png`, matching the
/// scheme the task asks for.
@MainActor
private func writeGalleryPNG(
    _ bitmap: NSBitmapImageRep, folder: URL, area: String, screen: String, state: String,
    size: CGSize, appearance: RenderAppearance, source: String, note: String?
) throws {
    let areaSlug = slug(area)
    let fileLeaf = "\(slug(screen))-\(slug(state))-\(appearance == .dark ? "dark" : "light")-\(Int(size.width)).png"
    let areaFolder = folder.appending(path: areaSlug, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: areaFolder, withIntermediateDirectories: true)

    // The frame-view capture is a little taller than the content size because
    // of the title bar, so the PNG is written at the capture's own point size
    // rather than the requested content size, keeping its aspect ratio.
    let pointSize = bitmap.size.width > 0 && bitmap.size.height > 0 ? bitmap.size : size
    let data = try #require(
        pngData(from: bitmap, pointSize: pointSize), "the bitmap had no PNG form")
    try data.write(to: areaFolder.appending(path: fileLeaf))

    GalleryIndex.shared.add(
        GalleryIndexRow(
            area: area, file: "\(areaSlug)/\(fileLeaf)", screen: screen, state: state,
            size: "\(Int(size.width))×\(Int(size.height))",
            appearance: appearance == .dark ? "dark" : "light", source: source, note: note))
}

/// Encodes a capture as PNG at one pixel per point. An off-screen capture comes
/// back at the display's backing scale (2× on this Mac), which quadruples the
/// bytes for no extra legibility in a reference image; the gallery runs on a
/// volume with little room to spare, so it is written at point resolution.
private func pngData(from bitmap: NSBitmapImageRep, pointSize: CGSize) -> Data? {
    let width = Int(pointSize.width.rounded())
    let height = Int(pointSize.height.rounded())
    guard width > 0, height > 0,
        let target = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else {
        // Fall back to the capture as-is rather than losing the image entirely.
        return bitmap.representation(using: .png, properties: [:])
    }
    target.size = pointSize
    guard let context = NSGraphicsContext(bitmapImageRep: target) else {
        return bitmap.representation(using: .png, properties: [:])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    bitmap.draw(in: CGRect(origin: .zero, size: pointSize))
    NSGraphicsContext.restoreGraphicsState()
    return target.representation(using: .png, properties: [:])
}

/// A file-safe slug: lowercased, spaces and separators to hyphens, the
/// middle-dot an area name carries dropped.
private func slug(_ text: String) -> String {
    let lowered = text.lowercased()
        .replacingOccurrences(of: "·", with: "")
        .replacingOccurrences(of: "/", with: "-")
    let mapped = lowered.map { character -> Character in
        character.isLetter || character.isNumber ? character : "-"
    }
    var result = ""
    var lastWasHyphen = false
    for character in mapped {
        if character == "-" {
            if !lastWasHyphen && !result.isEmpty { result.append("-") }
            lastWasHyphen = true
        } else {
            result.append(character)
            lastWasHyphen = false
        }
    }
    while result.hasSuffix("-") { result.removeLast() }
    return result.isEmpty ? "untitled" : result
}
