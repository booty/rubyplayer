# Kitty Artwork Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans. ROCKLEE (Luna, high effort) implements; the parent reviews and requests revisions. User explicitly authorized automatic plan approval.

**Status:** complete, reviewed and verified 2026-10-13; pushed to `origin/main`.
**Implementation commit:** `076bc7e658e5b18907c40bd0f77ec733afa54d8a` (Tasks 1–3).
**Baseline:** `5aa234e` on `main`.
**Goal:** Use one Kitty graphics renderer for artwork in Kitty and compatible iTerm2 terminals.
**Architecture:** Normalize artwork to cached PNG on the existing artwork worker. A small stateful terminal renderer owns one uploaded cover and placement. App supplies visibility and geometry, preserving current modal, resize and layout behavior; Screen remains a text drawing primitive.
**Tech Stack:** Ruby 4, existing ffmpeg, Kitty APC graphics protocol; no new dependencies.
**Spec:** The approved in-chat design: Kitty-only output, automatic support detection, cached PNG, upload reuse, explicit placement lifecycle, tests and lint before commit/push. Older iTerm2 versions may lose artwork.

## Global Constraints

- Work on main, without worktrees. Leave unrelated `.serena/` and other concurrent edits alone.
- No changes to native audio, playback, selection, or unrelated review findings.
- No OSC 1337 fallback. Unknown/unsupported terminals display the existing placeholder.
- Detect known terminals conservatively from the injected environment: Kitty via TERM=xterm-kitty, TERM_PROGRAM=kitty or KITTY_WINDOW_ID; iTerm2 via TERM_PROGRAM=iTerm.app with TERM_PROGRAM_VERSION, or LC_TERMINAL=iTerm2 with LC_TERMINAL_VERSION. Require iTerm2 >=3.5.4 stable; malformed, missing and older iTerm versions are unsupported. Parse numeric version components, not lexicographic order. Multiplexers (TMUX/STY) are unsupported in this change and must not receive raw graphics commands. No active terminal queries or input-protocol changes needed.
- Use direct base64 transmission (t=d), PNG (f=100), chunks of at most 4096 encoded bytes, q=2 to suppress success/error responses. Every command must terminate with ESC-backslash; all intermediate chunks m=1, final m=0.
- Use a nonzero app-owned image ID and nonzero placement ID, scoped deletion only. Upload once per retained cover, reuse placements after damage/resize/modal dismissal. Retain only the current cover in terminal storage; free it on replacement, no art, and exit.
- Placement uses c/r bounds, C=1 to prevent cursor movement, and explicit cursor save/restore around addressing. Current Kitty specification letterboxes/pillarboxes when both c/r are set. Never delete other programs' images.
- PNG conversion stays off the UI thread and caches successes and failures by content and pixel limit. Do not upscale. JPEG/GIF must become a single PNG frame even when already under the pixel limit. On conversion failure return nil, never mislabeled JPEG or garbage.
- No transmission/re-encoding every frame; idle CPU goal remains intact. Units in byte/pixel/time identifiers.
- Full tests (which compile native prerequisites), RuboCop, and parent review before final commit and push. Parent owns final Git writes. One feature commit, then a small plan checkpoint recording its hash if needed.

## Review Focus

1. Artwork placement must hide under covering overlays. Now Playing Info owns its modal placement; its Live/Tracker pages hide placement while retaining the current track upload for return and close.
2. Repaint/resize clearing terminal placements must be repaired using retained image data, with existing resize debounce preserved.
3. Switching to a track without art or failed conversion must not leave the previous cover visible.
4. A small JPEG/GIF must be converted; malformed files and missing ffmpeg must degrade to placeholder.
5. Version parsing and multipart transfers must not trigger commands through the keyboard decoder or advertise unsupported older iTerm2.

## Task 1: Cached display PNG

**Files:** `lib/rubyplayer/artwork.rb`, `test/artwork_test.rb`.
**Interface:** Keep `Artwork#display_bytes(bytes, max_px:) -> PNG binary String or nil`; preserve original bytes for accent-color extraction elsewhere.

