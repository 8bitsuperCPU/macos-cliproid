import Foundation

/// Every read of and every write to the system pasteboard happens here, and nowhere else.
///
/// Two reasons this exists rather than an ad-hoc queue:
///
/// 1. `NSPasteboard`'s thread-safety is folklore-grade. Confining it to one isolation domain
///    makes the question moot.
/// 2. It makes the self-capture bug structurally impossible. ClipRoid writes the pasteboard in
///    order to paste; the poller reads it looking for new clips. If those two can interleave,
///    the app captures its own paste as a fresh clip and the history fills with duplicates.
///    Same actor means no interleaving. See `PasteboardWriteReceipt`.
@globalActor
public actor PasteboardActor {
    public static let shared = PasteboardActor()
}
