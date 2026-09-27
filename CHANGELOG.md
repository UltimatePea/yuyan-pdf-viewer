# Changelog

## v0.2.2 — 2026-09-27

### Added

- In-memory history for every successfully loaded PDF content change, without snapshot eviction during the app session.
- Compact Previous / version counter / Next controls in the existing single toolbar row. Click the counter to return to Latest.
- A Versions menu listing every snapshot with its original timestamp, plus ⌥⌘[ / ⌥⌘] / ⌥⌘0 shortcuts.
- Per-PDF histories that survive closing and reopening documents until the app exits.

### Behavior

- New builds are collected while browsing history without interrupting the selected version. Returning to Latest resumes live refresh.
- Version navigation preserves zoom, display mode and the reading location using text-anchor matching.
- History browsing never changes the PDF on disk or replaces saved jump-point anchors with matches from an older version.
- Invalid/partial data, outdated asynchronous results and consecutive identical PDFs are excluded. A revert on disk is recorded as a new chronological version.
- Explicit SyncTeX requests return to the latest version before navigating.

### Limits

- History is memory-only and clears on app exit. Memory use grows with the number and size of captured PDFs.
- Rebuilds overwritten before the viewer successfully captures them cannot be recovered. Text matching remains heuristic.
- Apple Silicon, macOS 26+. The bundled app is ad-hoc signed, not Apple-notarized.

## v0.2.1 — 2026-09-27

- Show the last successful PDF update as system-local `YYYY-MM-DD HH:mm:ss` in the bottom status bar.
- Preserve that timestamp when content is unchanged or a reload fails.

## v0.2.0 — 2026-09-27

- Persistent named jump points with automatic A–Z, AA, AB labels.
- Direct jump buttons in a single-row toolbar, ⌘D to set, ⇧⌘D to name, and ⌘1–⌘9 to jump.
- Right-click removal, rebuild anchoring and per-document persistence.

## v0.1.0 — 2026-09-20

- Initial native AppKit/PDFKit viewer powered by Yuyan Wasm-GC on V8.
- Reliable file reload, reading-position anchoring, Follow Edits, and SyncTeX CLI navigation.
- Self-contained Apple Silicon app bundle and application icon.