- [x] Add failing tests using real image fixtures for small JPEG/GIF, larger images, PNG, no upscaling, repeated conversion/cache hits, corrupt bytes and missing executable.
- [x] Run the focused tests and record the expected failures.
- [x] Replace JPEG-only downscaling with bounded PNG conversion; avoid multiple subprocesses where one ffmpeg conversion suffices. Use existing ffmpeg facilities and safe argv calls.
- [x] Run focused tests and record green evidence in the progress section.

## Task 2: Kitty renderer

**Files:** create `lib/rubyplayer/ui/kitty_image.rb`, `test/kitty_image_test.rb`; retire `iterm_image.rb` and its tests once App is migrated; update requires in `lib/rubyplayer.rb`.
**Interface:** `KittyImage.supported?(env = ENV)` boolean. Instance with injected output; `render(bytes, row:, col:, width:, height:, force: false)` displays/repositions and returns nil; `hide` removes only the placement, retaining upload; `clear` removes placement and frees upload. An unchanged render emits nothing; force repairs a damaged placement without upload. Validate nonpositive/out-of-screen geometry at the App boundary or renderer and hide stale placement.

- [x] Add failing detection tests for Kitty, current/old/unknown iTerm2, SSH LC variables and multiplexers.
- [x] Add failing protocol tests for payload reconstruction at chunk boundaries, q=2, cursor preservation, single upload across placements, replacement freeing old data, idempotent hide/clear, and no-op unchanged frames.
- [x] Implement the small renderer with named byte limits and scoped IDs; keep base64 out of each-frame paths. Use fresh image IDs on replacement if necessary for iTerm2 compatibility.
- [x] Run focused tests and record evidence.

## Task 3: App integration and review

**Files:** `lib/rubyplayer/ui/app.rb`, focused `test/app_artwork_test.rb` or existing artwork tests in `test/app_rendering_theme_config_test.rb`, `test/support/app_test_support.rb` if required, `README.md`, `docs/memories.md`.
**Interface:** App uses the renderer from Task 2; existing art-mode configuration remains unchanged.

- [x] Add failing integration tests for both detected terminals and unsupported terminals. Cover all art modes; modal open/close including Now Playing and playlist prompts; resize/move/shrink; no-art/failed-art replacement; repaint reuse; cleanup before leaving alternate screen; no-art placeholder.
- [x] Integrate renderer lifecycle with render/emit_art and terminal teardown. Hide whenever artwork is not eligible, before any early return that could strand a placement. No repeated deletion or upload when stable. Preserve existing asynchronous generation checks against stale artwork worker results.
- [x] Remove iTerm-specific implementation/references and update README's terminal requirements and file map. Add concise tested lessons to memories without duplicating prior entries.
- [x] Run focused integration tests, then `mise exec -- bundle exec rake test` and `RUBOCOP_CACHE_ROOT=/private/tmp/rubyplayer-rubocop-cache mise exec -- bundle exec rubocop`. Record exact results.
- [x] ROCKLEE provides implementation report and diff summary to parent, without committing/pushing; parent reviews code and protocol behavior and sends revisions to ROCKLEE.
- [x] Resolve revisions, rerun affected tests and final gates, then parent commits and pushes to the verified current branch remote. Update this plan with final commit hash and verification evidence.

## References

- https://iterm2.com/documentation-images.html (explicit Kitty support)
- https://iterm2.com/downloads.html (3.5.4 beta introduction; stable floor chosen conservatively)
- https://sw.kovidgoyal.net/kitty/graphics-protocol/
- https://raw.githubusercontent.com/kovidgoyal/kitty/master/docs/graphics-protocol.rst
- Current spec: both c/r letterbox/pillarbox; C=1 prevents cursor movement; q=2 suppresses responses; a=d,d=i hides placement; a=d,d=I frees image data.

