# Executable Ruby Configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace TOML and brace templates with validated executable Ruby configuration, styled track formatters, last-known-good recovery, and nonfatal hot-reload errors.

**Architecture:** `ConfigStore` delegates source evaluation to a fresh DSL builder and activates results transactionally. `TrackFormatter` normalizes lambda output into styled fragments consumed by `TracksPane`; `Screen` remains terminal-only and gains two text attributes. `App` converts reload failures into a modal while startup fallback remains inside `ConfigStore`.

**Tech Stack:** Ruby 4, Minitest, ANSI terminal rendering, existing immediate-mode UI.

## Global Constraints

- `~/.config/rubyplayer/config.rb` is the only user configuration source.
- Missing primary config uses built-in defaults.
- Primary startup failure falls back to sibling `config-previous.rb`; both failing is fatal.
- Running app retains current config after reload failure and shows a modal.
- Successful primary loads atomically refresh exact-source `config-previous.rb`.
- Existing reads through `ConfigStore#[]` remain supported.
- Selection colors override formatter foreground/background.
- README documents every setting, executable-code risk, helpers, colors, and presets.
- No TOML or brace-template compatibility layer.

---

## File Structure

- Create `lib/rubyplayer/config_dsl.rb`: settings proxy, evaluator facade, validation, and actionable configuration errors.
- Modify `lib/rubyplayer/config.rb`: defaults, source paths, transactional activation, backup/fallback, reload signatures, and managed theme block.
- Create `lib/rubyplayer/track_formatter.rb`: fragment type, formatter helper context, result normalization, and style/color validation.
- Modify `lib/rubyplayer/ui/tracks_pane.rb`: invoke formatter lambdas and render normalized fragment styles.
- Modify `lib/rubyplayer/ui/screen.rb`: represent and emit underline/dim attributes.
- Modify `lib/rubyplayer/ui/app.rb`: config-error modal, input capture, fallback notice, and reload recovery.
- Modify `lib/rubyplayer.rb`: require new components and remove legacy template require.
- Delete `lib/rubyplayer/template.rb` and `test/template_test.rb`: legacy string-template implementation and tests.
- Modify `test/config_test.rb`, `test/tracks_pane_test.rb`, `test/screen_test.rb`, and `test/app_test.rb`: executable config, formatting, rendering, and modal coverage.
- Modify `README.md`, `Gemfile`, and `Gemfile.lock`: complete user guide and remove `tomlrb`.

---

### Task 1: Transactional Ruby Config Loader

**Files:**
- Create: `lib/rubyplayer/config_dsl.rb`
- Modify: `lib/rubyplayer/config.rb`
- Modify: `lib/rubyplayer.rb`
- Test: `test/config_test.rb`

**Interfaces:**
- Produces: `RubyPlayer::ConfigError < StandardError` with `path`, original exception, and source location.
- Produces: `RubyPlayer::ConfigDSL.evaluate(source, path:, defaults:) -> Hash`.
- Produces: `ConfigStore#reload_if_changed -> true | false`, raising `ConfigError` without changing `data` on failed reload.
- Produces: `ConfigStore#startup_error -> ConfigError | nil` when fallback was needed.
- Produces: `ConfigStore#previous_path -> String`.

- [ ] **Step 1: Replace TOML tests with executable DSL tests**

Cover missing-file defaults, scalar overrides, all top-level sections, mutable
maps, multiple `RubyPlayer.configure` blocks, ordinary Ruby conditionals,
unknown setting suggestions, invalid value errors, and runtime exceptions:

```ruby
def test_ruby_file_overrides_defaults_and_supports_ruby
  write_config <<~RUBY
    rate = 48_000
    RubyPlayer.configure do |config|
      config.audio.sample_rate = rate
      config.scanner.thread_count = RUBY_VERSION.start_with?("4") ? 4 : 2
      config.backends[".foo"] = :ffmpeg
      config.keymap.global["ctrl+p"] = :play_pause
    end
  RUBY

  config = RubyPlayer::ConfigStore.new(path: @path)

  assert_equal 48_000, config["audio", "sample_rate"]
  assert_equal 4, config["scanner", "thread_count"]
  assert_equal :ffmpeg, config["backends", ".foo"]
  assert_equal :play_pause, config["keymap", "global", "ctrl+p"]
end

def test_unknown_setting_reports_path_and_suggestion
  write_config 'RubyPlayer.configure { |config| config.ui.frame_fpz = 60 }'

  error = assert_raises(RubyPlayer::ConfigError) do
    RubyPlayer::ConfigStore.new(path: @path)
  end

  assert_includes error.message, "ui.frame_fpz"
  assert_includes error.message, "frame_fps"
end
```

