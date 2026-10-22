import Foundation

/// One of the package's own Swift files, read as text, for a test that holds
/// the code itself to a rule (which fonts the app draws with, which panels it
/// builds) rather than checking what a view draws.
public struct PackageSourceFile {
    /// The path below the target's folder: "Sections/HistorySection.swift".
    public let path: String
    /// The file's lines in order, so line `n` is `lines[n - 1]`.
    public let lines: [String]

    public init(path: String, lines: [String]) {
        self.path = path
        self.lines = lines
    }

    /// Every Swift file under `Sources/<target>`, sorted by path. The folder is
    /// found from this file's own place in the package, so a test reads the
    /// checkout it was built from. A folder that is not there throws, rather
    /// than reading as a target with no files in it.
    public static func all(in target: String) throws -> [PackageSourceFile] {
        try all(under: "Sources/\(target)")
    }

    /// Every Swift file under a folder of the package, by the folder's path
    /// from the package's root ("Tests"), sorted by path; each file's `path`
    /// is below that folder. A folder that is not there throws.
    public static func all(under folder: String) throws -> [PackageSourceFile] {
        let root = packageRoot.appending(path: folder, directoryHint: .isDirectory)
        let paths = try FileManager.default.subpathsOfDirectory(atPath: root.path(percentEncoded: false))
        return try paths.filter { $0.hasSuffix(".swift") }.sorted().map { path in
            let text = try String(contentsOf: root.appending(path: path), encoding: .utf8)
            return PackageSourceFile(path: path, lines: text.components(separatedBy: "\n"))
        }
    }

    /// Any file of the package as text, by its path from the package's root:
    /// "Resources/AppIcon.svg". For a test that holds code to an asset it is
    /// drawn from. A file that is not there throws.
    public static func text(at relativePath: String) throws -> String {
        try String(contentsOf: packageRoot.appending(path: relativePath), encoding: .utf8)
    }

    /// The package's root folder, found from this file's own place in it.
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