## Progress / handoff

- Plan self-reviewed and automatically approved under the user's explicit instruction.
- ROCKLEE owns implementation and task checkbox/evidence updates. Parent owns review decisions and final Git writes.
- Parent final review approved: corrected continuation headers and image/placement-scoped deletion, retained same-track uploads through Live/Info transitions, guarded nil artwork regions during resize, and strengthened resize/cache/fixture tests. No open revision requests.
- Parent final gates on reviewed code: `mise exec -- bundle exec rake test` — **1045 runs, 28026 assertions, 0 failures, 0 errors, 0 skips**; RuboCop — **213 files inspected, no offenses**; `git diff --check` clean. Logs: `/private/tmp/rubyplayer-kitty-reviewed-tests.log` and `/private/tmp/rubyplayer-kitty-reviewed-lint.log`. Native prerequisites are included in the rake test task.
- Scope decisions under automatic approval: environment-based detection, iTerm2 stable >=3.5.4, no multiplexer passthrough, preserve Now Playing Info artwork. Actual graphical terminal appearance was not manually exercised; verification uses protocol and App rendering tests per repository guidance.
- Task 1 RED: initial focused artwork run had 19 runs, 27 assertions, 6 failures, covering old JPEG passthrough and garbage/missing-FFmpeg behavior.
- Task 1 GREEN: `mise exec -- bundle exec ruby -Itest test/artwork_test.rb` — 19 runs, 36 assertions, 0 failures. Small JPEG dimensions remain unchanged; GIF and JPEG output is PNG; corrupt input and unavailable FFmpeg return nil; cache failures are keyed by content and pixel limit.
- Task 2 GREEN: `mise exec -- bundle exec ruby -Itest test/kitty_image_test.rb` — 8 runs, 41 assertions, 0 failures. Covers current/old/malformed version detection, multiplexers, direct PNG chunk reconstruction, continuation headers, placement scoping, cursor save/restore, reuse, replacement and idempotent cleanup. Latest output: `/private/tmp/rubyplayer-rocklee-kitty-image.log`.
- Task 3 focused GREEN: `mise exec -- bundle exec ruby -Itest test/app_artwork_test.rb` — 8 runs, 50 assertions, 0 failures; `mise exec -- bundle exec ruby -Itest test/app_rendering_theme_config_test.rb` — 62 runs, 204 assertions, 0 failures. Includes Kitty app detection, all placements, Info/Live/close reuse, overlay hide/restore, resize shrink/grow, no-art cleanup and terminal teardown. App test output: `/private/tmp/rubyplayer-rocklee-app-artwork.log`.
- Parent review revisions: extracted `handle_track_started`, renamed the iTerm version predicate, and simplified integer checks to satisfy RuboCop. Corrected the artwork cache test to assert success object reuse before stubbing the converter, then prove failure conversion runs once per distinct pixel limit.
- Final focused tests after revisions: `test/artwork_test.rb` — 19 runs, 36 assertions; `test/kitty_image_test.rb` — 8 runs, 41 assertions; `test/app_artwork_test.rb` — 8 runs, 50 assertions; `test/app_rendering_theme_config_test.rb` — 62 runs, 204 assertions; all passed. Logs: `/private/tmp/rubyplayer-rocklee-artwork-final.log`, `/private/tmp/rubyplayer-rocklee-kitty-final.log`, `/private/tmp/rubyplayer-rocklee-app-artwork-final.log`, `/private/tmp/rubyplayer-rocklee-app-rendering-final.log`.
- Final lint: `RUBOCOP_CACHE_ROOT=/private/tmp/rubyplayer-rubocop-cache mise exec -- bundle exec rubocop` — 213 files inspected, no offenses. Parent's subsequent full-suite results are recorded above.
- Commit `076bc7e658e5b18907c40bd0f77ec733afa54d8a` pushed successfully to `origin/main`; no outstanding implementation or review work. This documentation checkpoint records the resulting hash after the feature commit.