- [ ] **Step 2: Run loader tests and verify RED**

Run: `mise exec -- bundle exec ruby -Itest test/config_test.rb`

Expected: failures because `.rb` evaluation, DSL accessors, validation, and
`ConfigError` do not exist.

- [ ] **Step 3: Implement DSL builder and evaluator**

Implement a schema-aware proxy over a deep copy of `DEFAULTS`. Root and section
readers return nested proxies; known setters update copied data; map sections
support `[]` and `[]=`. Use `DidYouMean::SpellChecker` for unknown accessor
suggestions. Evaluate source through an anonymous module containing a facade
module whose only DSL entry point is:

```ruby
facade.define_singleton_method(:configure) do |&block|
  raise ConfigError, "RubyPlayer.configure requires a block" unless block
  block.call(builder)
end
```

Wrap `SyntaxError`, `ScriptError`, and `StandardError` with source path and
backtrace location. Validate all scalar defaults by expected class/range,
`sample_rate` as `"auto"` or positive integer, `theme` as a known id,
formatter values as callable, maps as hashes/proxies, and style-independent
glyph values as strings.

- [ ] **Step 4: Implement startup activation and fallback**

Change default format keys to callable lambdas under
`format_track_grouped`/`format_track_ungrouped`, add empty `backends` defaults,
change `RubyPlayer.config_path` to `config.rb`, and derive `previous_path` as
`config-previous.rb`.

On valid primary load, atomically snapshot exact source:

```ruby
temporary = "#{previous_path}.tmp-#{Process.pid}"
File.binwrite(temporary, source)
File.rename(temporary, previous_path)
```

On invalid primary startup, evaluate previous source. Store primary error in
`startup_error` when fallback succeeds. Raise one `ConfigError` containing both
failures when fallback is absent or invalid. Missing primary remains defaults.

- [ ] **Step 5: Implement transactional reload signatures**

Use a signature containing existence, nanosecond mtime, and size. Record the
new observed signature before evaluation so one invalid save produces one
modal event. Activate and snapshot only after successful evaluation. Leave
`@data` untouched on failure and re-raise `ConfigError`.

- [ ] **Step 6: Run focused tests and verify GREEN**

Run: `mise exec -- bundle exec ruby -Itest test/config_test.rb`

Expected: all config tests pass.

- [ ] **Step 7: Commit loader**

```bash
git add lib/rubyplayer/config.rb lib/rubyplayer/config_dsl.rb lib/rubyplayer.rb test/config_test.rb
git commit -m "Replace TOML with Ruby config DSL"
```

---

### Task 2: Styled Track Formatter and Screen Attributes

**Files:**
- Create: `lib/rubyplayer/track_formatter.rb`
- Delete: `lib/rubyplayer/template.rb`
- Delete: `test/template_test.rb`
- Modify: `lib/rubyplayer.rb`
- Modify: `lib/rubyplayer/ui/tracks_pane.rb`
- Modify: `lib/rubyplayer/ui/screen.rb`
- Test: `test/tracks_pane_test.rb`
- Test: `test/screen_test.rb`

**Interfaces:**
- Produces: `RubyPlayer::TrackFormatter.render(callable, track, album_artist:, star_glyph:) -> Array<Hash>`.
- Produces formatter context methods `text`, `number`, `duration`, `stars`, `line`, and `album_artist`.
- Produces normalized segments with `text`, `fg`, `bg`, `bold`, `italic`, `underline`, and `dim` keys.
- Extends `Screen#put` with `underline:` and `dim:` keyword arguments.

- [ ] **Step 1: Write formatter behavior tests**

Add tests that configure lambdas and assert conditional omission, helper output,
style retention, literal strings, nested arrays, malformed return rejection,
named/hex/theme colors, and selected-row precedence:

```ruby
formatter = lambda do |track, fmt|
  fmt.line(
    fmt.number(track.track_number, fg: :yellow),
    fmt.text(track.title, bold: true, underline: true),
    (fmt.text(track.artist, italic: true) unless track.artist == fmt.album_artist),
    fmt.duration(track.duration_ms, fg: :text_muted),
    fmt.stars(track.rating, fg: "#ffaa00", dim: true)
  )
end

segments = RubyPlayer::TrackFormatter.render(
  formatter, track, album_artist: track.artist, star_glyph: "★"
)

assert_equal "01 Title 1:00 ★★★", segments.map { |segment| segment[:text] }.join
assert segments.find { |segment| segment[:text] == "Title" }[:underline]
refute_includes segments.map { |segment| segment[:text] }, track.artist
```

