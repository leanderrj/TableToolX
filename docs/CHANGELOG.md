# Changelog

## Unreleased

- Continued the original Table Tool version sequence after v1.2.1, with Table Tool X starting
  at v1.3.0 and preserving the complete upstream tag history.
- Consolidated compatibility and performance checks into XCTest and removed one-off repository
  scripts so all maintained automation lives in declarative GitHub Actions workflows.
- Modeled Homebrew packaging after the original Table Tool cask by installing the signed GitHub
  release ZIP directly; removed the mixed-purpose Distribution directory.
- Added native file drops onto document windows, explicit text/number/date sort controls,
  double-click header sorting with visible direction indicators, and fast column-divider
  auto-fit using the bounded row cache.
- Dropping a file onto an untouched Untitled window now replaces that placeholder after the
  file opens successfully instead of leaving an extra empty document behind.
- The grid now ends visibly at its final column instead of extending row separators through
  unused window space.
- Closing an edited document now uses one POSIX atomic rename transaction, avoiding both a
  nested staging layer and `FileManager.replaceItemAt` consuming its temporary file while
  still reporting a close-time save error.
- Restored the original Table Tool icon geometry in a new Leme brand colorway, with an
  ink-to-spectrum grid treatment and a reproducible 1024 px PNG master.
- Clean Swift 6 application and core architecture.
- Streaming CSV parser/writer with strict and explicit best-effort modes.
- Length-aware SQLite text bindings preserve embedded NULs in column headers, projections,
  filters, regular expressions, and subsequent exports.
- Dialect, BOM, encoding, line-ending, and header detection.
- SQLite-backed virtualized document workspace and typed projections.
- Native document window, editable AppKit grid, find/replace, filters, sorts, export, and recovery.
- Replace All is restricted to the current filtered view and records disk-backed inverse rows
  for bounded, lossless Undo/Redo instead of becoming an irreversible bulk edit.
- Progressive large-file previews and a responsive compact toolbar for narrow windows.
- Double- and single-quote detection, including samples truncated inside a quoted field.
- Persistent, undoable column reordering.
- Bounded visible-page caching and cancellation of stale scroll requests for large files.
- Bounded keyset page cursors so adjacent pages after a distant jump avoid repeatedly scanning
  every preceding row, with automatic invalidation after document mutations.
- Linear-time streaming export from SQLite, including filtered and sorted visible rows.
- Hardened Runtime and sandbox configuration for Sparkle 2.9.4.
- Scheduled Sparkle checks start with the application instead of waiting for the first
  manually requested update, with weekly monitoring of the pinned Swift dependency.
- Fail-closed Developer ID signing, notarization, Sparkle appcast, checksum, provenance,
  GitHub Release, and Homebrew cask automation.
- Cryptographic release preflight verifies the private Sparkle Ed25519 seed matches the public
  key embedded in the app; a warning-only mismatched appcast can no longer be published.
- Release runners verify the Developer ID team, restrict secret-derived file permissions, and
  always destroy their temporary signing certificate and keychain.
- Correct final-newline detection beyond the bounded format-detection sample.
- Persistent composed filter/sort views that refresh safely after row and cell mutations.
- Numeric and ISO-8601 date filter operands are bound using their projected SQLite types,
  including comma-decimal documents and date-only values.
- Numeric projections skip ISO-8601 parsing for values that cannot be dates, eliminating the
  dominant first-filter cost; scheduled large-file budgets now cover projection and cached sort.
- Cell edits update an existing typed projection in place and rebuild a filtered view only when
  the edited column participates in that view, keeping unrelated million-row edits interactive.
- Atomic filter/sort replacement, view-aware find navigation, and restoration of the active
  view definition after reopening a recovery workspace.
- Row insertion above or below the selection with order-preserving undo/redo primitives.
- Column insertion left or right, adjacent duplication, and lossless delete/restore snapshots.
- SQLite-backed column duplication and undo snapshots keep structural edits bounded for
  million-row documents and roll back safely when cancellation is observed.
- Multi-row deletion now stores its lossless Undo payload in the workspace database instead
  of retaining every deleted field as a second Swift object graph; filtered selections are
  restored at their exact document positions and rejoin their active sort correctly.
- Cache-independent multi-row copy/delete, quoted TSV clipboard data, and insert-style paste
  that atomically grows columns and supports undo/redo.
- Large row and column copies stream the selected ranges through a temporary TSV instead of
  materializing every selected row and field before handing the final text to the pasteboard.
- Original row-first responder semantics for Copy and Delete prevent a lingering column
  selection from narrowing a row copy or deleting columns when rows are selected.
- Original Paste semantics insert complete rows after the last selected row, append when no
  row is selected, grow columns as needed, and detect the pasted delimiter and quote style.
- Row insertion and paste maintain cached projections incrementally; growing columns for a paste
  no longer rewrites every existing row merely to store trailing empty fields.
- Native in-place autosaving and document versions, debounced recovery manifests, and cleanup
  of stale or abandoned workspaces.
- Sandboxed crash recovery persists a security-scoped source bookmark and releases access when
  the restored document closes, allowing legitimate save-back after an application relaunch.
- Native multi-row drag reordering with exact order restoration through undo/redo.
- Row drags also advertise quoted tabular and plain text for copying data into Numbers,
  spreadsheets, and text editors outside Table Tool X.
- Non-fatal editing errors now leave an open document interactive.
- Atomic multi-column deletion with lossless undo snapshots, plus grid context menus,
  selection-aware Delete behavior, and explicit cell accessibility labels.
