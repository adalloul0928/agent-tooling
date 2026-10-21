import Foundation
import IOKit

/// This Mac's family as a person names it, "Mac mini" or "MacBook Pro", and
/// what You joined draws each Mac as (D24).
///
/// The family is read from the device tree's product name ("MacBook Pro
/// (14-inch, 2023)"), keeping the words before " (". The model identifier
/// (`hw.model`) is not a name anyone uses, so it is never shown. Nil when the
/// device tree says nothing, and the caption then leaves the family out.
/// Another Mac publishes no model, so it is only ever "other Mac".
enum MacModel {
    static func family() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard
            let property = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue(),
            let data = property as? Data
        else { return nil }
        return family(fromProductName: String(decoding: data.prefix { $0 != 0 }, as: UTF8.self))
    }

    /// The words before " (", trimmed, or nil when nothing is left.
    static func family(fromProductName name: String) -> String? {
        let family = name.components(separatedBy: " (").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return family.isEmpty ? nil : family
    }

    /// The version of macOS this Mac runs, by its major number: 26.
    static func systemMajorVersion() -> Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    /// The symbol a Mac of `family` is drawn with: a laptop for a MacBook,
    /// each desktop's own, and a laptop for a Mac whose family is not known,
    /// as another Mac's always is.
    static func symbol(forFamily family: String?) -> String {
        guard let family else { return "laptopcomputer" }
        if family.hasPrefix("MacBook") { return "laptopcomputer" }
        if family.hasPrefix("Mac mini") { return "macmini" }
        if family.hasPrefix("Mac Studio") { return "macstudio" }
        if family.hasPrefix("Mac Pro") { return "macpro.gen3" }
        if family.hasPrefix("iMac") { return "desktopcomputer" }
        return "laptopcomputer"
    }
}
