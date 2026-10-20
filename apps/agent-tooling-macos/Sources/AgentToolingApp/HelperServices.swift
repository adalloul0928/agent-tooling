import AgentToolingCore
import AppKit
import Foundation
import IOKit
import Security
import SwiftUI

/// Everything moving this copy to Applications reaches outside the app
/// through, each with its live default (plan §0.6): where Applications is,
/// what this launch was told about a move that opened it, whether another
/// copy is running, checking a copy's signature, opening a copy, quitting,
/// ejecting a disk image and showing a folder in Finder.
///
/// A test hands in services that record instead, so drawing Before you start
/// or pressing its primary never copies into the real Applications folder,
/// opens an app or ejects anything.
struct HelperServices: Sendable {
    /// Where the move goes: a rehearsal's own folder (`--applications-folder`),
    /// otherwise `/Applications`.
    var applicationsFolder: URL
    /// What `--after-move` says, when a move opened this copy.
    var afterMove: MoveToApplications.AfterMove?
    /// This copy's process, which the copy a move opens waits out.
    var processID: Int32
    /// What the moved copy is opened with besides `--after-move`: this
    /// launch's own scratch folders and rehearsal folder, never its override.
    var forwardedArguments: [String]
    /// This app's bundle identifier, which a disk image must hold before it is
    /// ejected.
    var ownBundleIdentifier: String?
    /// The one bundle these services move, when they move only one: the live
    /// services move this running copy and nothing else, whatever they are
    /// handed. Nil moves whatever copy is asked (a test's scratch bundle).
    var movableBundle: URL?
    /// Whether an app is running from the bundle at the URL, other than this
    /// copy.
    var isRunning: @Sendable (URL) -> Bool
    /// Whether the bundle at the URL is validly signed, strictly.
    var verifySignature: @Sendable (URL) -> Bool
    /// Sends the older copy a move replaces to the Trash.
    var trash: @Sendable (URL) throws -> Void
    /// Opens the app at the URL as a new instance, with these arguments: a
    /// rehearsal's copy from its own executable, any other through
    /// LaunchServices.
    var open: @MainActor @Sendable (URL, [String]) async throws -> Void
    /// Quits this copy.
    var terminate: @MainActor @Sendable () -> Void
    /// Whether the process is still running.
    var processIsAlive: @Sendable (Int32) -> Bool
    /// What the file system says about the volume at the URL.
    var volumeFacts: @Sendable (URL) -> AgentToolingInstallation.VolumeFacts?
    /// The bundle identifier of the app at the URL.
    var bundleIdentifier: @Sendable (URL) -> String?
    /// Unmounts and ejects the volume at the URL.
    var eject: @Sendable (URL) async throws -> Void
    /// Shows the URL in Finder.
    var reveal: @MainActor @Sendable (URL) -> Void
    /// The disk image file a mounted volume was opened from, when the system
    /// says.
    var diskImageFile: @Sendable (URL) -> URL?
    /// Waits, as the copy a move opened waits for the old one to quit.
    var pause: @Sendable (Duration) async throws -> Void
    /// A rehearsal that names no scratch Applications folder of its own: the
    /// move then refuses to act at all rather than touch the real
    /// `/Applications` (D41).
    var refusesMove = false
    /// Where macOS translocated the bundle at the URL from, as the read-only
    /// mount it runs a translocated copy from says: the app it was opened
    /// as, or the folder holding it. Nil for a bundle that is not translocated.
    var translocationSource: @Sendable (URL) -> URL? = { _ in nil }

    /// The services as the app runs, from this launch's own arguments.
    static var live: HelperServices { live(arguments: ProcessInfo.processInfo.arguments) }

