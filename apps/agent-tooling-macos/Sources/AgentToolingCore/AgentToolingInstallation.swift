import Foundation
import Security

/// Where this copy of Agent Tooling runs from, and whether the helper inside
/// it may be registered with an app.
///
/// An app keeps the helper's path, so only a copy that stays put may hand it
/// out: one in Applications. A copy running from a disk image, from the
/// temporary place macOS translocates a downloaded app to, or from a folder
/// such as Downloads is offered the move to Applications first; a
/// development build is neither moved nor registered.
public struct AgentToolingInstallation: Equatable, Sendable {
    /// Where the bundle is.
    public enum Location: Equatable, Sendable {
        /// In `/Applications` or `~/Applications`: the folder it is in.
        case applications(URL)
        /// On a mounted disk image.
        case diskImage(volumeName: String, volumeURL: URL)
        /// Run from the temporary place macOS moved a downloaded copy to.
        case translocated(URL)
        /// Any other folder: the folder it is in.
        case elsewhere(URL)
        /// Not a packaged app with its helpers, such as a build folder's.
        case developmentBuild
    }

    /// What the system says about the volume a bundle is on.
    public struct VolumeFacts: Equatable, Sendable {
        public var isReadOnly: Bool
        public var name: String?
        /// Where the volume is mounted, when the file system says.
        public var url: URL?

        public init(isReadOnly: Bool, name: String?, url: URL? = nil) {
            self.isReadOnly = isReadOnly
            self.name = name
            self.url = url
        }

