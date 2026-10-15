import Foundation

extension String {
    /// The first letter capitalised, the rest left as written.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
