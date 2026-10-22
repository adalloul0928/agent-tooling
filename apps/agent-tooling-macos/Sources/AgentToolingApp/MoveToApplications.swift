import AgentToolingCore
import AppKit
import Foundation

/// Moves this app to Applications after copying and verifying its signature.
/// The verified copy has quarantine removed before the swap. A running copy is
/// never replaced; an older copy is retained until the swap succeeds, then trashed.
/// Cancellation before the swap removes the partial copy; after it, the installed
/// copy remains unopened. Rehearsals require a scratch Applications folder.
/// The new instance waits for the old process to exit before ejecting a read-only
/// disk image that contains this app.
@MainActor
final class MoveToApplications {
    /// Where the move would go, and what is already there.
    struct Plan: Equatable {
        /// `<Applications>/Agent Tooling.app`.
        let destination: URL
        /// A copy already at the destination, if one is.
        let existing: URL?
        /// That copy's version, when it says.
        let existingVersion: String?
    }

    /// How a move ended.
    enum Outcome: Equatable {
        /// Copied and verified; the new copy is opening and this one quits.
        case relaunching
        /// Another copy is already in Applications: replacing it needs a yes.
        case needsReplaceConfirmation(existingVersion: String?)
        /// The copy in Applications is the same or newer: open that instead.
        case openExistingInstead(URL)
        /// Nothing was moved, and why.
        case failed(String)
    }

    /// What `--after-move <pid> <volume>` tells the copy a move opened: the
    /// process that made the move, and the disk image it ran from, if any.
    struct AfterMove: Equatable, Sendable {
        let previousProcess: Int32
        let volume: URL?

        /// The arguments the moved copy is opened with.
        var arguments: [String] {
            ["--after-move", String(previousProcess), volume?.path(percentEncoded: false) ?? ""]
        }

        /// What a launch said about a move that opened it, as `LaunchContext`
        /// read it: the launch's one reading of its arguments. Nil when no
        /// move opened it, or when it names no process that could be one.
        init?(_ launch: LaunchContext.AfterMove?) {
            guard let launch, launch.pid > 0 else { return nil }
            self.init(previousProcess: launch.pid, volume: launch.volume)
        }

        init(previousProcess: Int32, volume: URL?) {
            self.previousProcess = previousProcess
            self.volume = volume
        }

        /// What a launch's arguments (the executable first, as in
        /// `ProcessInfo.arguments`) say about a move that opened it, or nil.
        static func parse(_ arguments: [String]) -> AfterMove? {
            AfterMove(LaunchContext(arguments: arguments).afterMove)
        }
    }

    let installation: AgentToolingInstallation
    let services: HelperServices
    private let applicationsFolder: URL
    private let fileManager: FileManager

    /// How long the copy a move opened waits for the old one to quit before
    /// it leaves the disk image mounted, and how often it looks.
    static let afterMoveWait: Duration = .seconds(30)
    static let afterMovePoll: Duration = .milliseconds(200)

    /// `applicationsFolder` defaults to the services' own: `/Applications`,
    /// or a rehearsal's folder.
    init(
        installation: AgentToolingInstallation, applicationsFolder: URL? = nil, fileManager: FileManager = .default,
        services: HelperServices = .live
    ) {
        self.installation = installation
        self.applicationsFolder = applicationsFolder ?? services.applicationsFolder
        self.fileManager = fileManager
        self.services = services
    }

    /// Where the move would go. Reads only.
    func plan() -> Plan {
        let destination = applicationsFolder.appending(path: installation.bundleURL.lastPathComponent, directoryHint: .isDirectory)
        let exists = fileManager.fileExists(atPath: destination.path(percentEncoded: false))
        return Plan(
            destination: destination, existing: exists ? destination : nil,
            existingVersion: exists ? Self.shortVersion(of: destination) : nil)
    }

    /// This copy's version, as its bundle says.
    var version: String? { Self.shortVersion(of: installation.bundleURL) }

    /// Whether the copy already in Applications is Agent Tooling, this
    /// version or newer, so opening it is better than replacing it. An app
    /// under the same name that is not Agent Tooling (another bundle
    /// identifier) is never opened as if it were.
    func existingIsCurrent(_ plan: Plan) -> Bool {
        guard let app = plan.existing, let existing = plan.existingVersion, let mine = version,
            services.ownBundleIdentifier.map({ services.bundleIdentifier(app) == $0 }) ?? true
        else { return false }
        return existing.compare(mine, options: .numeric) != .orderedAscending
    }

