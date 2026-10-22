import Testing

@testable import AgentToolingApp

extension ActionTitlesTests {
    /// Setting this Mac up again is one name, cased for where it is shown:
    /// the app menu title-cases every word, as the system's menus do, and the
    /// window's sentence case names it in the palette, on Apps and in
    /// Settings › General. The words themselves are pinned once, with the
    /// welcome's (`LaunchpadWelcomeWordingTests`), and each control that
    /// offers them is followed to the stage by that name in
    /// `ReentryRoutesTests`.
    @Test("Set up this Mac… is one name, title-cased only in the app menu")
    func setUpThisMacIsOneNameInTwoCases() {
        let menu = ActionTitles.setUpThisMacCommand(.menu)
        let window = ActionTitles.setUpThisMacCommand(.palette)
        let titleCased = window.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }
        #expect(menu == titleCased.joined(separator: " "))
        #expect(window != menu, "the window's name is title-cased")
    }
}
