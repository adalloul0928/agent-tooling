import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Optional PNG gallery, enabled by AGENT_TOOLING_SCREEN_GALLERY. Reuses
/// ShellRenderHarness rasterization with explicit size and appearance.
/// Writes a shared index at process exit because serialized suites cannot
/// identify the final test.

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
    /// The setup stage's own window.
    static let stage = WindowSize.stage
}

/// The window a capture is drawn in: the shell's, with its toolbar, or the
/// setup stage's, a titled window with no toolbar and its zoom button off.
enum GalleryWindowChrome {
    case shell
    case stage
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
        "Launchpad",
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
    source: String,
    note: String? = nil
) throws {
    guard let folder = GalleryOutput.folder else { return }
    let (bitmap, captured) = try GalleryWindow(shellGround(view), size: size, appearance: appearance, chrome: .shell).capture()
    try writeGalleryPNG(
        bitmap, folder: folder, area: area, screen: screen, state: state,
        size: size, appearance: appearance, source: source, note: joinedNote(note, captured))
}

/// `galleryShellSnapshot`, captured once `isSettled` holds for the window's
/// content as VoiceOver reads it. Between looks the main actor is let go, so
/// what a view starts in a task (a read off the main actor, then a change of
/// its own state) lands before the capture; a capture made while the test
/// holds the main actor never sees it. Fails when it has not held after a
/// few seconds, so a state that never draws cannot pass as one that did.
@MainActor
func galleryShellSnapshot(
    _ view: some View,
    area: String,
    screen: String,
    state: String,
    size: CGSize = GallerySize.standard,
    appearance: RenderAppearance = .light,
    source: String,
    note: String? = nil,
    until isSettled: @MainActor (AccessibilityProbe) -> Bool
) async throws {
    guard let folder = GalleryOutput.folder else { return }
    let window = try GalleryWindow(shellGround(view), size: size, appearance: appearance, chrome: .shell)
    try await window.settle(until: isSettled, what: "\(screen) · \(state)")
    let (bitmap, captured) = try window.capture()
    try writeGalleryPNG(
        bitmap, folder: folder, area: area, screen: screen, state: state,
        size: size, appearance: appearance, source: source, note: joinedNote(note, captured))
}

/// A capture's own note, then what its capture could not draw.
private func joinedNote(_ own: String?, _ captured: String?) -> String? {
    let notes = [own, captured].compactMap(\.self)
    return notes.isEmpty ? nil : notes.joined(separator: "; ")
}

/// The shell on the app's own opaque content ground and its canvas wash. The
/// sidebar's behind-window material has no desktop to blur off screen; this
/// backing is the canvas a person sees beside it, not a change to the shell.
/// The sidebar column itself still comes back white in both appearances,
/// with nothing of its own drawn in it (the index's note says so).
@MainActor
private func shellGround(_ view: some View) -> some View {
    ZStack {
        AgentTheme.contentBackground
        AgentTheme.canvasGradient
        view
    }
    .ignoresSafeArea()
}

/// Captures setup in its configured native window, including title bar and
/// traffic lights. Uses an opaque ground-colour backing because behind-window
/// material does not composite off-screen; the gallery index records this limit.
@MainActor
func galleryStageSnapshot(
    _ view: some View,
    screen: String,
    state: String,
    appearance: RenderAppearance = .light,
    source: String
) throws {
    guard let folder = GalleryOutput.folder else { return }
    let grounded = ZStack {
        AgentTheme.stageGroundOpaque
        view
    }
    .background(WindowConfigurator(role: .setup))
    .ignoresSafeArea()
    let (bitmap, note) = try rasterizeTitledWindow(grounded, size: GallerySize.stage, appearance: appearance, chrome: .stage)
    let stageNote =
        "stage ground drawn on an opaque backing; its behind-window material does not composite off-screen, "
        + "and an off-screen window is never key, so the accent primary and glass buttons draw as an inactive window's"
    try writeGalleryPNG(
        bitmap, folder: folder, area: "Launchpad", screen: screen, state: state, size: GallerySize.stage,
        appearance: appearance, source: source, note: note.map { "\(stageNote); \($0)" } ?? stageNote)
}

