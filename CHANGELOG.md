# Changelog

## v0.2.9 — 2026-11-23

- Store every version on disk, in `~/Library/Application Support/YuyanPDFViewer/Versions/`, so that the history and its change highlights are still there after the app is quit and reopened. A reopened PDF shows its latest stored version at once; older versions are read only when they are shown or compared.
- Add **Versions → Remove This Version**, **Remove Version** (a list of every version) and **Remove Earlier Versions…**. Once a version is removed, its neighbours are compared with each other, so removing a build that holds an unwanted edit leaves only the real difference highlighted. Removed versions are deleted from disk, and the last remaining version cannot be removed.
- Ask for confirmation before removing, because a removed version cannot be restored. The confirmation for a single version has a **Do not ask again** box; **Remove Earlier Versions…** always asks.
- Show at the end of the **Versions** menu how many versions of the document are stored and their size. Nothing is removed automatically.
- Keep a version for the session when it cannot be written, and say `not saved to disk` in the status bar. Do not show a stored PDF whose bytes do not match its name. Rebuild missing or outdated line and word caches from the stored PDF.
- Record version times in whole milliseconds, each later than the one before.

## v0.2.8 — 2026-11-23

- Add an overview bar along the left edge of the window. It stands for the whole document, like a scrollbar with marks: green where the version adds words, red where the next version deletes them, and a grey block for the part in view. Click or drag on it to go there; click a mark to go to that change.
- Add **↑** and **↓** buttons beside the version controls that go to the previous and the next set of changes, with **⌥⌘↑** / **⌥⌘↓** and View menu items. Changes within about two lines of each other form one set. Stepping visits a change that is already in view first, wraps around, keeps the horizontal scroll, and works in single-page display.
- Show the number of the visited set in the status bar, such as `Change 3/12`, and outline it on the bar.
- Hide the bar and the two buttons while **Highlight Changes** is off.

## v0.2.7 — 2026-11-23

- Highlight changes between consecutive PDF versions. Words added since the previous version have a green background. While viewing an older version, words that the next version deletes have a red background. The status bar shows the word counts, such as `+72 −147`.
- Turn the highlights off or on with **View → Highlight Changes**. They are on by default, apply to every window, and the choice persists across launches.
- Compare words instead of lines, so that layout changes are not reported: margin line numbers and page numbers, running headers and footers, rebroken lines, and words re-hyphenated at a line end.
- Do not mark text that only moved to another page, or that PDFKit reports in another order while it stands in the same place, as happens to tables, inference rules and proof steps when a page break or a margin number changes. Text that really moved within a page is still marked.
- Pass over rebuilds that change no words: each version is compared with the nearest earlier and later version whose words differ, so a rebuild without edits keeps the highlights of the last change.
- Recognise margin line numbers however PDFKit reports them: on a line of their own, at the head of the text line, or glued to its last word.
- Show change highlights together with search highlights, and rebuild them after refreshes, version changes and reopening a document.

## v0.2.6 — 2026-10-04

- Let history and jump points overflow to a second toolbar row when the window is too narrow to keep every control readable. Return to one row automatically when there is enough room.
- Give checkpoint buttons their full native height and remove the scrollbar reservation that clipped their labels on macOS 27. Additional points remain reachable by horizontal scrolling.
- Keep search and its navigation buttons on the first row with a readable field width, and resize the PDF area below the toolbar to prevent overlap.

## v0.2.5 — 2026-10-04

- Fix a crash while opening certain LaTeX PDFs on macOS 27. PDFKit can return a negative line-range length encoded as a huge unsigned value; reading that selection's text causes a fatal CoreFoundation trap.
- Validate every selection range against the page's character count with overflow-safe bounds checks before extracting text. Skip invalid lines while retaining rendering, valid text anchors, search and version history.
- Apply the same validation to search matches before using them for highlighting and navigation. Preserve the skipped-line count with each historical snapshot.
- Reproduced the original trap and verified the fix against a copy of the supplied 51-page PDF. The PDF and TeX sources are not modified.

## v0.2.4 — 2026-10-04

- Highlight every case-insensitive search match as the query changes, with a distinct active result.
- Add Previous and Next search buttons beside the search field. Both directions wrap around; ⌘G finds the next match and ⇧⌘G finds the previous match. The tooltip shows the current result and total.
- Recompute highlights when the displayed PDF refreshes or switches versions, preserving the reading position until search navigation is requested. Keep search state independent in each window.
- Clear stale highlights for empty queries, missing results and closed documents; disable navigation when there are no matches. Keep all controls in the single toolbar row.

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
