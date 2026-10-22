import Foundation
import Testing

@Suite("Accessibility probe text")
@MainActor
struct AccessibilityProbeTests {
    @Test func objectTextGettersPreservePlainAndAttributedWords() {
        let node = TextAttributes()
        #expect(AccessibilityProbe.textAttribute(node, named: "plainText") == "Plain label")
        #expect(AccessibilityProbe.textAttribute(node, named: "attributedText") == "Attributed label")
        #expect(AccessibilityProbe.textAttribute(node, named: "absentText") == nil)
        #expect(AccessibilityProbe.textAttribute(node, named: "numberValue") == nil)
        #expect(AccessibilityProbe.textAttribute(node, named: "unavailableAttribute") == nil)
    }
}

@MainActor
private final class TextAttributes: NSObject {
    @objc var plainText: NSString { "Plain label" }
    @objc var attributedText: NSAttributedString { NSAttributedString(string: "Attributed label") }
    @objc var absentText: NSString? { nil }
    @objc var numberValue: NSNumber { 42 }
}
