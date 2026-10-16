import CoreGraphics
import Testing

@testable import AgentToolingApp

/// The Skills, Plugins and Connections tables lay their columns out from one
/// shared rule. The widths below are the ones each table drew with while it
/// still kept its own copy of the rule, so sharing it moved no column.
@Suite("Collection table columns")
struct CollectionColumnsTests {
    @Test("Each table switches to its wide layout at its own width")
    func eachTableExpandsAtItsOwnWidth() {
        let thresholds: [(String, CollectionColumns.Layout, CGFloat)] = [
            ("Connections", .connections, 1_050),
            ("Plugins", .plugins, 820),
            ("Skills", .skills(selecting: false, describing: true), 940),
        ]
        for (name, layout, from) in thresholds {
            #expect(!CollectionColumns(width: from - 1, layout: layout).expanded, "\(name) widened too early")
            #expect(CollectionColumns(width: from, layout: layout).expanded, "\(name) did not widen at \(from)")
        }
    }

    @Test("Connections: the name takes its share up to 240, or what the App column leaves down to 150")
    func connectionsNameColumn() {
        expectWidth(CollectionColumns(width: 1_050, layout: .connections).name, 231)
        expectWidth(CollectionColumns(width: 2_000, layout: .connections).name, 240)
        expectWidth(CollectionColumns(width: 800, layout: .connections).name, 704)
        expectWidth(CollectionColumns(width: 200, layout: .connections).name, 150)
    }

    @Test("Plugins: the name takes its share up to 300, or what Managed by leaves down to 160")
    func pluginsNameColumn() {
        expectWidth(CollectionColumns(width: 820, layout: .plugins).name, 229.6)
        expectWidth(CollectionColumns(width: 1_500, layout: .plugins).name, 300)
        expectWidth(CollectionColumns(width: 600, layout: .plugins).name, 504)
        expectWidth(CollectionColumns(width: 200, layout: .plugins).name, 160)
    }

    @Test("Skills: the wide layout's columns, with and without a description column")
    func skillsWideColumns() {
        let described = SkillTableColumns(width: 1_000, selecting: false, describing: true)
        #expect(described.expanded)
        expectWidth(described.name, 240)
        expectWidth(described.verdict, 104)
        expectWidth(described.plugin, 170)
        expectWidth(described.marketplace, 150)

        expectWidth(SkillTableColumns(width: 1_000, selecting: false, describing: false).name, 420)

        let roomy = SkillTableColumns(width: 2_500, selecting: false, describing: true)
        expectWidth(roomy.name, 300)
        expectWidth(roomy.plugin, 200)
        expectWidth(roomy.marketplace, 180)
        expectWidth(SkillTableColumns(width: 2_500, selecting: false, describing: false).name, 520)
    }

    @Test("Skills: the narrow name gives way to the marks, the Managed column and any checkbox")
    func skillsNarrowColumns() {
        let browsing = SkillTableColumns(width: 800, selecting: false, describing: true)
        #expect(!browsing.expanded)
        expectWidth(browsing.verdict, 96)
        expectWidth(browsing.name, 560)
        expectWidth(SkillTableColumns(width: 800, selecting: true, describing: true).name, 528)
        expectWidth(SkillTableColumns(width: 300, selecting: true, describing: true).name, 140)
    }

    private func expectWidth(
        _ actual: CGFloat, _ expected: CGFloat, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(actual - expected) < 0.001, "\(actual) is not \(expected)", sourceLocation: sourceLocation)
    }
}
