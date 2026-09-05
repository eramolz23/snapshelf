# SnapShelf Reliability Implementation Plan

> Execute the approved review fixes in the isolated `fix/reliability-2026-09-05` worktree. Preserve existing capture shortcuts and tools. Use focused regression checks and independent review before installation.

**Goal:** Make edited captures, OCR, saving, and shelf lifecycle reliable without losing existing behavior.

**Architecture:** Retain the native AppKit application and existing single-file structure. Make save success explicit, coordinate editing/indexing/clipboard ownership by capture URL, and centralize shelf layout. No new dependencies.

**Baseline:** `4ffbbdc`. Installed app remains unchanged while building and testing.

1. Add `tests/regression.swift` and a narrow `test.sh` harness compiling real application types without executing the normal app entrypoint. Use synthetic PNGs, isolated storage/defaults, and a named pasteboard. Demonstrate failing checks for stale OCR merge, failed saves, stacking, and capture names before implementation.
2. In `main.swift`, make `EditorController.saveAndClose()` close only after render and persistence succeed. Use atomic writes and propagate errors through both save callbacks. Update edited-image clipboard representations only if that capture still owns the pasteboard.
3. Replace `HistoryWindow.buildIndex()` stale-snapshot merging with generation-aware per-file indexing. Invalidate pending results after edits/deletes, prevent old persisted indexes from keeping previously redacted text, and test edit/index completion in both orders.
4. Repair `ShelfItem`/`AppDelegate` lifecycle: dismiss safely while an editor is active, persist login choice, allocate unique filenames, check capture termination status, bound thumbnail height and shelf placement, and reflow after closure/resizing.
5. Add small editing safeguards (solid redaction and one editor per file) only with regression coverage. Broader optional features remain subject to the user's scope answer.
6. Run `./test.sh`, `swiftc -typecheck -swift-version 5 main.swift`, and `./release.sh` in this worktree. Never use `build.sh` on the installed app before validation; it resets Screen Recording permission.
7. Independently review the complete diff for regressions, especially atomic-save file watchers, cancellation, OCR invalidation, clipboard ownership, undo/crop, and retention. Exercise a staged native UI with synthetic fixtures: golden path, narrow/tall capture, failure/cancel, and adjacent tools.
8. Verify `.gitignore` and scan staged paths for secrets; stage only changed sources/tests/docs and commit. Integrate only the reviewed branch. Keep a rollback copy before replacing an installed bundle; verify launch and permissions, and report any physical verification still requiring Luke.

## Implementation evidence

- [x] Added a real-type Swift regression harness with generated Retina PNGs, temporary directories, an isolated defaults suite and a named pasteboard. Baseline render-failure and tall-thumbnail checks failed before their fixes. Later Retina-rendering and blur-over-redaction checks also failed before their corrections.
- [x] Completed the seven approved reliability fixes, solid redaction and shared editor ownership. Preserved existing tool/undo behavior with pixel-level checks. Corrected Retina context scaling and prevented Blur from sampling beneath existing redactions.
- [x] Bounded OCR decoding to two workers, coalesced progress notifications, and reused history cells by URL/revision. Covered atomic refresh, changed search results, cache reuse and both edit/index completion orders.
- [x] `./test.sh`: 83 assertions passed; `swiftc -typecheck -swift-version 5 main.swift`: exit 0; `./release.sh`: exit 0, `dist/SnapShelf-1.0.1.zip`. `git diff --check` passed before handoff.
- [x] Prepared and launched `dist/SnapShelfReview.app` through `open` for root's visual review. Build command: `./test.sh --review`. The app uses real UI types, a separate bundle identity, temporary fixtures and a named pasteboard, with no capture/hotkey/login registration.
- [ ] Root: finish independent review and staged native UI verification, then commit/integrate/install with rollback and permission checks.
# Final verification — 2026-09-05

- Independent review approved all original fixes plus the rendering, History performance, and failed-cache-purge regressions.
- Fresh `./test.sh`: 94 assertions passed. Swift 5 typecheck passed. `./release.sh` built `dist/SnapShelf-1.0.2.zip`.
- Native CUA synthetic checks: redaction + overlapping blur saved and reopened; narrow-image arrow/undo/crop saved; missing destination displayed an error and retained edits. Dismiss All retained the editor; post-save CUA lost its target after the last window closed, with the equivalent save path covered by regression assertions.
- Installed application has not been replaced during testing. Its designated requirement is tied to the previous binary hash; activation must preserve rollback and account for Screen Recording consent.