Update the pane hot-reload test to assign a lambda in `config.rb`, then assert
the displayed row and cell style. Add a test proving selected cells use
`selection_text`/`selection_bg` while preserving formatter attributes.

- [ ] **Step 2: Write Screen underline/dim tests**

```ruby
screen.put(0, 0, "x", underline: true, dim: true)
output = screen.flush
assert_includes output, "\e[0;2;4m"
```

Also assert front/back diff equality includes both attributes.

- [ ] **Step 3: Run formatter and screen tests and verify RED**

Run: `mise exec -- bundle exec ruby -Itest test/tracks_pane_test.rb test/screen_test.rb`

Expected: failures because `TrackFormatter`, fragment styles, and new screen
keywords do not exist.

- [ ] **Step 4: Implement formatter normalization**

Create an immutable fragment representation and helper context. `text(nil)` and
`text("")` return nil. `line` recursively flattens, removes nil/empty parts, and
inserts separator fragments. Accept only strings, fragments, and arrays from a
formatter. Validate style keys, `#RRGGBB`, ANSI names, and theme-role symbols;
raise `ConfigError` with formatter context for bad values.

- [ ] **Step 5: Replace TracksPane templates**

Store config callables and star glyph in `update_config`. Build `text` by joining
normalized segment text. For grouped rows pass dominant artist as
`album_artist`; for flat rows pass nil. Resolve `:theme_role` colors with the
active theme during rendering, leave ANSI names/hex unchanged, and apply:

```ruby
fg = selected ? theme[:selection_text] : resolve_color(segment[:fg] || :text, theme)
segment_bg = selected ? theme[:selection_bg] : resolve_color(segment[:bg], theme)
screen.put(y, col, chunk, fg: fg, bg: segment_bg || bg,
           bold: selected || segment[:bold], italic: segment[:italic],
           underline: segment[:underline], dim: segment[:dim])
```

Delete `Template` and its tests after all pane paths use lambdas.

- [ ] **Step 6: Extend Screen cells and ANSI output**

Add underline and dim fields to `Cell`, include them in style diff tuples, and
emit SGR code `2` for dim and `4` for underline. Preserve existing color,
bold, italic, clipping, buffering, and flush behavior.

- [ ] **Step 7: Run focused tests and verify GREEN**

Run: `mise exec -- bundle exec ruby -Itest test/tracks_pane_test.rb test/screen_test.rb`

Expected: all formatter, pane, and screen tests pass.

- [ ] **Step 8: Commit formatter**

```bash
git add lib/rubyplayer/track_formatter.rb lib/rubyplayer/ui/tracks_pane.rb lib/rubyplayer/ui/screen.rb lib/rubyplayer.rb test/tracks_pane_test.rb test/screen_test.rb
git rm lib/rubyplayer/template.rb test/template_test.rb
git commit -m "Add styled Ruby track formatters"
```

---

### Task 3: Reload Error Modal and Theme Persistence

**Files:**
- Modify: `lib/rubyplayer/config.rb`
- Modify: `lib/rubyplayer/ui/app.rb`
- Test: `test/config_test.rb`
- Test: `test/app_test.rb`

**Interfaces:**
- Produces: `ConfigStore#persist_theme(id) -> true`, raising `ConfigError` transactionally on invalid source.
- Produces: App state `config_error` containing a `ConfigError` or nil.
- Produces modal dismissal through Escape/Enter and automatic clearing after successful reload.

- [ ] **Step 1: Write managed-theme-block tests**

Assert missing-file creation, preservation of user comments/code, replacement
rather than duplication, managed block last in source, immediate in-memory
theme update, and refreshed `config-previous.rb`:

```ruby
config.persist_theme(:ocean_mist)
source = File.read(@path)
assert_includes source, "# rubyplayer: managed theme begin"
assert_equal 1, source.scan("managed theme begin").size
assert_equal "ocean_mist", config["ui", "theme"]
assert_equal source, File.read(config.previous_path)
```

- [ ] **Step 2: Write App modal tests**

Create app with valid source, replace it with syntax-invalid source, force the
reload interval, and call `reload_config_if_changed`. Assert prior theme/format
remains, `config_error` is populated, rendered output contains exception and
path, ordinary actions are swallowed while modal is open, Escape dismisses it,
and a corrected save reloads and clears it. Add startup fallback test asserting
`ConfigStore#startup_error` appears in modal immediately after initialization.

- [ ] **Step 3: Run config and App tests and verify RED**

