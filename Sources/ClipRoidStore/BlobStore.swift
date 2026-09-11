import Foundation
import os.log
import ClipRoidCore

public enum BlobStoreError: LocalizedError, Equatable {
    case tooLarge(bytes: Int, limit: Int)
    case lowDisk(availableBytes: Int64)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let bytes, let limit):
            "Clip too large to save — \(bytes / 1_048_576)MB exceeds the \(limit / 1_048_576)MB limit."
        case .lowDisk(let available):
            "Not enough disk space to save this clip (\(available / 1_048_576)MB free)."
        case .writeFailed(let m):
            "Could not save clip contents: \(m)"
        }
    }
}

/// Binary payloads live on disk, one file per blob, with only the path in the database.
///
/// Structure follows ~/projects/nyx/Sources/NyxLib/Services/AvatarLibrary.swift: write to a temp
/// name and then move into place, so an interrupted write can never leave a half-file that the
/// database believes is whole.
///
/// Paths are sharded by the first two hex characters of the UUID. With a 10,000-clip history and
/// no sharding, a single directory ends up holding tens of thousands of entries, which makes
/// enumeration and Finder both miserable.
public actor BlobStore {
    private let root: URL
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "BlobStore")

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    public func prepare() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func url(for uuid: UUID, ext: String) -> URL {
        let shard = String(uuid.uuidString.prefix(2)).lowercased()
        return root.appendingPathComponent(shard, isDirectory: true)
            .appendingPathComponent("\(uuid.uuidString.lowercased()).\(ext)")
    }

    /// Returns the path stored in the DB, relative to the blob root so the whole store stays
    /// relocatable.
    public func write(_ data: Data, uuid: UUID, ext: String, maxBytes: Int) throws -> String {
        guard data.count <= maxBytes else {
            throw BlobStoreError.tooLarge(bytes: data.count, limit: maxBytes)
        }
        try checkDiskSpace(needing: Int64(data.count))

        let destination = url(for: uuid, ext: ext)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp, options: .atomic)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw BlobStoreError.writeFailed(error.localizedDescription)
        }
        return destination.path.replacingOccurrences(of: root.path + "/", with: "")
    }

    public func read(relativePath: String) -> Data? {
        try? Data(contentsOf: root.appendingPathComponent(relativePath))
    }

    public func absoluteURL(relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    /// Retention and deletion must remove the bytes, not just the row. A store that prunes rows and
    /// leaks blobs grows without bound while reporting that it is bounded.
    public func delete(relativePaths: [String]) {
        for path in relativePaths where !path.isEmpty {
            try? fileManager.removeItem(at: root.appendingPathComponent(path))
        }
    }

    public func totalSizeBytes() -> Int64 {
        guard let e = fileManager.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Spec §10: check before writing, not after failing.
    private func checkDiskSpace(needing bytes: Int64) throws {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        guard available - bytes > SizeLimits.lowDiskThresholdBytes else {
            throw BlobStoreError.lowDisk(availableBytes: available)
        }
    }
}
