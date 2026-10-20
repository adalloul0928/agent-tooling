import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// Tests never leave preference files in `~/Library/Preferences`. A suite
/// named the ordinary way keeps its file there, and removing its domain only
/// empties it: before this guard the folder held thousands of
/// `skills-render-<uuid>.plist`, `agent-tooling-preferences-<uuid>.plist` and
/// `agent-tooling-tests.<uuid>.plist` files. Every suite a test makes now
/// goes through `ScratchDefaults`, whose file lives in its own scratch
/// folder and goes with it.
@Suite("Test preferences stay in scratch", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct TestPreferencesStayInScratchTests {
    /// The names a test's suite used to leave behind.
    private static let leakedPrefixes = ["skills-render-", "agent-tooling-preferences-", "agent-tooling-tests.", "defaults-"]

    @Test func aScratchSuiteKeepsItsFileInItsOwnFolderAndTakesItAway() throws {
        let before = Self.leakedFiles()
        let scratch = try ScratchDefaults("guard")
        scratch.defaults.set("dark", forKey: AppPreferenceKey.appearance)
        scratch.defaults.synchronize()

        #expect(scratch.defaults.string(forKey: AppPreferenceKey.appearance) == "dark")
        #expect(FileManager.default.fileExists(atPath: scratch.file.path(percentEncoded: false)), "written beside the folder's name")
        #expect(Self.leakedFiles() == before, "nothing new in ~/Library/Preferences")

        scratch.remove()
        #expect(!FileManager.default.fileExists(atPath: scratch.folder.path(percentEncoded: false)))
        #expect(Self.leakedFiles() == before)
    }

    /// A suite made in a fixture's own folder keeps its file there, apart
    /// from any other suite in it; `remove()` takes the file and leaves the
    /// folder to its fixture.
    @Test func aSuiteInAFixturesFolderKeepsItsFileThere() throws {
        let before = Self.leakedFiles()
        let folder = try TemporaryFolder("fixture-preferences").url
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try ScratchDefaults("preferences", in: folder)
        let second = try ScratchDefaults("preferences", in: folder)
        first.defaults.set("dark", forKey: AppPreferenceKey.appearance)
        first.defaults.synchronize()

        #expect(first.suite != second.suite)
        #expect(second.defaults.string(forKey: AppPreferenceKey.appearance) == nil)
        #expect(FileManager.default.fileExists(atPath: first.file.path(percentEncoded: false)))
        #expect(first.file.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(Self.leakedFiles() == before)

        first.remove()
        second.remove()
        #expect(!FileManager.default.fileExists(atPath: first.file.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)), "the folder is the fixture's")
        #expect(Self.leakedFiles() == before)
    }

    /// The Skills renders' preferences, and a launch's `--defaults-suite`,
    /// the two kinds that leaked, leave nothing once removed.
    @Test func theRenderAndLaunchSuitesLeaveNothingBehind() throws {
        let before = Self.leakedFiles()
        let render = try ShellRenderFixture.preferences()
        render.defaults.set(true, forKey: "skills.groupByKind")
        render.defaults.synchronize()
        let launch = try ScratchDefaults("agent-tooling-tests")
        let context = LaunchContext(arguments: ["AgentTooling", "--defaults-suite", launch.suite])
        context.defaults.set(AppAppearance.light.rawValue, forKey: AppPreferenceKey.appearance)
        context.defaults.synchronize()

        #expect(launch.defaults.string(forKey: AppPreferenceKey.appearance) == AppAppearance.light.rawValue)
        render.remove()
        launch.remove()
        #expect(Self.leakedFiles() == before)
    }

    /// No test makes a suite any other way: the one `UserDefaults(suiteName:)`
    /// in the tests is ScratchDefaults' own.
    @Test func everyTestSuiteGoesThroughScratchDefaults() throws {
        let allowed: Set<String> = ["ScratchDefaults.swift"]
        // Spelled in two parts, so this line is not one it finds.
        let needle = "UserDefaults(" + "suiteName"
        var found: [String] = []
        for file in try PackageSourceFile.all(under: "Tests")
        where !allowed.contains(URL(filePath: file.path).lastPathComponent) {
            for (index, line) in file.lines.enumerated()
            where line.contains(needle) && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                found.append("\(file.path):\(index + 1)")
            }
        }
        #expect(found.isEmpty, "a suite made outside ScratchDefaults: \(found.joined(separator: ", "))")
    }

    /// The files in `~/Library/Preferences` named as a test's suite would be.
    private static func leakedFiles() -> Set<String> {
        let folder = ScratchDefaults.preferencesFolder.path(percentEncoded: false)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return Set(names.filter { name in leakedPrefixes.contains { name.hasPrefix($0) } })
    }
}
