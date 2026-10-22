import Foundation

/// Resource paths are resolved at runtime so binaries contain no build-machine path.
enum AppResources {
    private final class BundleToken: NSObject {}
    private static let resourceBundleName = "AgentTooling_AgentToolingApp.bundle"

    static let bundle: Bundle =
        packagedBundle(in: .main)
        ?? developmentBundle(executableURL: Bundle.main.executableURL, codeBundleURL: Bundle(for: BundleToken.self).bundleURL)
        ?? .main

    static func packagedBundle(in application: Bundle) -> Bundle? {
        guard let url = application.url(forResource: "AgentTooling_AgentToolingApp", withExtension: "bundle") else { return nil }
        return Bundle(url: url)
    }

    static func developmentBundle(executableURL: URL?, codeBundleURL: URL) -> Bundle? {
        let directories = [
            executableURL?.deletingLastPathComponent(),
            codeBundleURL,
            codeBundleURL.deletingLastPathComponent(),
        ].compactMap { $0 }
        return directories.lazy.compactMap { directory in
            Bundle(url: directory.appending(path: resourceBundleName, directoryHint: .isDirectory))
        }.first
    }

    @MainActor
    static func verifyPackagedResources() throws {
        guard let packaged = packagedBundle(in: .main),
            bundle.bundleURL.resolvingSymlinksInPath() == packaged.bundleURL.resolvingSymlinksInPath()
        else { throw VerificationError.missing("the app's resource bundle") }

        try verifyNotices(in: bundle)
        try verifyStarterShelf()
    }

    static func verifyNotices(in resourceBundle: Bundle) throws {
        guard let url = resourceBundle.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
            let notices = try? String(contentsOf: url, encoding: .utf8),
            !notices.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw VerificationError.missing("third-party notices") }
    }

    /// Validate bundled public listings without contacting their catalogs.
    @MainActor
    static func verifyStarterShelf() throws {
        let entries: [StarterShelf.Entry]
        do { entries = try StarterShelf.entries() } catch { throw VerificationError.missing("the starter shelf") }
        guard !entries.isEmpty else { throw VerificationError.missing("the starter shelf") }
        for entry in entries {
            guard StarterShelf.package(for: entry, retained: nil) != nil else { throw VerificationError.missing(entry.name) }
        }
    }

    private enum VerificationError: LocalizedError {
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .missing(let name): "Could not load \(name) from the packaged app."
            }
        }
    }
}
