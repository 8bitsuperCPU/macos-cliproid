import Foundation

/// Tags derived automatically at capture (spec §4.6).
///
/// Deliberately a narrow subset of what §4.6 lists. The spec also proposes auto-tagging every clip
/// with its content type and its source app — but both of those are already first-class facets in
/// the Library sidebar, with their own counts and filters. Duplicating them as tags would give the
/// user two different ways to express the same filter, a tag cloud dominated by `text` and
/// `Safari`, and no added capability.
///
/// What tags add that facets do not is the *inside* of a clip: the domain a link points at, the
/// kind of file that was copied. Those are generated here. Everything else is left to the user.
public enum AutoTags {
    public static func tags(for clip: CapturedClip) -> Set<String> {
        var tags = Set<String>()

        if let host = clip.linkHost ?? clip.linkUrl.flatMap({ URL(string: $0)?.host() }) {
            // Registrable-ish domain rather than the full host: a tag of `github.com` is useful,
            // one of `gist.github.com` splits the same site across several tags.
            tags.insert(normalisedDomain(host))
        }

        for url in clip.fileURLs {
            let ext = url.pathExtension.lowercased()
            if !ext.isEmpty, ext.count <= 8 { tags.insert(ext) }
        }

        return tags
    }

    static func normalisedDomain(_ host: String) -> String {
        let lower = host.lowercased()
        let parts = lower.split(separator: ".")
        guard parts.count > 2 else { return lower }

        // Two-part public suffixes such as co.uk and com.au need three labels kept, or every
        // Australian site collapses to "com.au".
        let twoPartSuffixes: Set<String> = [
            "co.uk", "com.au", "co.nz", "co.jp", "com.br", "co.za", "org.uk", "net.au", "org.au",
        ]
        let lastTwo = parts.suffix(2).joined(separator: ".")
        let keep = twoPartSuffixes.contains(lastTwo) ? 3 : 2
        return parts.suffix(keep).joined(separator: ".")
    }
}
