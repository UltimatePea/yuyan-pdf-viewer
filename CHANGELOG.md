# Changelog

## v0.2.3 — 2026-10-03

- Rename saved jump points from their toolbar context menu or the Jump Points menu. Labels update immediately and persist, while the saved location, stable ID, button order and keyboard shortcut remain unchanged.
- Open different PDFs in separate native windows through Open, Finder or drag-and-drop. Open accepts multiple files; New Window (⌘N) creates an empty window and Close Window (⌘W) closes only that window. An already open PDF reuses its existing window.
- Cycle through windows with ⌘` (forward) and ⇧⌘` (backward), also available in the Window menu.
- Keep independent Yuyan reload generations, debounce timers and retry state for each window. Concurrent rebuilds and background history browsing do not interfere with other documents.
- Retain document history in memory after closing its window for the remainder of the app session. Closing the last window quits the app.
- Preserve the single-row toolbar. Run native regression tests in background mode without activating the app.

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
