import AppKit
import Foundation
import SwiftUI

/// A zero-size view whose only job is to give the Share Sheet somewhere to
/// point, so the popover comes out of the button a person pressed rather than
/// a corner of the window.
///
/// Ported from the old Collections screen: AirDrop, Mail, Messages and
/// everything else the Mac already knows how to do, with no server to run and
/// no account to create.
@MainActor
final class ShareAnchor {
    fileprivate weak var view: NSView?

    func present(_ urls: [URL]) {
        guard let view, !urls.isEmpty else { return }
        NSSharingServicePicker(items: urls).show(relativeTo: .zero, of: view, preferredEdge: .minY)
    }
}

struct ShareAnchorView: NSViewRepresentable {
    let anchor: ShareAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

/// Where a package export goes: a folder the person chose, or a temporary one
/// staged for the share sheet.
///
/// A preset export is one member at a time — `WorkspacePackageExportSession`
/// writes one artifact's approved content as a folder, so sharing "a preset's
/// members" means choosing the member first, the same way the old screen let
/// someone export or share one collection at a time.
enum PackageFileExport {
    /// Asks where to write the package. Returning `nil` means the person
    /// cancelled, which is not an error and must not surface as one.
    @MainActor
    static func chooseDestinationFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Export Package"
        panel.prompt = "Export"
        panel.message = "Choose a folder on this Mac to write the package into."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    /// A fresh folder for the share sheet, so the export is a byte-for-byte
    /// snapshot rather than a live link — later changes here never reach
    /// anyone the folder is shared with.
    static func stagingFolder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "agent-tooling-share-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
