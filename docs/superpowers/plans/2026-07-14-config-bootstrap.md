# User Config Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install packaged Ruby config on first run and restore last-known-good source when primary config disappears.

**Architecture:** `ConfigStore` bootstraps primary source before normal transactional loading. A packaged, mostly commented example remains independent from loader code and gets copied with exclusive atomic creation.

**Tech Stack:** Ruby 4, Minitest, filesystem atomic link/rename operations.

## Global Constraints

- Never rename `lib/rubyplayer/config.rb`.
- Never overwrite existing user `config.rb`.
- Prefer `config-previous.rb` over packaged sample when primary is missing.
- Keep repository `.gitignore` unchanged because user files live under `~/.config`.
- Packaged example must not actively pin every built-in default.

---

### Task 1: Bootstrap Behavior

**Files:**
- Modify: `lib/rubyplayer/config.rb`
- Modify: `test/config_test.rb`

**Interfaces:**
- Produces: `RubyPlayer.config_sample_path -> String`.
- Extends: `ConfigStore.new(path:, sample_path:, create_if_missing:)`.
- Produces: `ConfigStore#bootstrap_primary!` private behavior before startup/reload.

- [ ] Write failing tests for exact sample install, previous restore, primary
      preservation, reload-time restore, and missing sample error.
- [ ] Run `mise exec -- bundle exec ruby -Itest test/config_test.rb`; verify
      failures come from absent bootstrap behavior.
- [ ] Add configurable sample path and atomic exclusive creation.
- [ ] Bootstrap before startup signature and whenever reload sees missing file.
- [ ] Preserve `create_if_missing: false` for pure-default test stores.
- [ ] Re-run config tests; expect zero failures/errors.
- [ ] Commit with `Add automatic user config bootstrap`.

### Task 2: Packaged Example and Documentation

**Files:**
- Create: `examples/config.rb`
- Modify: `README.md`
- Modify: `test/config_test.rb`
- Modify: tests constructing deliberately nonexistent config paths.

**Interfaces:**
- Supplies valid source from `RubyPlayer.config_sample_path`.

- [ ] Add valid, mostly commented example with common settings, maps, and two
      formatter examples.
- [ ] Assert packaged example evaluates and leaves representative defaults.
- [ ] Update pure-default test stores to pass `create_if_missing: false`.
- [ ] Document install/recovery/reset behavior and sample location.
- [ ] Search stale claims with
      `rg -n "creates no config|Missing file is fine" README.md`.
- [ ] Run `mise exec -- bundle exec rake test` and `git diff --check`.
- [ ] Commit with `Ship example Ruby configuration`.

### Task 3: Final Review

**Files:**
- Review all Task 1-2 changes.

- [ ] Confirm destination can never overwrite existing user source.
- [ ] Confirm previous source wins over sample.
- [ ] Confirm sample does not pin all defaults.
- [ ] Run fresh `mise exec -- bundle exec rake test`.
- [ ] Verify clean `git status --short`.
