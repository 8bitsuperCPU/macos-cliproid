# Specification: macOS Clipboard Manager — "ClipRoid"

## 1. Product Vision

A native macOS clipboard and screenshot history app that saves everything the user copies into a beautiful visual timeline, grouped by type, app of origin, and custom categories. The app should feel like a first-class macOS citizen — fast, spatial, offline-first, and a joy to reuse from — not a utility bolted onto the system.

**Positioning**: The clipboard manager that treats your copied content as *assets*, not a flat log. Visual-first, searchable, organizable, and instant to paste from anywhere.

---

## 2. Target Platforms & Requirements

| Attribute | Value |
|---|---|
| Platform | macOS only (v1) |
| Minimum OS | **macOS Tahoe 26.0+** (revised from 14.0 — unlocks FoundationModels for §4.18 in v1, and ScreenCaptureKit without availability guards) |
| Distribution | Mac App Store or direct download (DMG/lead-through) |
| License model | One-time purchase, lifetime updates, no subscription |
| Trial/Refund | 14-day money-back guarantee |
| Install scope | Per-user, no admin rights required for core features |

---

## 3. Core User Problems This Solves

1. **Clipboard amnesia** — copied something useful and lost it 5 minutes later.
2. **List fatigue** — existing clipboard managers are plain text logs; users want visual previews of images, colors, files, screenshots.
3. **Context switching** — opening a separate window to find and paste breaks flow.
4. **Organization debt** — clips pile up ungrouped; users can't find "that screenshot from dashboard" or "the blue color from yesterday."
5. **Sensitive leakage anxiety** — passwords, tokens, private text accidentally persisted forever.
6. **Cross-device gap** — clips don't follow the user across Macs (iCloud sync gap in v1 competitors).

---

## 4. Feature Specification

### 4.1 Clipboard Capture & Storage

- **Global hot-monitor**: install a system-wide clipboard change listener (macOS `NSPasteboard` change count / `pasteboardChangedCount` polling at low interval, or a proper pasteboard observer if available). Capture every change.
- **Debounce identical consecutive copies**: if the same string/image/file appears N times in a row from the same app within a short window, collapse to a single clip entry with a "repeated from App X" hint.
- **Supported clip content types**:
  - Plain text (UTF-8)
  - Rich text (RTF/HTML — store the HTML, render preview)
  - Files and directories (file URLs / aliases — store path, size, icon, thumbnail)
  - Images (PNG, JPEG, HEIC, TIFF, SVG — store as `NSImage`/file, generate thumbnail)
  - Colors — detect when clipboard contains color data (hex, NSColor pickers, color codes) and render a color swatch preview
  - Code — detect code-like text (common languages) and syntax-highlight preview
  - Links/URLs — detect URLs, render favicon + preview card
  - Screenshots (captured by the app itself or pasted from other apps)
  - Multiple-item clipboard — if the pasteboard contains multiple items, store as a "multi-clip" card (see 4.9)
- **Snapshot on capture**: for each clip, store metadata:
  - `clipId` (UUID)
  - `contentType` enum (text, richText, image, file, color, code, link, screenshot, multiClip, unknown)
  - `copiedAt` timestamp (Date)
  - `sourceAppBundleId` (Bundle identifier of the frontmost app when copied, via `NSWorkspace.shared.frontmostApplication`)
  - `sourceAppName` (human-readable)
  - `contentLength` (chars for text, bytes for binary)
  - `thumbnailData` (resized PNG/JPEG thumbnail for visual preview)
  - `fullContent` (the actual data — text string, image data, file references, etc.)
  - `categoryIds` (array of custom category IDs, initially empty)
  - `sensitivity` (none | personal | secret, see 4.7)
  - `tags` (auto-detected tags, see 4.6)
  - `reminderAt` (optional Date)
  - `shortcut` (optional string, see 4.5)
  - `isFavorite` (bool)
  - `isPinned` (bool — keep at top of timeline)
  - `sourceWindowTitle`, `sourceUrl` — **best-effort and nullable**. Window titles require Screen
    Recording (`CGWindowListCopyWindowInfo`) or Accessibility; browser tab URLs require per-app
    Automation consent and are unavailable in several browsers. No UI may depend on either being present.

### 4.2 Visual Timeline (History View)

- **Default view**: a horizontally-scrollable or vertical-time-lined visual strip of recent clips, newest first.
- **Card types** (each renders a distinct preview based on content type):
  - Text card: first ~80 chars preview, app icon + name, time ago
  - Image card: thumbnail, dimensions, file size
  - Color card: large swatch with hex/RGB label
  - Code card: syntax-highlighted first ~6 lines
  - File card: file icon, name, size, kind
  - Link card: favicon, domain, title if available
  - Screenshot card: full thumbnail
  - Multi-clip card: collaged previews of constituent items
