import CryptoKit
import Foundation
import Testing

@testable import AgentToolingCore

/// The key that opens an encrypted folder, and the phrase that carries it to a
/// second Mac by hand.
@Suite("Workspace folder key store")
struct WorkspaceFolderKeyStoreTests {
    @Test func aStoredKeySurvivesReopeningAndIsThePersonsAlone() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let key = WorkspaceFolderKeyStore.generate()

        try fixture.store.write(key)

        let reopened = try #require(try WorkspaceFolderKeyStore(containerRoot: fixture.root).read())
        #expect(reopened == key)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        #expect(attributes[.posixPermissions] as? NSNumber == 0o600)
    }

    @Test func aMacWithNoKeyHasNoKey() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(try fixture.store.read() == nil)
    }

    @Test func aDamagedKeyFileIsAnErrorRatherThanAnOfferToMakeANewOne() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("{ not json".utf8).write(to: fixture.file)

        // Treating this as "no key" would make a new one and leave the folder
        // unreadable by every Mac already using it.
        #expect(throws: WorkspaceFolderKeyError.unsupportedFormat) { _ = try fixture.store.read() }
    }

    @Test func aPhraseCarriesTheExactKeyToAnotherMac() throws {
        for _ in 0..<32 {
            let key = WorkspaceFolderKeyStore.generate()
            let phrase = WorkspaceFolderKeyStore.recoveryPhrase(for: key)
            #expect(try WorkspaceFolderKeyStore.key(fromRecoveryPhrase: phrase) == key)
        }
    }

    @Test func typingAPhraseBackIsNotDefeatedByPunctuationOrCase() throws {
        let key = WorkspaceFolderKeyStore.generate()
        let phrase = WorkspaceFolderKeyStore.recoveryPhrase(for: key)
        let mangled = phrase.uppercased().replacingOccurrences(of: "-", with: "  ")

        #expect(try WorkspaceFolderKeyStore.key(fromRecoveryPhrase: mangled) == key)
    }

    @Test func aLetterTypedForTheDigitItLooksLikeStillOpensTheFolder() throws {
        let key = WorkspaceFolderKeyStore.generate()
        let phrase = WorkspaceFolderKeyStore.recoveryPhrase(for: key)
        // Someone reading it off a screen types O for zero and l for one.
        let mistyped = phrase
            .replacingOccurrences(of: "0", with: "O")
            .replacingOccurrences(of: "1", with: "l")

        #expect(try WorkspaceFolderKeyStore.key(fromRecoveryPhrase: mistyped) == key)
    }

    @Test func aPhraseThatIsNotOneIsRefusedRatherThanTurnedIntoSomeKey() throws {
        for phrase in ["", "abc", String(repeating: "a", count: 51), String(repeating: "a", count: 53)] {
            #expect(throws: WorkspaceFolderKeyError.invalidRecoveryPhrase) {
                _ = try WorkspaceFolderKeyStore.key(fromRecoveryPhrase: phrase)
            }
        }
    }

    @Test func thePhraseNeverPrintsTheLettersThatLookLikeDigits() {
        let phrase = WorkspaceFolderKeyStore.recoveryPhrase(for: WorkspaceFolderKeyStore.generate())
        for confusable in ["i", "l", "o", "u"] {
            #expect(!phrase.contains(confusable), "'\(confusable)' is too easy to mistype: \(phrase)")
        }
        // Groups of five, so a person can keep their place across a screen.
        #expect(phrase.split(separator: "-").allSatisfy { $0.count <= 5 })
    }

    @Test func forgettingTheKeyHereLeavesTheFolderReadableWhereThePhraseStillIs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let key = WorkspaceFolderKeyStore.generate()
        let phrase = WorkspaceFolderKeyStore.recoveryPhrase(for: key)
        try fixture.store.write(key)

        try fixture.store.remove()

        #expect(try fixture.store.read() == nil)
        #expect(try WorkspaceFolderKeyStore.key(fromRecoveryPhrase: phrase) == key)
    }

    private struct Fixture {
        let root: URL
        let store: WorkspaceFolderKeyStore
        var file: URL { root.appending(path: "folder-sync-key.json") }

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "folder-key-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            store = try WorkspaceFolderKeyStore(containerRoot: root)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