Run: `mise exec -- bundle exec ruby -Itest test/config_test.rb test/app_test.rb`

Expected: failures because managed Ruby persistence and config modal state do
not exist.

- [ ] **Step 4: Implement managed theme source block**

Use exact begin/end marker constants. Remove at most one complete prior managed
block, preserve all other bytes, ensure one separating newline, append the new
block, and atomically replace `config.rb`. Evaluate rewritten source before
activating it and refreshing backup. On failure, retain old data and raise.

- [ ] **Step 5: Implement error modal flow**

Initialize `@config_error = @config.startup_error`. Put config-error handling
before all other modal/input states. `reload_config_if_changed` rescues
`ConfigError`, assigns it, and returns without updating keymap/theme/formatter.
Successful reload clears it before applying live settings.

Render a bounded modal last, after all existing modals, with title
`Configuration Error`, wrapped/truncated path/class/message/source-location
lines, and `[esc/enter] Keep last known good config`. Ensure narrow terminals
never produce negative geometry.

- [ ] **Step 6: Run focused tests and verify GREEN**

Run: `mise exec -- bundle exec ruby -Itest test/config_test.rb test/app_test.rb`

Expected: all config and App tests pass.

- [ ] **Step 7: Commit recovery UI**

```bash
git add lib/rubyplayer/config.rb lib/rubyplayer/ui/app.rb test/config_test.rb test/app_test.rb
git commit -m "Keep last good config after reload errors"
```

---

### Task 4: Documentation and Dependency Cleanup

**Files:**
- Modify: `README.md`
- Modify: `Gemfile`
- Modify: `Gemfile.lock`

**Interfaces:**
- Documents final public DSL and formatter contracts from Tasks 1-3.
- Removes runtime dependency `tomlrb`.

- [ ] **Step 1: Rewrite architecture and configuration documentation**

Replace TOML/Template descriptions with executable Ruby config architecture.
Document config path, arbitrary-code warning, defaults, startup fallback,
hot-reload modal, last-known-good exact-source snapshot, theme managed block,
live settings, and restart-required settings.

- [ ] **Step 2: Add complete setting reference**

List every key under `ui`, `audio`, `scanner`, `library`, `eq`, `glyphs`,
`keymap`, and `backends`, including expected value type and default. Include one
full config showing section accessors and dynamic map assignment.

- [ ] **Step 3: Add formatter reference and presets**

Document `track` fields, `fmt.album_artist`, helper signatures, accepted return
shapes, style keys, selection precedence, theme roles, ANSI names, and hex.
Include complete copyable lambdas for minimal, colorful, compact,
metadata-heavy, and conditional presets.

- [ ] **Step 4: Remove TOML dependency**

Delete `gem "tomlrb", "~> 2.0"` from `Gemfile`, then run:

`mise exec -- bundle lock`

Expected: `Gemfile.lock` no longer lists `tomlrb` as a specification or
dependency.

- [ ] **Step 5: Search for stale compatibility references**

Run:

`rg -n "config\\.toml|Tomlrb|tomlrb|format_string_|RubyPlayer::Template|require_relative .*template" README.md Gemfile Gemfile.lock lib test`

Expected: no matches.

- [ ] **Step 6: Run complete verification**

Run: `mise exec -- bundle exec rake test`

Expected: all tests pass with zero failures and zero errors.

Run: `git diff --check`

Expected: no whitespace errors.

- [ ] **Step 7: Commit docs and dependency cleanup**

```bash
git add README.md Gemfile Gemfile.lock
git commit -m "Document executable Ruby configuration"
```

---

### Task 5: Final Review and Regression Verification

**Files:**
- Review all files changed by Tasks 1-4.

**Interfaces:**
- Confirms implementation matches `docs/superpowers/specs/2026-07-14-executable-ruby-config-design.md`.

- [ ] **Step 1: Review complete diff for transactional safety**

Run: `git diff fe1f839..HEAD -- lib test README.md Gemfile Gemfile.lock`

Check that failed evaluations cannot mutate active data or backup, backup writes
are atomic, only primary success updates backup, and hot reload records failed
signatures without retry loops.

- [ ] **Step 2: Review formatter and renderer boundaries**

Confirm formatters produce data only, TracksPane resolves theme roles, Screen
knows only terminal colors/attributes, and selection always overrides custom
foreground/background.

- [ ] **Step 3: Run final suite from clean process**

Run: `mise exec -- bundle exec rake test`

Expected: all tests pass with zero failures and zero errors.

- [ ] **Step 4: Verify repository state**

Run: `git status --short`

Expected: clean working tree.