- **Grouping**: clips auto-group by "session" — visually separate clips copied in different time windows or different apps with subtle dividers. Reference the "grouped by app" aesthetic of Supaste (a competitor product — named here purely as a visual reference, not as this product's name).
- **App badge column**: each card shows the source app icon + name (e.g., "Safari", "Figma", "Xcode", "Slack", "Mail").
- **Type filter chips**: row of toggleable chips above the timeline — All, Text, Links, Images, Screenshots, Files, Code, Colors, Assets. Selecting a chip filters the timeline to that type.
- **App filter dropdown/search**: filter timeline to clips from a specific app (autocomplete from known bundle IDs).
- **Smart Filter** (auto-grouping rule engine):
  - Auto-assign clips to categories based on rules the user can configure (e.g., "all clips from Figma → 'Design Assets' category", "all images → 'Screenshots' category", "all text containing 'http' → 'Links' category").
  - Rules are evaluated at capture time and also retroactively on existing clips.
  - Store as `SmartFilterRule` model: `id`, `name`, `categoryId`, `contentType`, `sourceAppBundleId`, `textPattern` (regex or substring), `enabled`.
- **Search bar**: full-text search across all clips. Support search syntax:
  - Free text → matches text content, filenames, OCR text from images
  - `@text`, `@image`, `@link`, `@file`, `@code`, `@color`, `@screenshot` — type filter tokens
  - `@appname` or `@bundleId` — app filter token (e.g., `@Safari`, `@Figma`)
  - date-relative tokens: `today`, `yesterday`, `this week`, `@2025-01-15`
  - Combine: `dashboard @screenshot @today`
- **Infinite scroll / pagination**: virtualized list for performance with thousands of clips.

### 4.3 Notch Shelf / Always-Visible Strip

- **Notch/dynamic-island style shelf**: a thin horizontal strip that lives at the top of the screen (macOS notch area on compatible Macs) or alternatively can be placed on left/right/bottom edge per user preference.
- **Shows last N clips** (default 10, configurable 5–20): small thumbnail/preview cards, newest on the right or left per preference.
- **Each shelf item**: miniaturized preview, app icon, type badge.
- **Hover/expanding**: hovering a shelf item expands a larger tooltip preview with more content detail.
- **Click behavior options** (user preference):
  - Click → open ClipRoid search window focused on that clip
  - Click → immediate paste (with confirmation or direct, per preference)
  - Drag from shelf item → drag the clip data into any app (drag-and-drop source)
- **Shelf position preference**: top (default, notch-compatible), left, right, bottom. Shelf can be hidden entirely.
- **Shelf item limit**: don't show `secret` clips on shelf by default (respect per-clip "show on shelf" toggle or global setting).

### 4.4 Quick Search / Quick Paste Window

- **Global hotkey**: `Ctrl+Cmd+V` (default, user-remappable) opens a floating, borderless, SwiftUI search window positioned near the cursor or at a fixed screen position.
- **Window design**:
  - Compact, translucent or frosted-glass aesthetic consistent with macOS window style.
  - Large input field at top (search).
  - Results list below — visual cards, not plain text.
  - Keyboard navigable: arrow up/down, Enter to paste/insert, Esc to close.
  - Mouseless operation is the primary path.
- **"Quick Paste" mode**: if user types a search that matches exactly one clip, pressing Enter pastes it immediately without further confirmation.
- **Inline shortcut expansion** (see 4.5): if the search input starts with a registered shortcut (e.g., `;welcome`), expand it inline — replace the shortcut text in the active app with the clip content. This is the "type your shortcut anywhere" feature.
- **Positioning**: window should appear near the current cursor but not obscure it; remember last position per monitor.

### 4.5 Inline Shortcuts

- **Shortcut model**: each clip can have an associated shortcut string (e.g., `;welcome`, `;addr`, `;snippet1`).
- **Shortcut constraints**: alphanumeric + underscore + hyphen, starting with a non-alphanumeric prefix (default `;`) to avoid accidental expansion in normal typing. Configurable prefix char.
- **Expansion behavior**:
  - When the user types the shortcut prefix + shortcut string in any text field, ClipRoid detects the pattern and on a configurable trigger (space, enter, or immediate) replaces the shortcut text with the clip content.
  - Replacement is done via synthetic keystrokes or pasteboard write + Cmd+V simulation — must work in native text fields, web views, and terminal apps where possible.
  - For rich content (images, files), trigger a paste of the content.
- **Shortcut management UI**: in the clip detail panel or Library, an "Inline Shortcut" field where user assigns/edits/remove shortcut for a clip.
- **Shortcut conflicts**: warn if a shortcut is already assigned to another clip; allow reassignment.
- **Shortcut search in Quick Search**: typing `;welcome` in the quick search bar finds that clip immediately.

### 4.6 Tags & Smart Auto-Tagging

- **Auto-tags applied at capture time**:
  - `text`, `link`, `image`, `screenshot`, `file`, `code`, `color`, `asset`, `email` — based on content type detection.
  - App-derived tag: source app name (e.g., `Safari`, `Figma`, `Xcode`, `Slack`).
  - OCR-derived tags for images/screenshots (see 4.8).
  - Domain tag for URLs (e.g., `github.com`, `figma.com`).
- **Manual tags**: user can add/remove tags on any clip in the detail panel.
- **Tag cloud / faceted search**: in Library, show tag frequencies; clicking a tag filters.

### 4.7 Sensitive Content Detection

Detection is **tiered**. A flat "sensitive/not sensitive" boolean that fires on every email address
and phone number would blur most ordinary clips, turn the badge into noise, and get the whole feature
switched off — which is worse than not having it.

- **Tier `secret`** — high-confidence, high-consequence. Blurred in the timeline until explicitly
  revealed, excluded from the Notch Shelf by default, eligible for auto-deletion.
  - Private keys (`-----BEGIN … PRIVATE KEY-----`), JWTs, AWS access key / secret key shapes,
    common API-key formats (`sk-`, `ghp_`, `xoxb-`, …), 2FA backup codes.
  - Credit card numbers passing a **Luhn check** (the check is what keeps this out of false-positive
    territory — a bare 16-digit run is not a card number).
  - Anything the pasteboard itself declares as `org.nspasteboard.ConcealedType` — this is what
    password managers set, and it is the single most reliable signal available.
- **Tier `personal`** — recorded on the clip and filterable, but **not blurred and not hidden** by default.
  - Email addresses, phone numbers, IP addresses, postal addresses.
- **Not flagged at all**: bare keyword matching on "password" / "secret" / "token" / "key" / "private" /
  "confidential". These fire constantly on ordinary prose and documentation, and they were the main
  source of noise in the original draft.
- **When a `secret` clip is detected**:
  - Set `sensitivity = .secret` and record `sensitiveReason` (which rule matched, for the detail panel).
  - Exclude from the Notch Shelf by default.
  - Show a badge; blur the preview until click-to-reveal.
  - Option: auto-delete after N hours/days (configurable retention rule).
  - Option: never capture matching clips at all (blocklist mode — warn the user, don't store).
- **User overrides**: the user can raise or lower any clip's tier manually.
- **Honesty requirement**: document clearly that detection is heuristic and local, and is not guaranteed
  to catch everything. It is a convenience, not a security boundary.

### 4.8 Screenshot & Image OCR

- **Screenshot capture**:
  - Built-in screenshot tool: a screenshot button in ClipRoid opens the macOS screenshot capture mode (or uses a custom screenshot capture that writes to clipboard + ClipRoid simultaneously).
  - Option to auto-capture screenshots to ClipRoid (every screenshot taken anywhere on the system is also saved to ClipRoid history — requires accessibility permission or a screenshot notification observer).
- **OCR pipeline**:
  - On capture of an image or screenshot, run OCR (Apple's Vision framework `VNRecognizeTextRequest`) to extract text.
  - Store extracted text alongside the image clip, indexed for search.
  - User can search images by their visible text: "error message screenshot", "receipt total", "the text in that dashboard screenshot".
- **Image metadata extraction**: EXIF data, dimensions, color profile — store and surface in detail view.

### 4.9 Multi-Clip Copy

- **Multi-clip model**: a clip card can aggregate multiple content items from different copy operations.
- **UI to build a multi-clip**:
  - In the Library or timeline, user can select multiple clips and "Combine into multi-clip" — creates a new card containing all selected items in order.
  - Or: a "collect" mode where user clicks clips to add to an in-progress multi-clip buffer, then "Paste all" or "Save as multi-clip".
- **Pasting a multi-clip**: pastes items in sequence — for text items, concatenates with configurable separator (newline, space, or custom); for images/files, paste each in turn (or place them depending on target app capability).
- **Use cases**: collect a code snippet + a link + a screenshot into one card to paste into a report; collect multiple lines of text from different apps.

### 4.10 Clip Reminders

- **Reminder model**: any clip can have a reminder attached.
- **Reminder types**:
  - "Remind me in N minutes/hours/days" (relative).
  - "Remind me on [date/time]" (absolute).
  - "Remind me when I return to [app]" — when the user switches back to the app where the clip was originally copied from, show a notification/reminder for that clip.
- **Delivery**: macOS UserNotifications framework — local notifications. Notification content shows a preview of the clip (respecting sensitive masking) and offers actions: "Paste Now", "Dismiss", "Open in ClipRoid".
- **Reminder management UI**: in clip detail, a "Remind me" button with a date/time picker or app-selector.

### 4.11 Library View (Full Window)

- **Full Library**: a larger, resizable SwiftUI window showing the complete clipboard history with more detail than the timeline.
- **Layout modes**:
  - Timeline (vertical, chronological)
  - Grid (masonry/album-style layout — images and visual items larger)
  - List (dense, text-focused)
- **Sidebar**:
  - Categories (custom + auto-generated: Recent, Favorites, Pinned, Screenshots, Images, Text, Links, Files, Code, Colors, Assets)
  - Smart Filters (list of user's smart filter rules, clickable to apply)
  - Tags (tag cloud / tree)
- **Detail panel**: selecting a clip opens a detail panel (slide-over or split) showing full content, metadata, actions (copy, paste, edit, pin, favorite, add to category, set shortcut, set reminder, delete, share).
- **Edit content**: user can edit text clips inline in the detail panel — modify the text, and the edited version replaces the stored content.
- **Bulk actions**: select multiple clips → delete, move to category, pin, favorite, export.

### 4.12 Drag and Drop

- **Drag from ClipRoid**: any clip card in any ClipRoid UI (timeline, shelf, Library, quick search results) is a drag source. Drag the card into another app to paste that content.
  - Text → drags as `NSStringPboardType` / `public.utf8-plain-text`
  - Image → drags as `NSImage` / `public.png` / `public.jpeg`
  - File → drags as file URLs
  - Color → drags as color data if target supports it
- **Drop target**: ClipRoid can receive drops — dropping an image/file/text onto ClipRoid adds it as a new clip.

### 4.13 Color Picker Tool

- **Built-in color picker**: a tool within ClipRoid that:
  - Picks a color from anywhere on screen via `NSColorSampler` — the system loupe. **No Screen Recording permission required.**
  - Copies the picked color to clipboard in multiple formats (HEX, RGB, HSL, NSColor) — user chooses format.
  - Saves the picked color as a new color clip in history automatically.
- **Color clip**: special clip type with swatch preview, hex value, RGB/HSL values, and a "copy as HEX/RGB/HSL" action.

### 4.14 Text Capture Tool

- **Text from image**: a tool that lets the user select a region of the screen, captures it, runs OCR, and copies the extracted text to clipboard + saves as a text clip.
- **Text from app**: capture selected text from any app and save it as a clip with source context.

### 4.15 Quick Notes

- **Quick Notes**: a lightweight text note tool inside ClipRoid — a small text editor window for scratch notes that the user wants to keep temporarily.
- Notes are saved as text clips in the history with a "note" tag.
- Quick Note hotkey opens a small floating text field near cursor; Esc or Cmd+Enter saves it as a clip.

### 4.16 iCloud Sync (v2+)

- **Model**: Sync clipboard history across the user's Apple devices via iCloud CloudKit.
- **Scope**: clips, categories, smart filters, shortcuts, favorites, pins, reminders — the user's data.
- **Conflict resolution**: last-write-wins per clip, with merge of non-conflicting fields. Clip IDs are stable across devices.
- **Privacy**: content is encrypted in iCloud via CloudKit's private database (user's iCloud account, not ClipRoid servers). ClipRoid's servers never see the content.
- **Per-device discretion**: option to mark certain clips/categories as "local only" (not synced).
- **iOS companion app** (v2+): read-only or full sync of clipboard history to iPhone/iPad; quick paste from iOS.

### 4.17 Dropbox Integration (v2+)

- **Share to Dropbox**: user can send a clip (especially files, images, screenshots) directly to a Dropbox folder.
- **Dropbox badge**: clips stored in Dropbox (shared files) can show a Dropbox badge/link to open in Dropbox.
- **Auth**: Dropbox OAuth2, stored in keychain.

### 4.18 Apple Intelligence Integration (v2+, macOS 15+)

- **Text actions on clips** (requiring Apple Intelligence / LLM capabilities where available):
  - Rewrite text clip (formal, concise, expand, custom tone).
  - Summarize text clip.
  - Extract key points / bullet list from text clip.
  - Translate text clip to another language.
- **Image actions**:
  - Describe image (generate alt-text / caption for a screenshot or image clip).
- **UI**: in clip detail panel, an "Apple Intelligence" section with action buttons; results replace or supplement the clip content.
- **Graceful degradation**: if Apple Intelligence is unavailable (OS version, region, or not enabled), these buttons are hidden or disabled with a tooltip explaining why.

### 4.19 Settings / Preferences

- **General**:
  - Notch shelf position (top/left/right/bottom/off)
  - Shelf item count (5–20)
  - Quick Paste hotkey (default Ctrl+Cmd+V, remappable)
  - Recent clips hotkeys (Ctrl+Cmd+0–9, remappable, enable/disable per slot)
  - Start at login (launch at login toggle)
  - Launch minimized to menu bar / notch
  - Confirm before pasting sensitive content
- **Capture**:
  - Capture screenshots automatically (toggle)
  - Capture files (toggle)
  - Capture rich text (toggle)
  - Ignore clips from specific apps (blacklist)
  - Max clips to retain (count-based or age-based retention — e.g., keep last 10,000 clips or clips younger than 90 days)
  - Storage location (default: `~/Library/Application Support/ClipRoid/` — user can't choose, but should be able to see size)
- **Sensitive content**:
  - Enable/disable sensitive detection
  - Show/hide `secret` clips in shelf
  - Auto-delete `secret` clips after (never / 1h / 24h / 7d / 30d)
- **Categories**: manage custom categories (create, rename, delete, reorder, color/icon).
- **Smart Filters**: manage rules (create, edit, delete, reorder).
- **Shortcuts**: manage inline shortcuts list, change prefix character.
- **Appearance**:
  - Theme: Light / Dark / System
  - Shelf style: compact / comfortable
  - Card preview size
- **Sync**:
  - iCloud Sync (on/off)
  - Selective sync categories (which categories sync)
  - "Local only" per-clip toggle
- **About**:
  - License / activation (if license-key based) or purchase receipt validation
  - Check for updates
  - Privacy policy link
  - Support / feedback link

### 4.20 Onboarding & First Run

- **First launch**: intro overlay explaining the 4 main ways to use the app (Notch shelf, Quick Paste, Library, Search).
- **Permission requests**: accessibility (if needed for hotkey/global behavior), screen recording (for color picker / screenshot tool), notifications (for reminders). Request contextually, not all at once.
- **Empty state**: when history is empty, show a friendly illustration + "Copy something — your clipboard history starts here."

---

## 5. User Roles / Personas (Feature Prioritization Lens)

| Persona | Key workflow | Priority features |
|---|---|---|
| Designer | Copy colors, icons, SVGs, screenshots, visual references | Color picker, image previews, asset organization, screenshot OCR, categories for brand assets |
| Developer | Save code snippets, commands, errors, JSON, API responses, GitHub links | Code syntax highlighting, multi-clip (combine snippet+link), search by app (Xcode, Terminal), inline shortcuts for boilerplate |
| Content/Marketing | Capture hooks, taglines, SEO keywords, drafts, research links, campaign screenshots | Search, categories for campaigns, inline shortcuts for recurring copy, link previews |
| Sales/Support | Reuse replies, email templates, product links, support screenshots | Inline shortcuts for templates, categories for teams, quick paste, reminders to follow up |
| Founder/Operator | Organize investor notes, product ideas, competitor screenshots, pricing pages, links, research | Library view, categories, screenshot OCR, smart filters by app |
| Personal | Links, addresses, tracking numbers, images, screenshots, recipes, quotes | Search, visual previews, quick paste, dock shelf access |

---

## 6. UX Principles

1. **Visual over textual**: the app should feel like a visual gallery of your copied assets, not a spreadsheet or log. Thumbnails, swatches, syntax highlighting, favicons — every clip should have a visual identity.
2. **Zero-friction reuse**: the most common action (paste/reuse) should take one keystroke from anywhere, without opening a window. `Ctrl+Cmd+V` → search → Enter.
3. **Spatial memory**: users should be able to find things by "where" — app it came from, when it was copied, what category it's in — not just by text search.
4. **Stay out of the way**: the Notch shelf is glanceable; the Quick Paste window is transient; the Library is for organization. The app runs quietly in the background and only appears when you ask it to.
5. **Respect privacy by default**: sensitive content detection, local-first storage, no crashes, no analytics phone-home. Sync (when added) goes through the user's own iCloud, not a third-party server.
6. **Keyboard-first with mouse fallback**: everything should be doable from keyboard; mouse users get drag-and-drop and visual browsing.
7. **Beautiful but not precious**: the UI should be clean, modern, and macOS-native in feel — frosted glass, system colors, SF Symbols, rounded cards, subtle motion. It should feel like it belongs on a Mac, not like a web page wrapped in AppKit.

---

## 7. Visual & UI Direction

- **Design language**: macOS 14/15 aesthetic — translucent materials where appropriate, SF Symbols icons, SF Pro typography, system blur materials, rounded corners (10–14pt), subtle shadows, ample whitespace.
- **Color palette**: neutral grays for structure, one accent color (user-configurable, default a warm blue or teal) for interactive elements and highlights. Category chips use distinct accent colors (configurable per category).
- **Card design**:
  - Rounded rectangle card, ~60–80pt tall in timeline, larger in Library.
  - Left: content preview (thumbnail/swatch/preview) — 48–64pt square or wide depending on type.
  - Middle: primary label (text snippet, filename, color value) + secondary (app name + time ago).
  - Right: type badge (small pill) + optional actions on hover (pin, favorite, more).
- **Shelf design**: thin horizontal strip, ~48–60pt tall, items 56–64pt wide pills or cards, scrollable horizontally. Glass/frosted background.
- **Quick Search window**: ~400–500pt wide, ~300–400pt tall, compact. Search field with magnifying glass icon. Results list with card items. Keyboard shortcut hints in footer or as overlay.
- **Icons**: SF Symbols for all UI actions (magnifying glass, folder, photo, textformat, link, code, paintbrush for color, pin, star, tag, scribble for notes, clock for reminders, iCloud, gear, etc.).
- **Empty states**: illustrated, friendly, actionable.
- **Loading/processing**: subtle shimmer or skeleton for OCR-in-progress on images; don't block UI.

---

## 8. Technical Architecture

### 8.1 Platform & Stack

| Layer | Technology |
|---|---|
| UI framework | SwiftUI (primary) + AppKit view controllers where needed (e.g., floating window positioning, pasteboard access, screen recording) |
| Language | Swift 5.9+ |
| Min deployment target | macOS 26.0 (Tahoe) |
| Persistence | **Raw SQLite3** (`import SQLite3` + `.linkedLibrary("sqlite3")`) with an **FTS5** external-content index for search. No third-party dependency — the system sqlite3 has `ENABLE_FTS5`. Binary content (images, files) stored as individual files on disk, metadata + FTS index in the DB. |
| Storage path | `~/Library/Application Support/ClipRoid/` — `clips/<2-hex-shard>/<uuid>.<ext>` for binary blobs, `ClipRoid.sqlite` for metadata, `Backups/` for pre-migration snapshots. |
| Settings | `UserDefaults` (standard + suite) for preferences; Keychain for secrets (Dropbox tokens, license). |
| Notifications | UserNotifications framework (UNUserNotificationCenter) for reminders. |
| OCR | Vision framework (`VNRecognizeTextRequest`) — macOS 13+ support; fallback if unavailable. |
| Color picking | `NSColorSampler().show { }` — the system loupe, **requires no permission at all**. Do not hand-roll screen sampling; `CGWindowListCreateImage` and `CGDisplayStream` are deprecated (macOS 14) and would need Screen Recording for no benefit. |
| Screenshots | `SCScreenshotManager.captureImage(contentFilter:configuration:)` (ScreenCaptureKit) behind a custom region-select overlay. `CGWindowListCreateImage` is deprecated since macOS 14. Requires Screen Recording. |
| Global hotkeys | Carbon `RegisterEventHotKey` or NSEvent `addGlobalMonitorForEvents(matching: .leftMouseDown)` + listen for hotkey combo via a small Objective-C++ helper or a library like `HotKey` (open source). |
| Pasteboard access | `NSPasteboard.general` — monitor `changeCount`, read available types. Use an `NSPasteboardChangeCount` observer loop on a background timer (e.g., 300ms) for reliable capture, since macOS doesn't provide a robust async pasteboard change callback for all content types. |
| App identity | `NSWorkspace.shared.frontmostApplication` to get SourceApp at capture time; `NSRunningApplication.bundleIdentifier`. |
| Privacy permissions | Request at context: Screen Recording (for color picker/screenshot), Accessibility (if needed for global hotkey paste simulation), Notifications, iCloud (for sync). |
| iCloud sync | CloudKit (private database). Model clips as CloudKit records with content in a CloudKit asset (encrypted). Use `CKDatabase` and `CKFetchRecordZoneChanges` / `CKModifyRecordsOperation`. |
| Dropbox | Dropbox SDK for Swift / OAuth2 web flow; store `DBSession` / token in Keychain. |
| Apple Intelligence | `Foundation` / `Core ML` / `Apple Intelligence` APIs where exposed (as of macOS 15, some text generation actions are available through system services; design against the API surface available at ship time and abstract behind a protocol so it can be stubbed if unavailable). |
| Build system | Xcode project + Swift Package Manager for dependencies. |
| Distribution | Either Mac App Store (sandboxed, some features restricted) or direct .app download + notarization (more flexibility for global hotkeys, screen recording, pasteboard monitoring). Given the feature set (global hotkeys, screen recording, deep pasteboard monitoring), **direct download + notarization** is the recommended distribution path for v1. Polar.sh or similar for paid checkout. |

### 8.2 Data Model (Core Entities)

```
Clip {
  id: Int64                          // SQLite rowid; FTS5 external content requires an integer key
  uuid: UUID                         // stable identity (survives across devices for Phase 3 CloudKit)
  contentType: ClipContentType       // text | richText | image | file | color | code | link | screenshot | multiClip | note | unknown
  contentHash: String                // SHA-256 of canonical payload, for dedupe

  // Text indexed by FTS5. Column names must match the fts5() column names.
  body: String?                      // indexable text; capped at 1MB indexed
  ocrText: String?                   // OCR-extracted text, filled in asynchronously after capture
  title: String?                     // filename / link title / color name

  // Binary payloads live ON DISK. These are paths, never inline Data — a timeline
  // holding 10,000 inline thumbnails is exactly what breaks the §13 perf criterion.
  textBlobPath: String?              // only when text > 256KB
  imageBlobPath: String?
  thumbBlobPath: String?
  htmlBlobPath: String?
  faviconBlobPath: String?
  imageWidth: Int?
  imageHeight: Int?
  exifJson: String?

  colorHex: String?
  linkUrl: String?
  linkHost: String?

  sourceAppBundleId: String?
  sourceAppName: String?
  sourceWindowTitle: String?         // BEST-EFFORT: needs Screen Recording or Accessibility. Nullable. No UI may depend on it.
  sourceUrl: String?                 // BEST-EFFORT: needs per-app Automation consent; unavailable in several browsers.

  copiedAt: Int64                    // ms since epoch (not ISO-8601 — cheaper to range-scan)
  storedAt: Int64
  contentSizeBytes: Int64
  repeatCount: Int                   // consecutive identical copies collapse into one row (§4.1)

  isPinned: Bool
  isFavorite: Bool
  isLocalOnly: Bool                  // excluded from iCloud sync
  sensitivity: Sensitivity           // none | personal | secret  (see §4.7)
  sensitiveReason: String?
  shortcut: String?
  reminderAt: Int64?
  reminderType: ReminderType?        // relative | absolute | appReturn
  reminderAppBundleId: String?
  notes: String?
  enrichmentState: EnrichmentState   // pending | done | failed | notApplicable — the OCR/thumbnail worklist
}

// File clips are one-to-many; a single copy can carry several file URLs.
ClipFile {
  clipId: Int64
  ordinal: Int
  path: String
  bookmark: Data?                    // security-scoped bookmark, so the path survives a move
  sizeBytes: Int64?
  uti: String?
  iconBlobPath: String?
}

Category {
  id: UUID
  name: String
  color: String?                     // accent color hex
  iconName: String?                  // SF Symbol name
  sortOrder: Int
  isSmart: Bool                      // auto-generated vs user-created
  smartRuleId: UUID?
}

SmartFilterRule {
  id: UUID
  name: String
  categoryId: UUID
  enabled: Bool
  contentType: ClipContentType?      // nil = any
  sourceAppBundleId: String?
  textPattern: String?               // substring or regex
  isRegex: Bool
}

InlineShortcut {
  id: UUID
  shortcutText: String               // e.g. ";welcome"
  clipId: UUID
  prefixChar: String                 // default ";"
  createdAt: Date
}

Settings {
  // persisted in UserDefaults + CloudKit for sync of preferences
  shelfPosition: ShelfPosition        // top | left | right | bottom | hidden
  shelfItemCount: Int
  quickPasteHotkey: Hotkey
  recentClipHotkeys: [Hotkey?]       // 10 slots
  quickPasteWindowPosition: CGPoint
  theme: Theme                       // light | dark | system
  captureScreenshotsAutomatically: Bool
  captureFiles: Bool
  captureRichText: Bool
  ignoredAppBundleIds: [String]
  maxClipCount: Int?
  maxClipAgeDays: Int?
  sensitiveDetectionEnabled: Bool
  sensitiveExcludeFromShelf: Bool
  sensitiveAutoDeleteAfter: SensitiveRetention
  shortcutPrefixChar: String
  iCloudSyncEnabled: Bool
  syncCategoryIds: [UUID]
  dropboxConnected: Bool
}
```

### 8.3 Key Technical Considerations

- **Pasteboard monitoring reliability**: macOS `NSPasteboard` change-count polling is the most reliable general approach. Poll at ~200–500ms on a low-priority background thread. Debounce identical consecutive contents. Be careful: the pasteboard can contain large data (e.g., a 50MB image); cap captured size (e.g., 200MB max per clip, configurable) and skip abnormally large items with a log.
- **Hotkey registration**: global hotkeys on macOS require either a registered event hotkey (Carbon) or an event tap. Consider a well-maintained open-source Swift hotkey library to reduce FFI surface. The hotkey must work when the app is in the background / not frontmost.
- **Simulated paste for inline shortcuts**: after detecting a shortcut pattern in the active text field, the app must replace the shortcut text with the clip content. This is notoriously tricky across app types (native NSTextView, WebView, terminal emulators). Approach: select the shortcut range, delete it, write content to pasteboard, send Cmd+V. Provide a fallback: if detection of the text field selection fails, fall back to pasting at the current insertion point. Make this behavior configurable and testable.
- **Drag and drop**: implement `NSDragItem` / `NSDraggingSource` on clip views. Each clip type produces the appropriate pasteboard writer for its content.
- **OCR performance**: run OCR on a background queue; throttle to one OCR operation at a time; cache OCR results so re-indexing doesn't re-run OCR on the same image. For large images, downsample before OCR to speed up.
- **Storage growth**: clips can accumulate fast. Implement retention policies (count-based and/or age-based) and a background purger. Binary content (images, screenshots) takes the most space; consider a "full-resolution archive" mode where old images are downsampled but kept visually usable.
- **Sensitive detection performance**: run regex/heuristics on text clips at capture time (fast). Avoid running heavy checks on every search — pre-compute the `sensitivity` tier at capture time.
- **Threading model**: all clip capture, OCR, and disk I/O should be off the main thread. SwiftUI views observe an `@Observable` or Combine-driven view model that publishes clip updates on the main thread.
- **App Sandbox trade-offs**: if distributing outside the Mac App Store (recommended for v1 given hotkey + screen recording + pasteboard access), the app is unsandboxed and has full access. If targeting the Mac App Store, many features (global hotkey, screen recording, full pasteboard history of other apps) may be restricted or require specific entitlements that Apple may or may not grant — validate early.

---

## 9. Permissions & Privacy Model

- **Privacy promise (marketing-level)**: "Fully offline. Your clipboard never leaves your Mac unless you choose to sync via iCloud. No analytics. No tracking."
- **Permissions requested and why**:
  - **Screen Recording**: for Color Picker and Screenshot tools (capture screen content). Clearly explain in the permission prompt and onboarding.
  - **Accessibility**: only if needed for global hotkey paste simulation or window detection beyond what `NSWorkspace` provides. Prefer non-Accessibility approaches first; request Accessibility only if a real need emerges.
  - **Notifications**: for clip reminders — request at first reminder creation, not at first launch.
  - **iCloud**: for sync — user opts in explicitly in Settings.
- **Data location**: all data in user's home directory (`~/Library/Application Support/ClipRoid/`). No external servers.
- **No analytics**: do not phone home. If you add any diagnostics, make it explicitly opt-in and describe exactly what is collected.
- **Sensitive content**: document clearly that detection is heuristic and local; it is not guaranteed to catch everything. Provide manual override.

---

## 10. Edge Cases & Error Handling

- **Very large clipboard items**: cap capture size (default **50MB** per item; 200MB configurable ceiling). Log and skip items over the cap with a brief notification "Clip too large to save — skipped."
- **Binary/unknown content types**: store as "unknown" with a generic icon and the raw data preserved; allow user to delete. Don't crash on unexpected types.
- **Pasteboard cleared between poll intervals**: if the clipboard is modified and cleared in between two poll ticks, the change may be missed. This is acceptable for a clipboard *history* tool — document that extremely fast copy-delete sequences may not be captured. Do not try to achieve perfect capture of every transient state; aim for "everything the user actually wanted to keep."
- **Multiple monitors**: shelf and Quick Search window must handle multiple monitors correctly. Shelf lives on one chosen screen edge (per preference); Quick Search appears on the monitor where the cursor currently is, or the last monitor it was used on.
- **App sleep / App Nap**: prevent the app from being squeezed by App Nap while it's doing capture or OCR. Use `ProcessInfo.processInfo.beginActivity(options:reason:)` and **retain the returned token** for the lifetime of monitoring — dropping the token is a silent no-op. Set `NSSupportsAutomaticTermination = false` and `NSSupportsSuddenTermination = false` in Info.plist. (An earlier draft named `NSProcessAssertActivity`, which is not an API.)
- **Keyboard layout changes**: when the user switches keyboard layouts (e.g., QWERTY → Dvorak → Japanese), the inline shortcut detection must still work on the *characters* typed, not the physical keys. Detect on the resulting string, not key codes. Test with non-US layouts.
- **Terminal / non-NS text views**: inline shortcut expansion may not work in all terminal emulators (iTerm2, Terminal.app) or in games and some Electron apps. Document the limitation. Prioritize native Cocoa text fields first.
- **Conflicts with other clipboard apps**: if another clipboard manager is running, both apps may see the same pasteboard changes and both try to capture. This is generally fine — each app independently captures. Warn in onboarding that running multiple clipboard managers may cause duplicate captures or conflicts with hotkeys.
- **iCloud sync conflicts**: if the same clip is edited on two devices simultaneously, use last-write-wins on the clip's core content with a "synced at" timestamp. Metadata-only changes (favorite, pin, category assignment) should merge safely. Show a subtle "synced" indicator and a sync error state if CloudKit returns errors.
- **Low disk space**: before capturing a large clip, check available disk space; if under a threshold (e.g., 500MB), warn the user and skip the capture or alert.
- **App upgrade / data migration**: store a schema version in the DB; on upgrade, run migrations. Keep old data readable. If the data format changes significantly, migrate in place and back up the old store to a timestamped archive folder before migrating.
- **Crash recovery**: after a crash, on next launch, verify DB integrity (`PRAGMA integrity_check` or equivalent) and repair/rebuild if needed. Show a brief "recovering clipboard history" overlay if recovery is happening.

---

## 11. Implementation Phases

### Phase 1 — Core (v1.0)

- Clipboard monitoring + capture (text, images, files, rich text)
- Visual timeline with type filters and app filters
- Notch shelf (top position, configurable count)
- Quick Search window (`Ctrl+Cmd+V`) with search + paste
- Inline shortcuts (assign + expand)
- Categories (custom create/assign)
- Smart filters (basic rule: by app, by type, by text substring)
- Sensitive content detection (text heuristics)
- Clip detail panel (copy, paste, delete, pin, favorite, edit text)
- Drag and drop from all views
- Settings: hotkeys, shelf position/count, theme, retention, capture toggles, ignored apps
- Screenshot capture tool (region capture → clip)
- Color picker tool
- First-run onboarding
- One-time purchase / license check (if monetized from day one) or free with paid upgrade path
- Distribution: direct .app, notarized

### Phase 2 — Intelligence (v1.5–v1.7)

- Image / screenshot OCR (Vision framework) + OCR-indexed search
- Clip reminders (relative, absolute, "when I return to app")
- Quick Notes tool
- Multi-clip copy (combine clips into one card)
- Bulk actions in Library (delete, categorize, pin)
- Apple Intelligence text actions (rewrite, summarize, extract, translate) where available; degrade gracefully
- Image actions (describe image) where available
- Advanced search tokens (`@today`, `@yesterday`, domain tags, OCR text search)
- Library layout modes (timeline / grid / list)

### Phase 3 — Connect (v2.0+)

- iCloud sync (CloudKit, private database, end-to-end encrypted at rest in iCloud)
- iOS companion app (read clipboard history, quick paste, search)
- Dropbox integration (share clips to Dropbox, badge for Dropbox-stored files)
- Additional shelf positions (left / right / bottom)
- More appearance customization
- Optionally: Mac App Store version (sandboxed) with reduced feature set, for users who prefer App Store distribution — evaluate entitlement feasibility early.

---

## 12. Non-Goals (v1)

- Windows / Linux / iOS in v1.
- Subscription billing — one-time purchase only.
- Clipboard *sharing* with other users — this is a personal tool.
- Full-text search across arbitrary file contents inside file clips (search filename and metadata, not file contents — too heavy).
- Clipboard *editing* for binary types (can't edit an image inline — replace by re-capturing or replace with a new image clip).
- macOS versions before Tahoe 26.0.
- Running as a menu-bar-only app with no window — the app should have real windows (shelf, quick search, library) even if it also has a menu bar icon for quick access.

---

## 13. Success Criteria / MVP Definition

- **Capture**: text, images, files, and rich text are captured reliably within ~1 second of being copied, with correct source app attribution.
- **Revisit**: the user can press `Ctrl+Cmd+V` anywhere, type a few characters, and paste the right clip in under 3 seconds.
- **Visual**: image clips show thumbnails; color clips show swatches; code clips show syntax-highlighted preview; file clips show icons — not just a text list.
- **Organize**: the user can create categories and assign clips; can filter by app and by type; can set a smart filter rule.
- **Shortcuts**: the user can assign `;welcome` to a clip and have it expand when typed in a text field.
- **Sensitive**: passwords / keys in copied text are flagged and hidden from the shelf by default.
- **Performance**: app uses minimal CPU when idle (no OCR, no capture processing); search returns results interactively with 10,000+ clips.
- **Privacy**: no network requests except optional iCloud sync and optional update check. No analytics.
- **Polish**: dark mode, multiple monitors, keyboard-only operation, empty states, first-run onboarding, and a clean, macOS-native visual style.

---

## 14. Open Questions for the Developer

1. **Distribution channel**: Mac App Store vs. direct download? This determines sandboxing, entitlements, and which features are feasible in v1. Recommendation: direct download + notarization for full feature access.
2. **Monetization at launch**: one-time purchase with license key / receipt validation from day one, or free tier with paid upgrade? For comparison, the competitor Supaste uses a one-time purchase with a limited-time early-bird price and a 14-day refund guarantee.
3. **Pasteboard monitoring approach**: poll `changeCount` on a timer (simple, reliable, slightly more battery) vs. attempt `NSPasteboard` change observer / event tap (lower latency, more complex). For v1, polling at 300ms is a reasonable starting point.
4. **Inline shortcut expansion reliability target**: accept that it works in most native text fields and degrades in terminals/Electron, or invest in an accessibility-based approach for broader coverage? The latter costs more and may require Accessibility permission.
5. **OCR backlog**: if the user copies 50 screenshots in a minute, OCR those 50 images immediately (high CPU, delays UI) or queue and process lazily (OCR results appear later, search for recent screenshots is incomplete briefly)? Recommend lazy/queued OCR with a progress indicator.
6. **Storage format for binary clips**: store each binary clip as a separate file (simple, easy to delete/purge) vs. a single packed archive (more complex, better space efficiency). Separate files per clip in `clips/` is simpler and matches the retention/purge model well.
7. **Screenshot capture**: use macOS's built-in screenshot tool and observe the pasteboard afterward, or build a custom region-select screenshot capture? Custom capture gives more control and faster integration with ClipRoid, but the built-in tool is what users already know. A custom region-select tool that also saves to clipboard is a good middle path.

---