/// Lays a screen out in a titled, full-size-content window with a toolbar, the
/// way the app shows it, and captures the whole frame view so the title bar is
/// in the image. Returns a note when only the content could be captured. The
/// stage's chrome has no toolbar and does not resize; its zoom button is
/// turned off by the stage's own `WindowConfigurator`, which the stage's
/// capture carries.
@MainActor
func rasterizeTitledWindow(
    _ view: some View,
    size: CGSize = GallerySize.standard,
    appearance: RenderAppearance = .light,
    chrome: GalleryWindowChrome = .shell
) throws -> (bitmap: NSBitmapImageRep, note: String?) {
    try GalleryWindow(view, size: size, appearance: appearance, chrome: chrome).capture()
}

/// A screen in a titled, full-size-content window on screen, laid out and
/// settled, until it is captured.
@MainActor
private final class GalleryWindow {
    private let window: NSWindow
    private let host: NSHostingView<AnyView>
    private let size: CGSize
    private let chrome: GalleryWindowChrome

    /// At most this many looks, a short turn of the run loop apart, before a
    /// settling capture gives up: about five seconds.
    private static let looks = 100
    private static let lookTurn: TimeInterval = 0.05

    init(_ view: some View, size: CGSize, appearance: RenderAppearance, chrome: GalleryWindowChrome) throws {
        self.size = size
        self.chrome = chrome
        host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(
            contentRect: host.frame,
            styleMask: chrome == .stage
                ? [.titled, .closable, .miniaturizable, .fullSizeContentView]
                : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        switch chrome {
        case .shell:
            window.toolbar = NSToolbar(identifier: "gallery")
            window.toolbarStyle = .unifiedCompact
        case .stage:
            // The stage sizes its window itself (below), so the hosted content
            // must not ask the window for a content area of its own size.
            host.sizingOptions = []
        }
        window.isReleasedWhenClosed = false
        if let nsAppearance = appearance.nsAppearance {
            window.appearance = nsAppearance
            host.appearance = nsAppearance
        }
        // The shell's backdrop is a behind-window material. Off-screen there
        // is no desktop behind it to sample; the window's opaque background
        // colour is the ground it has instead. (The sidebar column still comes
        // back white: see `shellGround`.)
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        if chrome == .stage {
            // The stage's window is exactly its size, its content under the title
            // bar. Made from a content rectangle, a titled window adds the title
            // bar's height on top, which would leave a strip under the footer that
            // the real stage does not have.
            window.setFrame(CGRect(origin: .zero, size: size), display: false)
        }
        window.orderFrontRegardless()
        // A titled window with a toolbar needs more than one turn to settle its
        // chrome and let the glass controls composite; the palette layout test uses
        // the same 0.4s wait against the same window shape.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        if chrome == .stage {
            // The capture's chrome is the stage's own: its configurator ran.
            try #require(window.identifier == AppWindow.setup.identifier, "the stage's window configuration did not run")
            #expect(window.standardWindowButton(.zoomButton)?.isEnabled == false, "the stage's zoom button is on")
            #expect(window.collectionBehavior.contains(.fullScreenNone), "the stage can go full screen")
            #expect(window.tabbingMode == .disallowed, "the stage takes tabs")
        }
    }

    /// Looks again until `isSettled` holds, letting the main actor go between
    /// looks so a view's own tasks can land.
    func settle(until isSettled: @MainActor (AccessibilityProbe) -> Bool, what: String) async throws {
        let probe = AccessibilityProbe(reading: window)
        var looked = 0
        while !isSettled(probe), looked < Self.looks {
            await Task.yield()
            turn()
            looked += 1
        }
        let settled = isSettled(probe)
        if !settled { window.orderOut(nil) }
        try #require(settled, "\(what) never drew what its capture waits for")
    }

    private func turn() {
        RunLoop.current.run(until: Date().addingTimeInterval(Self.lookTurn))
        host.layoutSubtreeIfNeeded()
    }

    /// Captures the window and takes it off screen.
    func capture() throws -> (bitmap: NSBitmapImageRep, note: String?) {
        // Include the title bar and toolbar. Behind-window glass cannot
        // composite off-screen; the shell uses its canvas there instead.
        let sidebarNote: String? =
            chrome == .shell
            ? "sidebar column drawn on the app canvas; its behind-window glass does not composite in an off-screen capture"
            : nil
        if let frameView = window.contentView?.superview,
            frameView.bounds.width > 0, frameView.bounds.height > 0,
            let frame = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
        {
            frameView.cacheDisplay(in: frameView.bounds, to: frame)
            window.orderOut(nil)
            if chrome == .stage {
                // Crops against the mockups' 860 × 640 stage line up only if the
                // capture is that size too.
                try #require(frame.size == size, "the stage captured at \(frame.size), not \(size)")
            }
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
