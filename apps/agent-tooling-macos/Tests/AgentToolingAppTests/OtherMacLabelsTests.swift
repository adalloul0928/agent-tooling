import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The Other Mac sheet's rows, which no gallery fixture draws with a report.
/// Each app row counted "servers" while the library calls them connections,
/// never said a count in the singular ("1 skills"), and built its VoiceOver
/// label as a second copy of the visible line; an assigned plugin was read out
/// as a "package".
@Suite("Other Mac labels")
struct OtherMacLabelsTests {
    private func app(
        installed: Bool = true, version: String? = "2.1", skills: Int = 0, plugins: Int = 0, connections: Int = 0
    ) -> PublishedDeviceStatus.AppSummary {
        .init(
            surface: .claudeCode, installed: installed, version: version,
            skillCount: skills, pluginCount: plugins, mcpServerCount: connections)
    }

    @Test("An app's counts use the library's nouns, singular for one")
    func countsInTheLibrarysNouns() {
        let one = DeviceLabels.appLine(app(skills: 1, plugins: 1, connections: 1))
        #expect(one.text == "2.1 · 1 skill · 1 plugin · 1 connection")
        #expect(one.accessibilityLabel == "Claude Code, installed, 2.1, 1 skill, 1 plugin, 1 connection")

        let several = DeviceLabels.appLine(app(skills: 3, plugins: 0, connections: 2))
        #expect(several.text == "2.1 · 3 skills · 0 plugins · 2 connections")
    }

    @Test("An app with no version says installed, and VoiceOver says the version is unknown")
    func noVersion() {
        let line = DeviceLabels.appLine(app(version: nil, skills: 2))
        #expect(line.text == "Installed · 2 skills · 0 plugins · 0 connections")
        #expect(line.accessibilityLabel == "Claude Code, installed, version unknown, 2 skills, 0 plugins, 0 connections")
    }

    @Test("An app that is not there says so about that Mac")
    func notFound() {
        let line = DeviceLabels.appLine(app(installed: false, version: nil))
        #expect(line.text == "Not found on that Mac")
        #expect(line.accessibilityLabel == "Claude Code, not found on that Mac")
    }

    @Test("The row and its VoiceOver label say the same things")
    func labelCarriesTheVisibleParts() {
        let summaries = [
            app(skills: 2, plugins: 1, connections: 4),
            app(version: nil, skills: 1),
            app(installed: false, version: nil),
        ]
        for summary in summaries {
            let line = DeviceLabels.appLine(summary)
            for part in line.text.components(separatedBy: " · ") {
                #expect(
                    line.accessibilityLabel.localizedCaseInsensitiveContains(part),
                    "\(line.accessibilityLabel) leaves out \(part)")
            }
            #expect(!line.text.contains("server"))
            #expect(!line.accessibilityLabel.contains("server"))
        }
    }

    @Test("An assigned item's kind is named the way the app names it")
    func kindNames() {
        #expect(DeviceLabels.kindName(.skill) == "skill")
        #expect(DeviceLabels.kindName(.mcpServer) == "connection")
        #expect(DeviceLabels.kindName(.nativePlugin) == "plugin")
        #expect(DeviceLabels.kindName(.package) == "plugin")
        #expect(DeviceLabels.kindName(.preset) == "preset")
        #expect(DeviceLabels.kindName(.logicalProject) == "project")
    }
}