- Independent visible-row export controls for encoding, delimiter, quote character, quote
  policy, escaping, header, BOM, final newline, and line endings.
- A full-document Convert / Export command complements visible-row export, and both normalize
  ragged input to the displayed column count exactly like the original editor.
- Native CSV, TSV, and plain-text save/export types, including `.tsv` filename suggestions
  when the active document delimiter is a tab.
- Optional classic all-fields quoting in addition to minimal RFC-style quoting.
- Scheduled 100 MiB/1M+ row import, export, cold-tail paging, and resident-memory budgets.
- Cancellation-aware streaming imports, atomic streaming exports that preserve the existing
  destination on failure, and document-close cancellation of import/page work.
- Document-close cancellation now covers every asynchronous edit, search, view, and structural
  operation; the view model detaches before recovery cleanup so late tasks cannot resurrect a
  discarded workspace.
- SQLite's progress handler cooperatively interrupts long native sorts, projections, and schema
  rewrites, translating the interruption back to Swift cancellation so transactions roll back.
- Long edits, searches, filters, sorts, pastes, and structural rewrites run one at a time with
  an in-window progress strip and Cancel action; conflicting grid and menu commands are disabled.
- Visible-row exports use a tracked, cancellable temporary file and atomically replace the chosen
  destination only after the complete filtered export succeeds.
- Public-repository issue forms, generated release notes, dependency automation, pinned
  GitHub Actions, and a macOS 14/Xcode 16.2 compatibility CI lane.
- Native Swift CodeQL security analysis runs for mainline changes, pull requests, and weekly
  scheduled scans using the real generated Xcode project and SHA-pinned GitHub actions.
- Swift security extraction traces one native architecture, matching CodeQL guidance and avoiding
  duplicate cross-architecture compiler work during every scheduled scan.
- Targeted AppKit page and cell invalidation so toolbar/status changes no longer reload the
  entire million-row grid during momentum scrolling.
- Post-import WAL truncation so large open documents do not retain a second workspace-sized
  write-ahead log after indexing has committed.
- Manual notarized release-candidate runs that exercise every production release stage
  without publishing, while tag-triggered runs remain the only path to a public release.
- Release metadata validation for the Sparkle key/feed/services, sandbox network and Mach
  entitlements, and manual Developer ID export settings; workflow definitions are linted in CI.
- Removed the placeholder Homebrew cask so installation metadata is published only after a
  real signed ZIP exists and its SHA-256 has been calculated.
- Transactional format editing: dismissing the format popover no longer mutates the displayed
  or saved dialect, and byte-order marks are cleared automatically for legacy encodings.
- Applying a corrected delimiter, quote, or encoding to a clean opened document now reparses
  the source; edited documents keep the non-destructive output-format-only behavior.
- Locale-aware GB18030 detection matching the original Table Tool's Chinese-language behavior,
  preventing valid Chinese CSV bytes from being misclassified as Windows-1252.
- Full upstream heuristic parity across 20 fixtures, including ambiguous delimiters, default
  quoting, backslash escaping, decimal marks, header inference, and legacy encodings.
- Strict reader parity across 13 original valid and malformed fixtures, including blank rows,
  both escape modes, invalid bytes, incomplete escapes, and unterminated quoted fields.
- Malformed-file errors expose an explicit best-effort recovery action; recovered documents
  remain visibly warned and dirty so normalized data cannot overwrite the source silently.
- Best-effort mode counts every parsing warning while retaining only a bounded diagnostic
  sample, preventing heavily malformed files from creating an unbounded warning array.
- Explicit safe Cancel/Retry controls for long imports, with editing, find, filter, and sort
  actions disabled until indexing reaches an interactive state.
- Transaction-level regression coverage proving a cancelled import cannot expose partially
  indexed rows.
- Normal document closure now removes crash-recovery state after AppKit's Save/Don't Save
  review, so explicitly discarded edits cannot reappear on the next launch.
- Format detection moved off AppKit's synchronous document-open callback so the native window
  appears immediately while bounded dialect analysis runs away from the main thread.
- Homebrew metadata declares Sparkle auto-updates and cleanly quits the application before
  uninstalling it.
- Generated Homebrew metadata is staged in an ephemeral tap for real `brew style` and offline
  audit checks before publication, then receives an online audit after the release is public.
- The release job explicitly dispatches the post-publication cask workflow because GitHub
  suppresses ordinary release events created with `GITHUB_TOKEN`; dispatch and PR creation are
  idempotent for safe reruns.
- Release archives verify the embedded semantic version, stable Sparkle feed, universal
  architectures, and final signed sandbox/network entitlements before notarization.
- Final archive validation also requires Xcode-expanded Sparkle installer/status Mach service
  names, rejecting signatures that accidentally retain build-setting placeholders.
- Public release automation rejects lightweight tags and tags outside `main`, enforcing the
  annotated-mainline provenance required by the release procedure before credentials are used.
- Repository-level immutable releases lock published assets and tags and produce GitHub release
  attestations; automation verifies draft digests before publication and those attestations after.
- GitHub and embedded Sparkle release notes come from the matching changelog section instead of
  comparing against the original repository's inherited tags.
- Every macOS 15 CI run now cross-compiles and inspects the universal arm64/x86_64 Release
  executable before credentialed release work begins.
- Every macOS 15 CI run also ZIPs and images the app, signs an ephemeral Sparkle appcast,
  validates the archives, and renders the pinned Homebrew cask before release credentials
  are involved.
- Native Open Recent, Revert, Find Next/Previous, conversion, and selection-aware command
  validation restore the original document-menu behavior without exposing invalid actions.
