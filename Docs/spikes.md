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

## S2 — Carbon `RegisterEventHotKey` under Swift 6 language mode — **PASS**

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

**Firing confirmed** on 2026-09-11 17:25:17: `Ctrl+Cmd+V` pressed in Notes reached the handler in a
background `LSUIElement` app with no window of its own, and drove a successful paste. See S4.

---

## S3 — TCC grant survival across rebuilds — **FAILS for a self-signed identity**

*Risk R2: if grants do not survive a rebuild, every permission-dependent feature becomes untestable
and failures look like code bugs.*

**An earlier revision of this document recorded S3 as a pass. That was wrong**, and worth reading
carefully, because the mechanism it got right is the same one that misleads.

### What is true

The designated requirement is stable across rebuilds:

```
designated => identifier "dev.philtronic.ClipRoid"
               and certificate leaf = H"1f3be1474d434e5f9ee8ef8dfcd691cd12f4d0b6"
```

Byte-identical before and after a rebuild — it references only the bundle identifier and the signing
certificate, never the binary. `codesign --verify --strict --deep` reports "satisfies its Designated
Requirement" after every build.

### What actually happens

Accessibility is **still revoked on every rebuild**. Observed directly:

| Step | cdhash | `AXIsProcessTrusted()` |
|---|---|---|
| Binary granted by hand in System Settings, launched 17:24:04 | (granted build) | **`true`** — hotkey fired, paste landed in Notes |
| Rebuilt after a source change | `fa472a16…` | `false` |
| Rebuilt again from the *identical* committed source | `9ae32253…` | `false` |

Two things follow. First, **the build is not reproducible** — rebuilding unchanged source produces a
different cdhash, so "rebuild the same code to get the grant back" is not available. Second, and the
actual cause: `codesign -dvv` reports **`TeamIdentifier=not set`**. A self-signed certificate carries
no team identifier, and without one TCC does not appear to accept the designated requirement as a
stable identity — it pins the grant to the cdhash, which every build changes.

### What this means for the plan

`Scripts/create-signing-identity.sh` was carried over from `nyx`, where its stated purpose is
keychain access *and* TCC. It genuinely fixes the keychain half — that check is DR-based. **It does
not fix the TCC half for a self-signed identity.** R2's mitigation as written in the plan does not
work, and the plan should be corrected rather than the finding worked around.

Options, in order of preference:

1. **Sign development builds with a real Developer ID** (Apple Developer Program, ~A$150/yr). A
   Developer ID certificate carries a TeamIdentifier, TCC uses the DR, and grants survive rebuilds.
   This is the only option that actually removes the friction, and it is needed for notarization at
   M6 regardless — so the cost is being paid either way, just earlier.
2. **Accept re-granting during development.** Workable but genuinely costly for this app: M2 and M5
   iterate directly on Accessibility-dependent code, and a stale grant presents as "paste silently
   does nothing", which is indistinguishable from the bug you are actually hunting.
3. **Keep a permission-testing build separate from the iteration build** — grant one stable bundle,
   and only rebuild it when the paste path itself changes. Mitigates but does not fix.

**Recommendation: option 1**, and early. Also add a startup diagnostic that logs
`AXIsProcessTrusted()` on every launch, so a revoked grant announces itself instead of looking like
a paste bug.

### A trap this investigation walked into

`open ClipRoidSpike.app` **re-activates an already-running instance** rather than launching the new
build. For several minutes that made a freshly-built, untrusted binary look trusted, because the
process answering was the one launched an hour earlier from the granted build. When testing TCC
behaviour, always confirm the pid and its start time (`ps -o pid,lstart`) before drawing a
conclusion.

Separately: a binary exec'd directly from a shell can be attributed by TCC to its *responsible
process* — the terminal — so a paste that works from a shell may be riding the terminal's own
Accessibility grant. Both of these can manufacture a false pass. Verify via a fresh `open` launch
with a confirmed new pid.

---

## S4 — CGEvent paste round-trip — **PASS (first target)**

Confirmed end to end on 2026-09-11 17:25:17, against **Notes**, from the granted build:

> copied text in Claude Desktop → pressed `Ctrl+Cmd+V` in Notes → Notes received
> `ClipRoid spike paste 1789111517`

That single result closes both open questions at once:

- **S2 firing — PASS.** The Carbon handler fires on a real keypress from a background,
  `LSUIElement` app, with no window of its own.
- **S4 — PASS for a native Cocoa text view.** The whole sequence works: frontmost app captured
  before any of our UI appears, activation returned and confirmed via
  `didActivateApplicationNotification`, held modifiers waited out, `"v"` resolved against the live
  keyboard layout, `Cmd+V` posted to `.cghidEventTap` and delivered.

Note the marker text is what landed, not the user's copied text — that is correct spike behaviour.
The spike deliberately overwrites the pasteboard with a unique marker so that a successful paste is
unambiguous rather than something that could be explained by the clipboard's prior contents.

### Still to do: the per-app table

S4's deliverable is a per-app result, not a boolean, because the plan already accepts degradation in
terminals and Electron. Remaining targets, all currently running on this machine and covering the
cases that matter:

| Target | Bundle id | Case it exercises |
|---|---|---|
| TextEdit | `com.apple.TextEdit` | Plain `NSTextView` baseline |
| Brave | `com.brave.Browser` | Chromium web view |
| Discord | `com.hnc.Discord` | Electron |
| Terminal | `com.apple.Terminal` | Terminal, incl. bracketed paste |
| OneNote | `com.microsoft.onenote.mac` | Non-Apple native app |

`Spikes/SpikeApp` now takes `S4_TARGETS=<bundle-id,...>` and pastes into each in turn with no
keypress, so the whole table can be produced in one run once the bundle is granted again.

Pasting into a live app writes into the user's real documents, and in a chat app could put text in a
message box — so targets are confirmed with the user before running, never assumed.
