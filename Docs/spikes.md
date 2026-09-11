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

---

## S2 — Carbon `RegisterEventHotKey` under Swift 6 language mode — **PASS (registration)**

*Two questions: does a global hotkey need Accessibility, and does the Carbon C-callback trampoline
survive `-swift-version 6`?*

Harness: `Spikes/S2-CarbonHotKey.swift`, plus `Spikes/SpikeApp/` for the bundled case.

| Question | Answer |
|---|---|
| Compiles under `-swift-version 6`? | **Yes** — clean, no `Sendable` warnings, no `@unchecked` needed |
| `InstallEventHandler` | `0` (noErr) |
| `RegisterEventHotKey` | `0` (noErr) |
| `AXIsProcessTrusted()` after registering | **`false`** |

**A global hotkey registers and arms with no Accessibility grant.** This is what makes the
permission story in the plan work: `Ctrl+Cmd+V` can open the Quick Paste window, search, and put a
clip on the pasteboard before the user has granted anything. Only the final synthetic `Cmd+V`
needs Accessibility, and the clipboard-only fallback covers its absence.

The `Unmanaged.passUnretained(self).toOpaque()` userData trampoline is safe here specifically
because the hotkey center outlives the installed handler — it is installed for the lifetime of the
app and torn down in `deinit`. **Platform does not need a `.v5` downgrade.**

**Still open:** confirming the handler actually *fires* on a real keypress. Two listener runs
recorded zero presses, which reflects no key being pressed rather than any failure — registration
returned `noErr` both times. Re-confirm with one keypress against `Spikes/SpikeApp/`.

---

## S3 — TCC grant survival across rebuilds — **PASS**

*Risk R2: if grants do not survive a rebuild, every permission-dependent feature becomes untestable
and failures look like code bugs.*

Method: build, capture the designated requirement, touch a source file, rebuild, capture again.

```
designated => identifier "dev.philtronic.ClipRoid"
               and certificate leaf = H"1f3be1474d434e5f9ee8ef8dfcd691cd12f4d0b6"
```

**Byte-identical across rebuilds.** The requirement references only the bundle identifier and the
signing certificate — never the binary — so TCC grants bind to something that does not change when
code does. This is exactly what ad-hoc signing cannot provide, and why `Scripts/bundle.sh` refuses
to fall back to it.

Two things that would still reset every grant, neither of which the script can protect against:
- changing `CFBundleIdentifier` (fixed at `dev.philtronic.ClipRoid` from M0);
- moving the bundle — TCC keys on path too, so `bundle.sh` writes to a stable `.build/` location
  rather than a temp directory.

Note for M6: a notarized Developer ID build is a *different* signing identity from the local
self-signed one, so grants will not carry over from development to the shipped app. That is correct
behaviour, but budget a re-grant when testing the release build.

---

## S4 — CGEvent paste round-trip — **harness ready, needs an Accessibility grant**

Harness: `Spikes/SpikeApp/` (combined with S2 because both need a signed bundle for TCC to bind to).
Implements the full sequence the plan specifies, each step of which is individually easy to get
wrong:

1. capture the frontmost app **before** any of our own UI appears;
2. `activate`, then await `didActivateApplicationNotification` for that pid with a 400ms timeout —
   not a fixed sleep, because timing varies with Spaces switches and app launches;
3. **wait for held modifiers to clear** — the user may still be holding `Ctrl+Cmd` from the hotkey,
   and posting `Cmd+V` on top of a held `Ctrl` delivers `Ctrl+Cmd+V`, a different command. Most
   likely single cause of "paste sometimes does nothing";
4. resolve the keycode for `"v"` by enumerating the **current layout** via `UCKeyTranslate` —
   `kVK_ANSI_V` is a physical position, and on Dvorak that position is not `"v"`. The spec raises
   layout-independence for shortcut *detection* and misses it for paste *delivery*;
5. post with `.eventSourceUserData` set to a magic value so the M5 keystroke observer can ignore
   our own synthetic events.

To run: grant Accessibility to `.build/ClipRoidSpike.app`, launch it, press `Ctrl+Cmd+V` in each
target app. Deliverable is a per-app results table — TextEdit, Safari, VS Code, Terminal.app,
iTerm2, Slack — not a boolean.
