import Foundation

/// Where Bookrest keeps its files.
///
/// Downloads live in Application Support (backed up is undesirable for large audio,
/// so the folder is excluded from iCloud/iTunes backup) rather than Caches, because
/// the system may purge Caches while a book is still needed offline.
public enum StorageLocations {
    public static let folderName = "Bookrest"

    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    public static var offlineRoot: URL {
        applicationSupport.appendingPathComponent("Offline", isDirectory: true)
    }

    public static var indexFile: URL {
        applicationSupport.appendingPathComponent("offline-index.json")
    }

    public static var progressFile: URL {
        applicationSupport.appendingPathComponent("progress.json")
    }

    public static func itemFolder(forKey key: String) -> URL {
        offlineRoot.appendingPathComponent(sanitize(key), isDirectory: true)
    }

    /// Item keys contain `/` for podcast episodes, which would create nested folders.
    public static func sanitize(_ key: String) -> String {
        key.replacingOccurrences(of: "/", with: "__")
    }

    @discardableResult
    public static func ensureDirectories() -> Bool {
        do {
            try FileManager.default.createDirectory(at: offlineRoot, withIntermediateDirectories: true)
            var root = applicationSupport
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? root.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    public static func availableCapacityBytes() -> Int64? {
        let values = try? offlineRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
