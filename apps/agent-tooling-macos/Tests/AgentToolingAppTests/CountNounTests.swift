import Testing

@testable import AgentToolingApp

/// Counts read the way a person says them: "1 connection", never "1
/// connections" or "1 servers".
@Suite("Count nouns")
struct CountNounTests {
    @Test("Exactly one takes the singular")
    func oneIsSingular() {
        #expect(CountNoun.connection.phrase(1) == "1 connection")
        #expect(CountNoun.skill.phrase(1) == "1 skill")
        #expect(CountNoun.plugin.phrase(1) == "1 plugin")
        #expect(CountNoun.change.phrase(1) == "1 change")
    }

    @Test("Any other count takes the plural, zero included")
    func othersArePlural() {
        #expect(CountNoun.connection.phrase(2) == "2 connections")
        #expect(CountNoun.skill.phrase(0) == "0 skills")
        #expect(CountNoun.plugin.phrase(14) == "14 plugins")
        #expect(CountNoun.change.phrase(3) == "3 changes")
    }

    @Test("A noun can name its own plural")
    func irregularPlural() {
        let copy = CountNoun("copy", plural: "copies")
        #expect(copy.phrase(1) == "1 copy")
        #expect(copy.phrase(2) == "2 copies")
    }

    @Test("The noun alone agrees with the count, for text that puts the number elsewhere")
    func wordAgreesWithCount() {
        #expect(CountNoun.connection.word(for: 1) == "connection")
        #expect(CountNoun.connection.word(for: 5) == "connections")
    }

    @Test("The app's nouns say connection and plugin, the words its screens use")
    func vocabulary() {
        #expect(CountNoun.connection.singular == "connection")
        #expect(CountNoun.plugin.singular == "plugin")
    }
}
