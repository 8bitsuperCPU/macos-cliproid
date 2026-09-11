# M0 spikes

Each spike answers one question that could invalidate the architecture. Answers are recorded here
so they do not have to be rediscovered.

---

## S1 — Pasteboard read privacy on macOS 26 — **PASS, with a caveat**

*Risk R1: if macOS 26 prompts, blocks, or toasts on programmatic pasteboard reads by a background
app, ClipRoid's whole capture model changes shape.*

Harness: `Spikes/S1-PasteboardPrivacy.swift`. Run on macOS 26.6.2 / Xcode 26.5 as an unsigned bare
executable with `activationPolicy = -1` and `isActive = false` — i.e. maximally "background", more
so than the real app will ever be.

**Result: unimpeded.**

| Operation | Outcome |
|---|---|
| `changeCount` | Read fine |
| `types` (declared UTIs, no payload) | Read fine |
| `string(forType:)` | Returned all 92 chars |
| Sustained 300ms polling with a payload read per tick | **10/10 successful reads** |

No denial, no empty return, no degradation over sustained polling. **The M0 capture model stands and
the adaptive-interval poller can be built as designed.**

### Caveat — worth knowing before shipping

`NSPasteboard.h` documents `detectPatternsForPatterns:` with this sentence:

> "...doesn't allow the app to access the item's contents. As a result, the system doesn't notify
> the person using the app about reading the contents of the pasteboard."

The clear implication is that reading contents *does* notify the user in some circumstances. No
alert was observed during this spike, but a spike run from a terminal cannot prove one would never
appear for a signed, bundled, long-running app. **Re-check this in M1** once the app runs as a real
bundle for hours at a time, and watch for any user-facing pasteboard notice.

### Finding: the read-free pre-check is awkward to reach from Swift

`detectPatterns` is the documented way to inspect the pasteboard *without* triggering a contents
read, and it is the natural fallback if the caveat above ever bites. On MacOSX26.5.sdk it is
effectively unavailable to Swift:

- `NSPasteboard.DetectionPattern` — does not exist in Swift.
- `NSPasteboardDetectionPattern*` constants — not in scope in Swift.
- `detectPatterns(for:completionHandler:)` and the async form — neither exists.
- Only `__detectPatterns(forPatterns:completionHandler:)` is imported, and it wants
  `__NSPasteboardDetectionPattern` values built from constants Swift cannot see.

Working route, confirmed by this spike: resolve the constants with `dlsym` against the AppKit binary
and wrap them in `__NSPasteboardDetectionPattern(rawValue:)`. Their real values are
`com.apple.appkit.pasteboard-detection-pattern.{probable-web-url,number,dd.email}`. Detection itself
works correctly once reached — it matched email and URL in the probe payload.

If this fallback is ever needed, budget for a small ObjC shim target rather than shipping `dlsym`
against a private-ish symbol.

---

## S2 — Carbon `RegisterEventHotKey` under Swift 6 language mode — **not yet run**

Needs: `Ctrl+Cmd+V` firing from a background app, no Accessibility prompt, through the `Unmanaged`
userData C-callback trampoline, from a `.v6` target.

## S3 — TCC grant survival across rebuilds — **blocked**

Needs `Scripts/create-signing-identity.sh` to have been run, which requires the login keychain
password and so cannot be automated. Until then `Scripts/bundle.sh` deliberately refuses to build
rather than falling back to ad-hoc signing (see R2).

## S4 — CGEvent paste round-trip — **not yet run**

Needs S3 first (Accessibility grant must survive a rebuild to be testable). Target apps: TextEdit,
Safari, VS Code, Terminal.app, iTerm2, Slack. Deliverable is a per-app results table, not a boolean.