    /// Makes the move: copy, check, clear the quarantine flag, swap, open the
    /// copy and quit. An older copy in Applications is replaced only when
    /// `replacingExisting`; the same or a newer one is opened instead.
    ///
    /// A cancelled move (a quit while it ran) stops at the next safe point:
    /// before the swap the copy is removed and nothing has changed; after it
    /// the copy stays in Applications and is not opened. `beforeOpening` runs
    /// once the files are in place, just before the copy is opened.
    func move(replacingExisting: Bool, beforeOpening: @MainActor () -> Void = {}) async -> Outcome {
        let plan = plan()
        let failed = Outcome.failed(LaunchpadCopy.Helper.Failures.notMoved)
        guard !services.refusesMove, isThisCopy else { return failed }
        if let existing = plan.existing {
            if existingIsCurrent(plan) { return .openExistingInstead(existing) }
            guard replacingExisting else { return .needsReplaceConfirmation(existingVersion: plan.existingVersion) }
            guard !services.isRunning(existing) else { return .failed(LaunchpadCopy.Helper.Failures.otherCopyOpen) }
        }
        let stamp = UUID().uuidString
        let partial = applicationsFolder.appending(path: ".\(plan.destination.lastPathComponent).partial-\(stamp)")
        // The older copy is set aside under its own name, so the Trash shows
        // it as what it is and it can be put back from there.
        let asideFolder = applicationsFolder.appending(path: ".agent-tooling-previous-\(stamp)", directoryHint: .isDirectory)
        let aside = asideFolder.appending(path: plan.destination.lastPathComponent, directoryHint: .isDirectory)
        do {
            try await Self.copy(installation.bundleURL, to: partial)
            try Task.checkCancellation()
            // A strict check of a whole app takes a moment: off the main actor
            // too, so the stage keeps drawing "Moving…".
            let verify = services.verifySignature
            guard await Task.detached(operation: { verify(partial) }).value else { throw CocoaError(.fileReadCorruptFile) }
            try await Self.removeQuarantine(in: partial)
            try Task.checkCancellation()
        } catch {
            try? fileManager.removeItem(at: partial)
            return failed
        }
        do {
            if let existing = plan.existing {
                guard !services.isRunning(existing) else {
                    try? fileManager.removeItem(at: partial)
                    return .failed(LaunchpadCopy.Helper.Failures.otherCopyOpen)
                }
                try fileManager.createDirectory(at: asideFolder, withIntermediateDirectories: false)
                try fileManager.moveItem(at: existing, to: aside)
            }
            do {
                try fileManager.moveItem(at: partial, to: plan.destination)
            } catch {
                if plan.existing != nil { try? fileManager.moveItem(at: aside, to: plan.destination) }
                throw error
            }
        } catch {
            try? fileManager.removeItem(at: partial)
            Self.removeIfEmpty(asideFolder)
            return failed
        }
        if plan.existing != nil {
            try? services.trash(aside)
            Self.removeIfEmpty(asideFolder)
        }
        guard !Task.isCancelled else { return .failed(LaunchpadCopy.Helper.openFromApplications) }
        beforeOpening()
        return await open(plan.destination)
    }

    /// Opens the copy at `app` (the one just moved, or the same or newer one
    /// already in Applications) as a new instance told about this move, then
    /// quits this one. A copy there that is already open is not started a
    /// second time beside it, over the same library: the person is asked to
    /// quit it first, and nothing quits.
    func open(_ app: URL) async -> Outcome {
        guard !services.refusesMove, isThisCopy else { return .failed(LaunchpadCopy.Helper.Failures.notMoved) }
        guard !services.isRunning(app) else { return .failed(LaunchpadCopy.Helper.Failures.otherCopyOpen) }
        let afterMove = AfterMove(previousProcess: services.processID, volume: diskImageVolume)
        do {
            try await services.open(app, afterMove.arguments + services.forwardedArguments)
        } catch {
            return .failed(LaunchpadCopy.Helper.openFromApplications)
        }
        services.terminate()
        return .relaunching
    }

