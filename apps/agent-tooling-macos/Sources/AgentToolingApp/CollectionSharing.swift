import AgentToolingCore
import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A zero-size view whose only job is to give the Share Sheet somewhere to
/// point, so the popover comes out of the button a person pressed rather than
/// a corner of the window.
@MainActor
final class ShareAnchor {
    fileprivate weak var view: NSView?

    /// AirDrop, Mail, Messages and everything else the Mac already knows how
    /// to do — with no server to run and no account to create. The two
    /// products in this space that bet on hosted sharing are both gone; the
    /// file is what survives.
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

enum CollectionFileExport {
    /// Asks where to put the file. Returning `nil` means the person cancelled,
    /// which is not an error and must not surface as one.
    @MainActor
    static func chooseDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Collection"
        panel.prompt = "Export"
        panel.message = CollectionExportDocument.securityNote
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Stages the file for sharing in its own temporary folder, so the name a
    /// recipient sees is the collection's name rather than a UUID.
    static func stageForSharing(named name: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "agent-tooling-share-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        try data.write(to: url, options: [.atomic])
        return url
    }
}
