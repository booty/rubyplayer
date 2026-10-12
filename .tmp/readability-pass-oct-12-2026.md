# Readability review — October 12, 2026

Status: **in progress**. Findings are appended as they are confirmed; this file is ready for another agent to work from now.

Scope: 68 commits dated October 5–12, through `79204f1`. Review current code, rather than refactoring intermediate versions that have already been superseded. Recommendations are behavior-preserving unless explicitly stated. No production code is changed by this review.

## 1. Share the lifecycle of the GBS and NSF history trackers

Priority: worthwhile. Files: `lib/rubyplayer/gbs/tracker.rb` and `lib/rubyplayer/nsf/tracker.rb`, particularly `update`, `reset`, `to_sample`, and their note-transition logic.

Both trackers perform the same generation reset, sample-rate setup, output-frame conversion, ordered snapshot ingestion, conditional model rebuild, and changed/not-changed return. Their note histories also use the same rules: newly playing or retriggered → start; still playing → pitch change; previously playing → stop. Maintaining this independently makes future seek/history fixes easy to apply to only one format.

Extract the small shared lifecycle first, with explicit hooks for resetting format state, ingesting a native snapshot, and building the view snapshot. A small base class is reasonable here because these are two implementations of the same protocol; do not absorb register decoding into it. Keep NSF's per-chip histories, global voice numbering, and VRC7 reconstruction format-specific. If transition extraction needs many callbacks, leave that part local.

Name the input `live_state`, the per-record value `native_snapshot`, and the output `view_snapshot` (or document that distinction at the public methods). Currently `state`, `live`, `snapshot`, and `@latest` require the reader to infer which of three representations is involved.

Validation: existing GBS/NSF tracker tests, especially generation changes, retriggers, and pitch changes. Preserve the NSF register-cache reset and the force-write after a synthesized VRC7 key-off.

## 2. Rename the shared VGM page and its generic modal interface

Priority: worthwhile. Files: `lib/rubyplayer/ui/vgm_live_view.rb`, `lib/rubyplayer/ui/now_playing_modal.rb`, and `lib/rubyplayer/ui/app.rb`.

`VgmLiveView` now renders VGM, GBS, NSF, and NSFe chip state. `NowPlayingModal` receives GBS/NSF views through `vgm_view:` and updates them through `update_vgm`. These names describe the first implementation rather than the present responsibility, making format dispatch unnecessarily confusing.

Rename the shared widget to `ChipLiveView` (or `ChannelLiveView`), its modal argument/instance variable to `chip_view`, and the generic update method to `update_chip`. Keep genuinely VGM-specific telemetry names (`VgmTelemetryController`, VGM replay) unchanged. Separately consider moving the format-neutral snapshot/patch/pitch types out of `Vgm` once imports can be changed mechanically; that is a larger optional follow-up, not a prerequisite for the widget rename.

Validation: all live-view and Now Playing tests, including VGM telemetry visibility and SPC's distinct DSP view. Avoid a compatibility alias unless something outside this repository needs the old name.

## Review coverage / remaining work

- Examined: GBS/NSF tracker lifecycle and the shared live-page naming.
- Still reviewing: panel/layout duplication, backend/native helpers, native identifier names, engine/app orchestration, earlier week's queue/scanner/metadata changes, and test helpers.