    /// The services for a launch with `arguments`, the executable first, read
    /// as `LaunchContext` reads them: the launch's one reading of its
    /// rehearsal flags and of `--after-move`.
    static func live(arguments: [String]) -> HelperServices {
        let launch = LaunchContext(arguments: arguments)
        return HelperServices(
            applicationsFolder: launch.applicationsFolder ?? URL(filePath: "/Applications", directoryHint: .isDirectory),
            afterMove: MoveToApplications.AfterMove(launch.afterMove),
            processID: ProcessInfo.processInfo.processIdentifier,
            forwardedArguments: forwarded(arguments),
            ownBundleIdentifier: Bundle.main.bundleIdentifier,
            movableBundle: Bundle.main.bundleURL,
            isRunning: { bundle in
                let wanted = bundle.standardizedFileURL.resolvingSymlinksInPath()
                guard let identifier = Bundle(url: bundle)?.bundleIdentifier else { return false }
                let current = ProcessInfo.processInfo.processIdentifier
                return NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains {
                    $0.processIdentifier != current
                        && $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == wanted
                }
            },
            // Only a copy signed as this running one is, which a copy of it
            // always is, is ever swapped in: not some other validly signed app
            // put in its place between the launch and the copy.
            verifySignature: { liveSignatureCheck($0, requirement: ownDesignatedRequirement()) },
            trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
            open: { app, arguments in
                if startsDirectly(arguments) {
                    try startDirectly(app, arguments: arguments)
                    return
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                configuration.activates = true
                configuration.arguments = arguments
                _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            },
            terminate: { NSApp.terminate(nil) },
            processIsAlive: { process in kill(process, 0) == 0 || errno == EPERM },
            volumeFacts: AgentToolingInstallation.VolumeFacts.live,
            bundleIdentifier: { Bundle(url: $0)?.bundleIdentifier },
            eject: { volume in
                try await FileManager.default.unmountVolume(at: volume, options: [.allPartitionsAndEjectDisk, .withoutUI])
            },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            diskImageFile: liveDiskImageFile,
            pause: { try await Task.sleep(for: $0) },
            refusesMove: launch.installationOverride != nil && launch.applicationsFolder == nil,
            translocationSource: liveTranslocationSource)
    }

    /// The pairs of this launch's arguments a moved copy keeps: the scratch
    /// workspace and home, the defaults suite, the rehearsal's Applications
    /// folder, and the state-restoration switch a rehearsal sets.
    static func forwarded(_ arguments: [String]) -> [String] {
        let kept: Set<String> = [
            "--workspace", "--home", "--defaults-suite", "--applications-folder", "-ApplePersistenceIgnoreState",
        ]
        var result: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let next = arguments.index(after: index)
            if kept.contains(arguments[index]), next < arguments.endIndex {
                result += [arguments[index], arguments[next]]
                index = arguments.index(after: next)
            } else {
                index = next
            }
        }
        return result
    }

    /// Whether a copy opened with these arguments is started from its own
    /// executable rather than through LaunchServices: one told to use a
    /// rehearsal's scratch workspace or home. LaunchServices has been seen to
    /// drop the arguments of a launch, and a rehearsal's copy without them
    /// would open the real workspace.
    static func startsDirectly(_ arguments: [String]) -> Bool {
        let scratch = forwarded(arguments)
        return scratch.contains("--workspace") || scratch.contains("--home")
    }

    /// Starts the app's own executable with exactly these arguments. It reads
    /// nothing from this copy's terminal and writes nothing to it, so it runs
    /// on once this copy has quit.
    static func startDirectly(_ app: URL, arguments: [String]) throws {
        let info = app.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let name = plist["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/")
        else { throw CocoaError(.executableNotLoadable) }
        let process = Process()
        process.executableURL = app.appending(path: "Contents/MacOS/\(name)")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Whether the bundle at `url` passes a strict check of its signature,
    /// nested code and every architecture included, and, given a
    /// `requirement`, is signed as it says. The requirement is held against
    /// the architecture this Mac runs: an ad-hoc build's names its own code's
    /// hash, which each architecture has its own of.
    static func liveSignatureCheck(_ url: URL, requirement: SecRequirement? = nil) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, strict, nil) == errSecSuccess else { return false }
        guard let requirement else { return true }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The requirement this running copy's own signature names (its
    /// identifier and team for a signed release, its code's own hash for an
    /// ad-hoc build), or nil when it is not signed. A copy of it meets it;
    /// another app does not.
    static func ownDesignatedRequirement() -> SecRequirement? {
        var running: SecCode?
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
            SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code,
            SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess
        else { return nil }
        return requirement
    }

    /// Where macOS translocated the bundle at `url` from: a translocated copy
    /// runs from a read-only `nullfs` mount, and the mount names its source.
    /// Nil for any other bundle.
    static func liveTranslocationSource(_ url: URL) -> URL? {
        var stats = statfs()
        guard statfs(url.path(percentEncoded: false), &stats) == 0 else { return nil }
        let type = withUnsafeBytes(of: &stats.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let source = withUnsafeBytes(of: &stats.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard type == "nullfs", source.hasPrefix("/") else { return nil }
        return URL(filePath: source, directoryHint: .isDirectory)
    }

    /// The disk image a mounted volume came from: the volume's device, then
    /// up the registry to the disk image driver's own record of its file.
    /// Nothing is run; the registry is only read.
    static func liveDiskImageFile(_ volume: URL) -> URL? {
        var stats = statfs()
        guard statfs(volume.path(percentEncoded: false), &stats) == 0 else { return nil }
        let device = withUnsafeBytes(of: &stats.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let name = device.hasPrefix("/dev/") ? String(device.dropFirst("/dev/".count)) : device
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, name) else { return nil }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }
        let upward = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        if let path = IORegistryEntrySearchCFProperty(media, kIOServicePlane, "image-path" as CFString, kCFAllocatorDefault, upward) {
            if let data = path as? Data { return URL(filePath: String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)) }
            if let text = path as? String { return URL(filePath: text) }
        }
        if let address = IORegistryEntrySearchCFProperty(media, kIOServicePlane, "DiskImageURL" as CFString, kCFAllocatorDefault, upward)
            as? String, let url = URL(string: address), url.isFileURL
        {
            return url
        }
        return nil
    }
}

extension EnvironmentValues {
    /// How Before you start moves this copy. A render or a gallery capture
    /// hands in services that record, so drawing it never moves anything.
    @Entry var helperServices: HelperServices = .live
}
