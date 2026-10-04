# 阅卷 · Yuyan PDF Viewer

<img src="资源/图标.png" width="144" alt="Yuyan PDF Viewer icon">

A native macOS PDF viewer for papers that are continuously rebuilt with LaTeX. Application logic is written in **Yuyan**, compiled to **Wasm-GC**, and executed by embedded **V8**. AppKit and PDFKit provide the native interface and rendering.

## Download

[Download the latest release](https://github.com/UltimatePea/yuyan-pdf-viewer/releases/latest).

Unzip `Yuyan-PDF-Viewer-v0.2.6-macos-arm64.zip`, then open `阅卷.app` or move it to Applications.

- **Apple Silicon (arm64), macOS 26 or newer.** Intel builds are not included.
- Node/V8 and all non-system dynamic libraries are bundled. No Homebrew or Node installation is required to run the release.
- The app is ad-hoc signed, **not Apple-notarized**. macOS may require explicit approval in Privacy & Security before first launch.
- SyncTeX navigation optionally requires an installed `synctex` executable and a matching `.synctex.gz` file.

## Features

- Separate native windows for different documents, each with independent reading position, reloads and history. Open via **⌘O**, Finder or drag-and-drop; **⌘N** creates an empty window and **⌘W** closes the current window. **⌘`** cycles forward through windows; **⇧⌘`** cycles backward. Opening an already open PDF brings its existing window forward.
- Native continuous scrolling, page navigation, zoom, fit to width, text selection and printing.
- Search highlights all matches as you type. Previous and Next buttons sit beside the search field; **⌘G** / **⇧⌘G** navigate matches with wraparound. Search results update after refreshes and version changes, independently in each window.
- File and directory notifications detect in-place rewrites, atomic replacement and delete/recreate cycles.
- Debounced reloads retain the last valid PDF through partial writes and reject stale asynchronous results.
- Invalid text ranges reported by PDFKit are skipped before text extraction, preventing fatal range-conversion crashes while keeping the PDF available for reading.
- The bottom status shows the last successful PDF update in system-local time, including seconds (`YYYY-MM-DD HH:mm:ss`); unchanged content does not reset it.
- Text anchors preserve the reading passage and its viewport position across page insertion/deletion, with coordinate fallback for image-only pages.
- Persistent jump points with direct top-bar buttons, optional names, and keyboard shortcuts.
- In-memory PDF version history with Previous, Next and Latest navigation.
- Optional Follow Edits mode and source-to-PDF navigation through a simple CLI.

Anchoring is heuristic: extensive reflow, ambiguous text or formula-only content can fall back to the original page coordinates.

## Version history

Every successfully loaded content change is retained as an immutable PDF snapshot **in memory**, with its original update timestamp. After the first refresh, compact **‹ vN/Total ›** controls appear in the toolbar: the arrows move between versions, and clicking the version counter returns to Latest. The **Versions** menu lists every snapshot by number and timestamp.

- **⌥⌘[**: previous version; **⌥⌘]**: next version; **⌥⌘0**: latest version.
- While viewing an older version, new successful refreshes are collected without replacing what you are reading. Returning to Latest resumes live updates.
- Version changes preserve zoom, display mode and the reading position using the same heuristic text anchors. Viewing history never writes an old PDF back to disk.
- Histories are separate for each PDF path and survive closing/reopening documents within the running app. **Quitting the app clears history.** Snapshots are never evicted during the session, so memory use grows with the number and size of captured PDFs.
- Invalid/partial reads, stale asynchronous results and consecutive identical content are excluded. Rapid builds overwritten before the viewer captures them cannot be recovered. A disk revert to earlier content is retained as a new chronological version.

Explicit SyncTeX navigation returns to Latest, because the source and SyncTeX files describe the current build. [Changelog](CHANGELOG.md).

## Jump points

Press **⌘D** or click **Set Point** to save the current reading location instantly. Unnamed points use **A, B, … Z, AA, AB…**, skipping labels already in use. Press **⇧⌘D** or right-click **Set Point** to supply a custom name.

The toolbar uses **one row when everything fits**. When space is tight, history and saved points move to a **second row**, keeping labels and search readable. Saved points appear as small named buttons beside Set Point: click one to jump, or use **⌘1–⌘9** for the first nine points in display order. Right-click a point for **Jump to Point**, **Rename…** and **Remove Jump Point**; renaming and removal has no shortcut or extra toolbar button. The Jump Points menu also exposes these actions. Scroll the inline point area horizontally when it fills up; it remains horizontally scrollable even in the overflow row.

Renaming changes only the label: the saved location, button order and jump shortcut stay the same. Names may contain Unicode; an empty rename keeps the existing name.

Points are stored separately for each PDF path, survive app restarts, and update their text anchors after successful rebuilds without moving your reading position. Jumping preserves your current zoom and display mode. If the target text is gone or cannot be extracted, the app uses a safely clamped page-coordinate fallback and reports an approximate location. Moving or renaming the PDF does not migrate its saved points. Concurrent app instances editing points for the same PDF use the last saved list.

## Build and test

Development requires Xcode Command Line Tools, Node 26 headers/libraries, and a compatible Yuyan checkout. The validated [Yuyan toolchain](https://github.com/yuyan-lang/yuyan) commit is `57be1c544e1898540509c9f3c773dd57f9fc8ae6`. The matching standard-library sources are included in `第三方/标准库`.

```sh
YY_ROOT=/path/to/yuyan-wktree-1 ./构建.sh
./运行.sh /path/to/paper.pdf
./测试.sh
# Build a self-contained release ZIP:
YY_ROOT=/path/to/yuyan-wktree-1 ./发布.sh
```

Tests run in the background without activating the app. Set `YY_VIEWER_BACKGROUND=1` when running an individual test script. Tests run the actual Yuyan Wasm-GC application with PDFKit. The integration suite also requires `latexmk` and LaTeX. A logged-in macOS graphical session is required. To run the private-document crash regression as well, set `YY_CRASH_PDF=/path/to/test-copy.pdf`; the test creates another temporary copy and never rewrites the supplied file.

```sh
# Navigate an already-open PDF after compilation:
./运行.sh --navigate /path/to/paper.pdf /path/to/source.tex 120
```

[详细说明（现代汉语）](自述.汉语.md) · [文言说明](自述.文言.md) · [Icon generation prompt](资源/图标提示词.汉语.md)

License: GPL-3.0-or-later. Bundled third-party libraries retain their own licenses, included inside the app.
