import AgentToolingCore
import AgentToolingTestSupport
import Foundation

@testable import AgentToolingApp

/// Before you start's outside world, recorded: every copy it opens, every
/// quit, eject, reveal and trip to the Trash is written down instead of done,
/// so a test or a gallery capture moves into a scratch folder and nothing on
/// this Mac opens, quits or ejects. What the system would answer (whether a
/// copy runs, whether a signature holds, whether the old process is still
/// alive, what a volume is) is the test's to set.
final class HelperRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var openedApps: [(app: URL, arguments: [String])] = []
    private var quits = 0
    private var ejects: [URL] = []
    private var reveals: [URL] = []
    private var trashes: [URL] = []
    private var aliveAnswers: Int
    /// Where `trash` puts what it is given: a folder of the test's own.
    let trashFolder: URL
    /// The bundles reported running, by path.
    var running: Set<String> = []
    var signatureHolds = true
    var openFails = false
    /// What the volume check answers.
    var volume: AgentToolingInstallation.VolumeFacts?
    /// The disk image file a volume came from.
    var image: URL?
    /// The bundle identifier of every app asked about.
    var bundleIdentifier: String?

    /// `aliveFor` is how many times the old process answers that it is still
    /// running before it has quit.
    init(trashFolder: URL, aliveFor: Int = 0) {
        self.trashFolder = trashFolder
        aliveAnswers = aliveFor
    }

    var opened: [(app: URL, arguments: [String])] { lock.withLock { openedApps } }
    var terminated: Int { lock.withLock { quits } }
    var ejected: [URL] { lock.withLock { ejects } }
    var revealed: [URL] { lock.withLock { reveals } }
    var trashed: [URL] { lock.withLock { trashes } }

    /// The services, with the move going to `applications`.
    func services(
        applications: URL, afterMove: MoveToApplications.AfterMove? = nil, processID: Int32 = 4242,
        forwarded: [String] = ["--workspace", "/tmp/qa/ws"], ownBundleIdentifier: String? = "dev.agenttooling.app"
    ) -> HelperServices {
        HelperServices(
            applicationsFolder: applications, afterMove: afterMove, processID: processID, forwardedArguments: forwarded,
            ownBundleIdentifier: ownBundleIdentifier, movableBundle: nil,
            isRunning: { [self] bundle in lock.withLock { running.contains(bundle.standardizedFileURL.path(percentEncoded: false)) } },
            verifySignature: { [self] _ in lock.withLock { signatureHolds } },
            trash: { [self] item in
                try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: item, to: trashFolder.appending(path: UUID().uuidString))
                lock.withLock { trashes.append(item) }
            },
            open: { [self] app, arguments in
                try lock.withLock {
                    if openFails { throw CocoaError(.fileReadNoPermission) }
                    openedApps.append((app, arguments))
                }
            },
            terminate: { [self] in lock.withLock { quits += 1 } },
            processIsAlive: { [self] _ in
                lock.withLock {
                    guard aliveAnswers > 0 else { return false }
                    aliveAnswers -= 1
                    return true
                }
            },
            volumeFacts: { [self] _ in lock.withLock { volume } },
            bundleIdentifier: { [self] _ in lock.withLock { bundleIdentifier } },
            eject: { [self] volume in lock.withLock { ejects.append(volume) } },
            reveal: { [self] folder in lock.withLock { reveals.append(folder) } },
            diskImageFile: { [self] _ in lock.withLock { image } },
            pause: { _ in })
    }
}

/// A scratch copy of Agent Tooling: an app bundle with its two helpers and a
/// version, wherever a test puts it.
enum HelperBundle {
    static let name = "Agent Tooling.app"

    /// `executable` gives the bundle a main executable that does nothing;
    /// `recordingArgumentsTo` gives it one that only writes down what it was
    /// started with, one argument a line, the file appearing whole.
    @discardableResult
    static func make(
        in folder: URL, version: String = "0.1.0", executable: Bool = false, recordingArgumentsTo record: URL? = nil
    ) throws -> URL {
        let bundle = folder.appending(path: name, directoryHint: .isDirectory)
        try write(
            bundle.appending(path: "Contents/Info.plist"),
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>dev.agenttooling.app</string>
            <key>CFBundleExecutable</key><string>AgentTooling</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleShortVersionString</key><string>\(version)</string>
            </dict></plist>
            """)
        let main = bundle.appending(path: "Contents/MacOS/AgentTooling")
        if let record {
            let path = record.path(percentEncoded: false)
            try write(main, "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(path).partial' && mv '\(path).partial' '\(path)'\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: main.path(percentEncoded: false))
        } else if executable {
            try FileManager.default.createDirectory(at: main.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: main)
        }
        for helper in ["agent-tooling-mcp", "agent-tooling"] {
            let file = bundle.appending(path: "Contents/Helpers/\(helper)")
            try write(file, "#!/bin/sh\nexit 0\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        }
        return bundle
    }

    /// The copy as it runs from a mounted disk image.
    static func onDiskImage(_ bundle: URL, volume: URL) -> AgentToolingInstallation {
        AgentToolingInstallation(
            bundleURL: bundle, location: .diskImage(volumeName: "Agent Tooling", volumeURL: volume),
            mcpHelperURL: bundle.appending(path: "Contents/Helpers/agent-tooling-mcp"),
            cliHelperURL: bundle.appending(path: "Contents/Helpers/agent-tooling"), isAdHocSigned: false)
    }

    /// The copy as it runs from Applications, `folder` standing in for it.
    static func inApplications(_ folder: URL) -> AgentToolingInstallation {
        let bundle = folder.appending(path: name, directoryHint: .isDirectory)
        return AgentToolingInstallation(
            bundleURL: bundle, location: .applications(folder),
            mcpHelperURL: bundle.appending(path: "Contents/Helpers/agent-tooling-mcp"),
            cliHelperURL: bundle.appending(path: "Contents/Helpers/agent-tooling"), isAdHocSigned: false)
    }
}
