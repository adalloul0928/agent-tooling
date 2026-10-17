import Foundation

/// A stable UUID used by deterministic test fixtures.
public func fixtureUUID(_ value: String) -> UUID {
    guard let uuid = UUID(uuidString: value) else {
        preconditionFailure("Invalid UUID in test fixture: \(value)")
    }
    return uuid
}
