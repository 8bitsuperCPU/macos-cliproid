import Foundation
import os.log

/// A startup and lifecycle log that is actually readable.
///
/// `os.log` at `.info` is not persisted by default, so a bundled app launched with `open` produces
/// no visible output at all — which makes "did the hotkey register?" impossible to answer without
/// attaching a debugger. This mirrors every line to a file as well.
///
/// The spikes work (Docs/spikes.md, S3) recommended exactly this: log `AXIsProcessTrusted()` on
/// every launch so a revoked grant announces itself rather than presenting as a paste bug.
public enum Diagnostics {
    public static let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/ClipDroid.log")

    private static let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "Diagnostics")
    private static let lock = NSLock()

    public static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")

        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp)  \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))

        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}