        /// The volume `url` is on, as the file system reports it, or nil when
        /// it cannot say.
        public static func live(_ url: URL) -> VolumeFacts? {
            guard let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeNameKey, .volumeURLKey]),
                let isReadOnly = values.volumeIsReadOnly
            else { return nil }
            return VolumeFacts(isReadOnly: isReadOnly, name: values.volumeName, url: values.volume)
        }
    }

    /// A rehearsal of the move on a Mac that is not really running from a
    /// disk image (D41): where this copy should be taken to run from, and a
    /// folder of the rehearsal's own that stands in for Applications.
    ///
    /// It is read from the launch's own arguments, and only from a launch
    /// that also names a scratch workspace with `--workspace`, so an ordinary
    /// launch, or one with a stray flag, is never rehearsing.
    public struct Rehearsal: Equatable, Sendable {
        /// Where `--installation-override` says this copy runs from.
        public enum Override: String, CaseIterable, Sendable {
            case applications
            case diskImage = "disk-image"
            case translocated
            case elsewhere
            case development
        }

        public var override: Override?
        /// `--applications-folder`: a folder taken as Applications, both as
        /// the move's destination and as a stable place to run from.
        public var applicationsFolder: URL?

        public init(override: Override? = nil, applicationsFolder: URL? = nil) {
            self.override = override
            self.applicationsFolder = applicationsFolder
        }

        /// The rehearsal `arguments` ask for, or nil when they ask for none
        /// or name no workspace.
        public static func parse(_ arguments: [String]) -> Rehearsal? {
            var rehearsal = Rehearsal()
            var namesWorkspace = false
            var index = arguments.startIndex
            while index < arguments.endIndex {
                let next = arguments.index(after: index)
                let value = next < arguments.endIndex ? arguments[next] : nil
                switch arguments[index] {
                case "--workspace":
                    namesWorkspace = value.map { !$0.isEmpty && !$0.hasPrefix("--") } ?? false
                case "--installation-override":
                    rehearsal.override = value.flatMap(Override.init(rawValue:))
                case "--applications-folder":
                    if let value, !value.isEmpty, !value.hasPrefix("--") {
                        rehearsal.applicationsFolder = URL(filePath: value, directoryHint: .isDirectory).standardizedFileURL
                    }
                default:
                    break
                }
                index = next
            }
            guard namesWorkspace, rehearsal.override != nil || rehearsal.applicationsFolder != nil else { return nil }
            return rehearsal
        }

        /// The rehearsal this process was launched with, if any.
        public static var launch: Rehearsal? { parse(ProcessInfo.processInfo.arguments) }
    }

    public let bundleURL: URL
    public let location: Location
    /// `Contents/Helpers/agent-tooling-mcp`, when it is a regular executable
    /// inside the bundle.
    public let mcpHelperURL: URL?
    /// `Contents/Helpers/agent-tooling`, the command-line tool, likewise.
    public let cliHelperURL: URL?
    /// True when the bundle carries an ad-hoc signature, as a local build does.
    public let isAdHocSigned: Bool

    public init(bundleURL: URL, location: Location, mcpHelperURL: URL?, cliHelperURL: URL?, isAdHocSigned: Bool) {
        self.bundleURL = bundleURL
        self.location = location
        self.mcpHelperURL = mcpHelperURL
        self.cliHelperURL = cliHelperURL
        self.isAdHocSigned = isAdHocSigned
    }

    /// The helper path an app may keep: only from Applications, only when
    /// the bundle has its helper, and only a path `ConnectAgentToolingCommand`
    /// takes, so what setup offers is always what it can record. An ad-hoc
    /// signed copy there may register.
    public var registrableHelperPath: String? {
        guard case .applications = location, let mcpHelperURL else { return nil }
        let path = mcpHelperURL.path(percentEncoded: false)
        return ConnectAgentToolingCommand.accepts(helperPath: path) ? path : nil
    }

    /// Whether setup offers to move this copy to Applications first. Yes for
    /// a disk image or a translocated copy that has its helpers, and for one
    /// elsewhere unless it is ad-hoc signed — a local build kept in a folder
    /// of its own is left where it is. Never once it is in Applications, and
    /// never for a development build.
    public var offersMove: Bool {
        switch location {
        case .diskImage, .translocated: mcpHelperURL != nil
        case .elsewhere: mcpHelperURL != nil && !isAdHocSigned
        case .applications, .developmentBuild: false
        }
    }

    /// Classifies the running bundle, including translocation and read-only volumes.
    /// Applications on removable volumes cannot supply a persistent helper path.
    /// Helpers must be regular executables resolving inside the bundle; a missing
    /// helper or non-app bundle is a development build. Rehearsal overrides take
    /// precedence and development rehearsals expose no helpers.
    public static func inspect(
        bundleURL: URL,
        homeURL: URL,
        fileManager: FileManager = .default,
        volume: (URL) -> VolumeFacts? = VolumeFacts.live,
        rehearsal: Rehearsal? = Rehearsal.launch,
        isAdHoc: (URL) -> Bool = Self.liveAdHocCheck
    ) -> AgentToolingInstallation {
        let bundle = bundleURL.standardizedFileURL
        let isApp = bundle.pathExtension.lowercased() == "app"
        let helpers = bundle.appending(path: "Contents/Helpers", directoryHint: .isDirectory)
        var mcp = isApp ? helper(helpers.appending(path: "agent-tooling-mcp"), inside: bundle, fileManager: fileManager) : nil
        var cli = isApp ? helper(helpers.appending(path: "agent-tooling"), inside: bundle, fileManager: fileManager) : nil
        let adHoc = isApp ? isAdHoc(bundle) : true
        let folder = bundle.deletingLastPathComponent()

        let location: Location
        if let override = rehearsal?.override {
            switch override {
            case .applications: location = .applications(rehearsal?.applicationsFolder ?? folder)
            case .diskImage:
                location = .diskImage(volumeName: bundle.deletingPathExtension().lastPathComponent, volumeURL: folder)
            case .translocated: location = .translocated(folder)
            case .elsewhere: location = .elsewhere(folder)
            case .development:
                location = .developmentBuild
                mcp = nil
                cli = nil
            }
        } else if !isApp || mcp == nil {
            location = .developmentBuild
        } else if bundle.pathComponents.contains("AppTranslocation") {
            location = .translocated(folder)
        } else if let facts = volume(bundle), facts.isReadOnly {
            let mount = facts.url ?? folder
            location = .diskImage(volumeName: facts.name ?? mount.lastPathComponent, volumeURL: mount)
        } else if applicationsFolders(homeURL: homeURL, rehearsal: rehearsal).contains(realPath(folder)),
            !realPath(folder).hasPrefix("/Volumes/")
        {
            location = .applications(folder)
        } else {
            location = .elsewhere(folder)
        }
        return AgentToolingInstallation(
            bundleURL: bundle, location: location, mcpHelperURL: mcp, cliHelperURL: cli, isAdHocSigned: adHoc)
    }

    /// Whether the bundle at `url` is signed only ad hoc, as a local build
    /// is, or not signed at all: a copy nobody vouched for.
    public static func liveAdHocCheck(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return true }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let details = information as? [String: Any], details[kSecCodeInfoIdentifier as String] != nil
        else { return true }
        let flags = (details[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }

    // MARK: - Reading the bundle

    /// The folders a copy may run from and register its helper from.
    private static func applicationsFolders(homeURL: URL, rehearsal: Rehearsal?) -> Set<String> {
        var folders = [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            homeURL.appending(path: "Applications", directoryHint: .isDirectory),
        ]
        if let folder = rehearsal?.applicationsFolder { folders.append(folder) }
        return Set(folders.map(realPath))
    }

    /// `url` as a regular executable whose real path is inside `bundle`, or
    /// nil.
    private static func helper(_ url: URL, inside bundle: URL, fileManager: FileManager) -> URL? {
        let real = url.resolvingSymlinksInPath()
        let root = realPath(bundle)
        guard real.path(percentEncoded: false).hasPrefix(root + "/"),
            (try? real.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
            fileManager.isExecutableFile(atPath: real.path(percentEncoded: false))
        else { return nil }
        return url
    }

    /// A folder's path with links resolved and no trailing slash, so two
    /// spellings of one folder compare equal.
    private static func realPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
