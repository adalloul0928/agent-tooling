import Foundation

extension ObservedSkillCopies {
    /// Adds file counts and newest modification dates off the caller's actor,
    /// using scan bounds and excluding files the definition digest excludes.
    /// Equality still uses the observed digest. Unreadable folders keep nil count
    /// and date rather than reporting zero.
    public static func measure(_ copies: [ObservedSkillCopy]) async -> [ObservedSkillCopy] {
        await Task.detached(priority: .userInitiated) {
            copies.map { copy in
                var measured = copy
                let folder = URL(filePath: copy.path, directoryHint: .isDirectory)
                if let measurement = measurement(of: folder) {
                    measured.fileCount = measurement.files
                    measured.changedAt = measurement.newest
                }
                return measured
            }
        }.value
    }

    /// The visible regular files under `folder`, and when the newest changed.
    /// Nil when the folder holds none that can be read.
    static func measurement(of folder: URL, fileManager: FileManager = .default) -> (files: Int, newest: Date?)? {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let files = BoundedFileAccess.relativeRegularFiles(under: root, fileManager: fileManager)
        guard !files.isEmpty else { return nil }
        let dates = files.compactMap { relative in
            (try? root.appending(path: relative).resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
        return (files.count, dates.max())
    }
}