    /// Whether the copy being moved is the one the services may move: the
    /// live services move this running copy and nothing else, so no other
    /// copy is ever opened, and this one quit, on its account.
    private var isThisCopy: Bool {
        guard let only = services.movableBundle else { return true }
        return only.standardizedFileURL.resolvingSymlinksInPath()
            == installation.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The disk image the opened copy ejects: the volume this copy runs
    /// from, or, for a copy macOS translocated, the volume it was opened from
    /// when that is a read-only one that holds this app. Nil for any other
    /// copy.
    var diskImageVolume: URL? {
        switch installation.location {
        case .diskImage(_, let volume):
            return volume
        case .translocated:
            // macOS runs a translocated copy from a read-only mount of where
            // it was opened, which names that place: the app itself, or the
            // folder holding it.
            guard let source = services.translocationSource(installation.bundleURL) else { return nil }
            let volume = source.pathExtension.lowercased() == "app" ? source.deletingLastPathComponent() : source
            return Self.holdsThisApp(volume, services: services) ? volume : nil
        case .applications, .elsewhere, .developmentBuild:
            return nil
        }
    }

    // MARK: - After the move

    /// Run by the copy a move opened, once it has launched: waits for the old
    /// copy to quit, then ejects the disk image it ran from, as the launch's
    /// `--after-move` names them.
    static func finishAfterMove(_ context: LaunchContext) async {
        await finishAfterMove(AfterMove(context.afterMove), services: .live)
    }

    /// The same, with what the launch said and the services to act through.
    /// Nothing is ejected unless the old process has ended and the volume is
    /// a read-only disk image mounted there that holds this app.
    static func finishAfterMove(_ afterMove: AfterMove?, services: HelperServices) async {
        guard let afterMove else { return }
        var waited: Duration = .zero
        while services.processIsAlive(afterMove.previousProcess), waited < afterMoveWait {
            try? await services.pause(afterMovePoll)
            waited += afterMovePoll
        }
        guard !services.processIsAlive(afterMove.previousProcess), let volume = afterMove.volume,
            holdsThisApp(volume, services: services)
        else { return }
        try? await services.eject(volume)
    }

    /// Whether `volume` is a read-only mount of a disk image with this app at
    /// its top level: the only kind of volume a move ever ejects. A locked
    /// card, a read-only stick or share holding the app is no disk image,
    /// and ejecting it would take every partition of that disk with it.
    static func holdsThisApp(_ volume: URL, services: HelperServices) -> Bool {
        guard let facts = services.volumeFacts(volume), facts.isReadOnly,
            let mount = facts.url, mount.standardizedFileURL.path == volume.standardizedFileURL.path,
            services.diskImageFile(volume) != nil,
            let identifier = services.ownBundleIdentifier,
            let entries = try? FileManager.default.contentsOfDirectory(at: volume, includingPropertiesForKeys: nil)
        else { return false }
        return entries.contains { $0.pathExtension == "app" && services.bundleIdentifier($0) == identifier }
    }

    // MARK: - The files

    /// A bundle's `CFBundleShortVersionString`, read from its Info.plist each
    /// time rather than from a cached `Bundle`.
    nonisolated static func shortVersion(of bundle: URL) -> String? {
        let info = bundle.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    /// Copies the bundle off the main actor: a copy of an app takes a moment.
    private nonisolated static func copy(_ source: URL, to destination: URL) async throws {
        try await Task.detached { try FileManager().copyItem(at: source, to: destination) }.value
    }

    /// Removes `folder` only when nothing is left in it: the folder an older
    /// copy was set aside in is never removed with that copy inside.
    private static func removeIfEmpty(_ folder: URL) {
        _ = rmdir(folder.path(percentEncoded: false))
    }

    /// Takes the quarantine flag off every file and folder in the copy, the
    /// copy itself included.
    nonisolated static func removeQuarantine(in bundle: URL) async throws {
        try await Task.detached { try stripQuarantine(bundle) }.value
    }

    /// The walk itself, which a directory enumerator does synchronously. A
    /// link inside the bundle (a framework's `Versions/Current`) is not what
    /// macOS checks, so a link that keeps its flag is no failure; a file or a
    /// folder that keeps one is.
    private nonisolated static func stripQuarantine(_ bundle: URL) throws {
        var items: [(path: String, isLink: Bool)] = [(bundle.path(percentEncoded: false), false)]
        if let walk = FileManager().enumerator(at: bundle, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in walk {
                let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
                items.append((url.path(percentEncoded: false), isLink))
            }
        }
        for item in items where removexattr(item.path, quarantineAttribute, XATTR_NOFOLLOW) != 0 {
            guard errno != ENOATTR, !item.isLink else { continue }
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    /// The extended attribute macOS marks a download with.
    nonisolated static let quarantineAttribute = "com.apple.quarantine"
}
