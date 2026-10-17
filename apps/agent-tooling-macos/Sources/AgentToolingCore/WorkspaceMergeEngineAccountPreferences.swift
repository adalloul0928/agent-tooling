import Foundation

extension WorkspaceMergeEngine {
    /// Three-way merge of the account choices, one switch at a time.
    ///
    /// A switch only one Mac changed takes that change. A switch both Macs set
    /// to the same value is settled. A switch the Macs moved in different
    /// directions — two values, or one Mac letting go of a choice the other
    /// changed — is a conflict the person decides, keyed by the switch's own
    /// identity; the local value is kept until they do. A document before
    /// schema 6 holds no choices, which reads the same as holding none.
    static func mergeAccountPreferences(
        base: AccountPreferences?,
        local: AccountPreferences?,
        remote: AccountPreferences?,
        report: Report
    ) -> AccountPreferences {
        let ancestors = index(base?.entries, key: { $0.key })
        let mine = index(local?.entries, key: { $0.key })
        let theirs = index(remote?.entries, key: { $0.key })
        var entries: [AccountPreference] = []
        for key in orderedKeys(base?.entries, local?.entries ?? [], remote?.entries ?? [], key: { $0.key }) {
            let ancestor = ancestors[key]
            switch (mine[key], theirs[key]) {
            case (nil, nil):
                continue
            case (let entry?, nil), (nil, let entry?):
                // Present on one side only. Without an ancestor it is an
                // addition; with one, the other side let the choice go.
                guard let ancestor else {
                    entries.append(entry)
                    continue
                }
                if entry == ancestor { continue }  // the removal is the only move
                report(.accountPreference, nil, key.objectID,
                       "One Mac stopped sharing this account choice while the other changed it.")
                if mine[key] != nil { entries.append(entry) }
            case (let mineEntry?, let theirsEntry?):
                if let chosen = pick(ancestor: ancestor, mine: mineEntry, theirs: theirsEntry, onConflict: { _ in
                    report(.accountPreference, nil, key.objectID, "Both Macs changed this account choice differently.")
                }) {
                    entries.append(chosen)
                }
            }
        }
        return AccountPreferences(entries: entries).canonicalized()
    }
}
