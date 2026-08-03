# Queued Pane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent, read-only Queued pane that shows upcoming playback and the three latest history events without changing the interactive Playback Queue view.

**Architecture:** Extract stateless list-row drawing from `TracksPane`, add an atomic upcoming snapshot to `PlaybackEngine`, and build a snapshot-backed `UI::QueuedPane`. `UI::App` reserves Queued width before optional dedicated artwork, refreshes snapshots from existing events, and never makes the pane focusable.

**Tech Stack:** Ruby 4.x, Minitest, custom double-buffered `UI::Screen`, SQLite-backed `Library`, mutex-protected `PlaybackEngine`, executable Ruby configuration.

## Global Constraints

- Preserve the existing top-level `Playback Queue` Library item and every queue ordering/removal invariant.
- Queued is read-only and never becomes `@active_pane`; Tab still switches only Library and Tracks.
- Default Queued preference is `true`, width is `36`, minimum retained Library + Tracks width is exactly `72`, and the effective default Queued threshold is `108` columns.
- Selecting the top-level Playback Queue suppresses Queued without changing its saved preference.
- Upcoming excludes queue index zero during normal playing or pause; stopped and Focus playback include the full queue.
- Previously contains at most three newest playback events, newest first, with duplicates preserved.
- Mixed known/unknown cumulative duration renders as the known sum plus ` + ??`.
- Queued refreshes from events; render performs no SQL query or engine lock and preserves near-zero idle CPU use.
- Use `mise exec -- bundle exec ...`; plain `bundle exec` can select the wrong Ruby.
- Verify raw-TTY behavior through tests, not a headless app launch.
- Preserve unrelated user change `.githooks/pre-commit` and stage only feature files.
- Project policy requires one implementation commit for this feature. Do not commit intermediate task states; commit once after full verification and memory review.

---

## File Structure

**Create:**

- `lib/rubyplayer/ui/list_row_renderer.rb` — stateless shared track-row building, styled segment drawing, and decorative section-header text.
- `lib/rubyplayer/ui/queued_pane.rb` — read-only snapshot storage, duration/header calculation, height allocation, and rendering.
- `test/list_row_renderer_test.rb` — direct regression coverage for extracted styling/clipping primitives.
- `test/queued_pane_test.rb` — Queued content, totals, history, overflow, and height allocation.

**Modify:**

- `lib/rubyplayer.rb` — load shared renderer and QueuedPane before App is required directly.
- `lib/rubyplayer/ui/tracks_pane.rb` — delegate row building, drawing, and header construction to shared renderer; keep all interactive state local.
- `lib/rubyplayer/config.rb` — queued formatter/defaults, managed preference persistence.
- `lib/rubyplayer/config_dsl.rb` — boolean validation and positive queued width.
- `lib/rubyplayer/keymap.rb` — global `b => toggle_queued_pane` binding.
- `lib/rubyplayer/ui/bottom_lines.rb` — human label for the new action.
- `lib/rubyplayer/playback_engine.rb` — atomic `upcoming_items` snapshot.
- `lib/rubyplayer/ui/app.rb` — component lifecycle, event refresh, toggle, config reload, visibility, and four-pane layout.
- `test/config_test.rb` — defaults, booleans, width validation, managed block persistence.
- `test/keymap_test.rb` — collision-free binding in both active scopes.
- `test/playback_engine_test.rb` — stopped/playing/paused/Focus snapshot semantics.
- `test/tracks_pane_test.rb` — extraction regression for rows and queue identity.
- `test/app_playback_queue_test.rb` — top-level queue suppression and unchanged queue interaction.
- `test/app_rendering_theme_config_test.rb` — thresholds, pane order, artwork priority, toggle persistence/reload, events, and idle behavior.
- `examples/config.rb` — commented queued preference, width, and formatter examples.
- `README.md` — navigation behavior, file map, managed persistence, hot reload, and settings table.
- `AGENTS.md` — durable layout/persistence lesson learned after green verification.

---

### Task 1: Extract Stateless List Row Rendering

**Files:**

- Create: `lib/rubyplayer/ui/list_row_renderer.rb`
- Create: `test/list_row_renderer_test.rb`
- Modify: `lib/rubyplayer.rb:25-31`
- Modify: `lib/rubyplayer/ui/tracks_pane.rb:213-232,277-312,348-367`
- Test: `test/tracks_pane_test.rb`

**Interfaces:**

- Consumes: `TrackFormatter.render(formatter, track, album_artist:, star_glyph:)`, `UI::Screen#put`, semantic `Theme` hashes.
- Produces: `UI::ListRowRenderer.track(track, formatter:, star_glyph:, album_artist: nil) -> Hash`, `render_track(screen, row, x:, y:, w:, selected:, bg:, theme:) -> nil`, and `header_line(label, width) -> String`.

- [ ] **Step 1: Write direct failing tests for shared row construction and drawing**

Create `test/list_row_renderer_test.rb`:

```ruby
require 'test_helper'
require 'stringio'

class ListRowRendererTest < Minitest::Test
  def setup
    @track = RubyPlayer::Track.new(id: 7, title: 'Song', artist: 'Band', duration_ms: 65_000)
    @formatter = lambda do |track, fmt|
      fmt.line(fmt.text(track.title, bold: true),
               fmt.duration(track.duration_ms, fg: :text_muted),
               fmt.text(track.artist, italic: true))
    end
  end

  def test_track_builds_existing_segment_row_shape
    row = RubyPlayer::UI::ListRowRenderer.track(
      @track, formatter: @formatter, star_glyph: '★'
    )

    assert_equal :track, row[:type]
    assert_same @track, row[:track]
    assert_equal 'Song 1:05 Band', row[:text]
    assert row[:segments].first[:bold]
    assert_equal :text_muted, row[:segments][2][:fg]
  end

  def test_render_track_clips_segments_and_preserves_styles
    row = RubyPlayer::UI::ListRowRenderer.track(
      @track, formatter: @formatter, star_glyph: '★'
    )
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 2, cols: 8)

    RubyPlayer::UI::ListRowRenderer.render_track(
      screen, row, x: 0, y: 0, w: 8, selected: false, bg: nil,
      theme: RubyPlayer::Theme::DEFAULT
    )
    cells = screen.instance_variable_get(:@back)[0]

    assert_equal 'Song 1:0', cells.map(&:ch).join
    assert cells[0].bold
    assert_equal RubyPlayer::Theme::DEFAULT[:text_muted], cells[5].fg
  end

  def test_selected_row_uses_selection_palette
    row = RubyPlayer::UI::ListRowRenderer.track(
      @track, formatter: @formatter, star_glyph: '★'
    )
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 1, cols: 20)

    RubyPlayer::UI::ListRowRenderer.render_track(
      screen, row, x: 0, y: 0, w: 20, selected: true,
      bg: RubyPlayer::Theme::DEFAULT[:selection_bg], theme: RubyPlayer::Theme::DEFAULT
    )
    cell = screen.instance_variable_get(:@back)[0][0]

    assert_equal RubyPlayer::Theme::DEFAULT[:selection_text], cell.fg
    assert_equal RubyPlayer::Theme::DEFAULT[:selection_bg], cell.bg
    assert cell.bold
  end

  def test_header_line_fills_available_width
    assert_equal '--- Album ---', RubyPlayer::UI::ListRowRenderer.header_line('Album', 13)
    assert_equal '--- Al', RubyPlayer::UI::ListRowRenderer.header_line('Album', 6)
  end
end
```

- [ ] **Step 2: Run the focused test and verify the missing constant failure**

Run:

```bash
mise exec -- bundle exec ruby -Itest test/list_row_renderer_test.rb
```

Expected: FAIL with `NameError: uninitialized constant RubyPlayer::UI::ListRowRenderer`.

- [ ] **Step 3: Implement the shared renderer**

Create `lib/rubyplayer/ui/list_row_renderer.rb`:

```ruby
# frozen_string_literal: true

module RubyPlayer
  module UI
    module ListRowRenderer
      module_function

      def track(track, formatter:, star_glyph:, album_artist: nil)
        segments = TrackFormatter.render(
          formatter, track, album_artist: album_artist, star_glyph: star_glyph
        )
        { type: :track, text: segments.map { |segment| segment[:text] }.join,
          segments: segments, track: track }
      end

      def render_track(screen, row, x:, y:, w:, selected:, bg:, theme:)
        col = x
        remaining = w
        row[:segments].each do |segment|
          break if remaining <= 0
          next if segment[:text].empty?

          chunk = segment[:text][0, remaining]
          fg = selected ? theme[:selection_text] : resolve_color(segment[:fg] || :text, theme)
          segment_bg = selected ? theme[:selection_bg] : resolve_color(segment[:bg], theme)
          screen.put(y, col, chunk, fg: fg, bg: segment_bg || bg,
                                    bold: selected || segment[:bold], italic: segment[:italic],
                                    underline: segment[:underline], dim: segment[:dim])
          col += chunk.size
          remaining -= chunk.size
        end
        nil
      end

      def header_line(label, width)
        prefix = "--- #{label} "
        return prefix[0, width] if prefix.size >= width

        "#{prefix}#{'-' * (width - prefix.size)}"
      end

      def resolve_color(color, theme)
        color.is_a?(Symbol) && theme.key?(color) ? theme[color] : color
      end
      private_class_method :resolve_color
    end
  end
end
```

Add this require before panes in `lib/rubyplayer.rb`:

```ruby
require_relative 'rubyplayer/ui/list_row_renderer'
```

- [ ] **Step 4: Refactor TracksPane onto the helper without behavior changes**

In `TracksPane#render`, replace private calls with:

```ruby
if row[:type] == :header
  screen.put(y + i, x, ListRowRenderer.header_line(row[:text], content_w),
             fg: theme[:info], bg: bg, bold: true)
elsif row[:type] == :empty
  screen.put(y + i, x, row[:text][0, content_w], fg: theme[:text_muted])
else
  ListRowRenderer.render_track(
    screen, row, x: x, y: y + i, w: content_w,
    selected: selected, bg: bg, theme: theme
  )
end
```

Replace `flat_rows` track hashes with:

```ruby
def flat_rows
  filtered_tracks.map do |track|
    ListRowRenderer.track(track, formatter: @flat_formatter, star_glyph: @star_glyph)
  end
end
```

Replace each grouped track hash with:

```ruby
ListRowRenderer.track(
  track, formatter: @grouped_formatter, star_glyph: @star_glyph,
  album_artist: album_artist
)
```

Delete `TracksPane#render_track_row`, `#header_line`, and `#resolve_color` after every caller has moved.

- [ ] **Step 5: Run helper and TracksPane tests**

Run:

```bash
mise exec -- bundle exec ruby -Itest test/list_row_renderer_test.rb
mise exec -- bundle exec ruby -Itest test/tracks_pane_test.rb
```

Expected: both files PASS; existing queue rows remain flat and selection rendering remains unchanged.

---

### Task 2: Add Queued Configuration and Keymap Primitives

**Files:**

- Modify: `lib/rubyplayer/config.rb:7-31,34-89,105-190`
- Modify: `lib/rubyplayer/config_dsl.rb:120-174`
- Modify: `lib/rubyplayer/keymap.rb:9-35`
- Modify: `lib/rubyplayer/ui/bottom_lines.rb:82-99`
- Test: `test/config_test.rb`
- Test: `test/keymap_test.rb`

**Interfaces:**

- Consumes: existing `ConfigStore#persist_managed`, `TrackFormatter` callable contract, global keymap merging.
- Produces: `config['ui', 'queued_pane'] -> true|false`, `config['ui', 'queued_pane_width'] -> Integer`, `config['ui', 'format_track_queued'] -> callable`, `ConfigStore#persist_queued_pane(visible) -> true`, and `b -> :toggle_queued_pane`.

- [ ] **Step 1: Write failing config tests**

Add to `test/config_test.rb`:

```ruby
def test_queued_pane_defaults
  config = RubyPlayer::ConfigStore.new(path: @path)

  assert config['ui', 'queued_pane']
  assert_equal 36, config['ui', 'queued_pane_width']
  assert_respond_to config['ui', 'format_track_queued'], :call
end

def test_boolean_settings_accept_false
  write_config <<~RUBY
    RubyPlayer.configure do |config|
      config.ui.queued_pane = false
      config.ui.art_accent = false
    end
  RUBY

  config = RubyPlayer::ConfigStore.new(path: @path)

  refute config['ui', 'queued_pane']
  refute config['ui', 'art_accent']
end

def test_queued_pane_width_must_be_positive
  write_config 'RubyPlayer.configure { |config| config.ui.queued_pane_width = 0 }'

  error = assert_raises(RubyPlayer::ConfigError) do
    RubyPlayer::ConfigStore.new(path: @path)
  end

  assert_includes error.message, 'ui.queued_pane_width must be a positive Integer'
end

def test_persist_queued_pane_replaces_only_its_managed_block
  config = RubyPlayer::ConfigStore.new(path: @path)
  config.persist_theme(:basic_terminal)
  config.persist_art_mode(:corner)

  assert config.persist_queued_pane(false)
  assert config.persist_queued_pane(true)

  source = File.read(@path)
  assert_equal 1, source.scan('managed queued_pane begin').size
  assert_equal 1, source.scan('managed theme begin').size
  assert_equal 1, source.scan('managed art_mode begin').size
  assert_match(/config\.ui\.queued_pane = true/, source)
  assert config['ui', 'queued_pane']
end
```

- [ ] **Step 2: Write the failing keymap and label tests**

Add to `test/keymap_test.rb`:

```ruby
def test_b_toggles_queued_pane_from_both_interactive_scopes
  keymap = RubyPlayer::Keymap.new

  assert_equal :toggle_queued_pane, keymap.action_for('b', pane: :library)
  assert_equal :toggle_queued_pane, keymap.action_for('B', pane: :tracks)
end
```

Add to `test/bottom_lines_test.rb` near other label coverage:

```ruby
def test_queued_pane_binding_has_human_label
  labels = RubyPlayer::UI::HotkeyLine::LABELS

  assert_equal 'queue bar', labels[:toggle_queued_pane]
end
```

- [ ] **Step 3: Run focused tests and verify missing settings/method/action failures**

Run:

```bash
mise exec -- bundle exec ruby -Itest test/config_test.rb
mise exec -- bundle exec ruby -Itest test/keymap_test.rb
mise exec -- bundle exec ruby -Itest test/bottom_lines_test.rb
```

Expected: FAIL because queued defaults, persistence method, binding, and label do not exist; the boolean test also exposes the current `TrueClass`/`FalseClass` validation bug.

- [ ] **Step 4: Add formatter and UI defaults**

In `lib/rubyplayer/config.rb`, define:

```ruby
DEFAULT_FORMAT_QUEUED = lambda do |track, fmt|
  fmt.line(
    fmt.text(track.title, bold: true),
    fmt.duration(track.duration_ms, fg: :text_muted),
    fmt.text(track.artist, italic: true)
  )
end
```

Add to `DEFAULTS['ui']`:

```ruby
'format_track_queued' => DEFAULT_FORMAT_QUEUED,
'queued_pane' => true,
'queued_pane_width' => 36,
```

- [ ] **Step 5: Correct boolean and width validation**

In `ConfigDSL.validate_known_tree!`, put boolean validation before the general class comparison:

```ruby
elsif expected == true || expected == false
  unless value == true || value == false
    raise SettingError, "#{current.join('.')} must be true or false"
  end
elsif expected.is_a?(Integer)
```

Add `ui.queued_pane_width` to the `positive` settings in `validate_special_values!` so zero and negative values get the standard positive-integer error.

- [ ] **Step 6: Add managed persistence, binding, and label**

Update `ConfigStore`:

```ruby
MANAGED_SETTINGS = %w[theme art_mode queued_pane].freeze

def persist_queued_pane(visible)
  persist_managed('queued_pane', "config.ui.queued_pane = #{visible}")
end
```

Add to `Keymap::DEFAULTS['global']`:

```ruby
'b' => 'toggle_queued_pane',
```

Add to `HotkeyLine::LABELS`:

```ruby
toggle_queued_pane: 'queue bar',
```

- [ ] **Step 7: Run config, keymap, and bottom-line tests**

Run:

```bash
mise exec -- bundle exec ruby -Itest test/config_test.rb
mise exec -- bundle exec ruby -Itest test/keymap_test.rb
mise exec -- bundle exec ruby -Itest test/bottom_lines_test.rb
```

Expected: all three files PASS.

---

### Task 3: Add Atomic Upcoming Queue Snapshot

**Files:**

- Modify: `lib/rubyplayer/playback_engine.rb:155-175`
- Test: `test/playback_engine_test.rb`

**Interfaces:**

- Consumes: `PlayQueue#items -> Array<Track>`, `@playing` under `PlaybackEngine` mutex.
- Produces: `PlaybackEngine#upcoming_items -> Array<Track>`, always a detached array snapshot.

- [ ] **Step 1: Write failing lifecycle tests**

Add to `test/playback_engine_test.rb`:

```ruby
def test_upcoming_items_include_head_when_stopped_and_exclude_it_when_playing_or_paused
  first = make_track('shantae.gbs', subtune: 0)
  second = make_track('shantae.gbs', subtune: 1)
  @engine.enqueue_end([first, second])

  assert_equal [first.id, second.id], @engine.upcoming_items.map(&:id)

  @engine.toggle_play
  wait_for_event(:track_started)
  assert_equal [second.id], @engine.upcoming_items.map(&:id)

  @engine.toggle_play
  wait_until { @engine.state[:paused] }
  assert_equal [second.id], @engine.upcoming_items.map(&:id)
end

def test_upcoming_items_include_full_queue_during_focus_playback
  first = make_track('shantae.gbs', subtune: 0)
  second = make_track('shantae.gbs', subtune: 1)
  @engine.enqueue_end([first, second])

  @engine.play_focus(RubyPlayer::FocusSounds::ALL.first)

  assert_equal [first.id, second.id], @engine.upcoming_items.map(&:id)
end

def test_upcoming_items_returns_a_detached_snapshot
  first = make_track('shantae.gbs', subtune: 0)
  second = make_track('shantae.gbs', subtune: 1)
  @engine.enqueue_end([first])

  snapshot = @engine.upcoming_items
  @engine.enqueue_end([second])

  assert_equal [first.id], snapshot.map(&:id)
  assert_equal [first.id, second.id], @engine.upcoming_items.map(&:id)
end
```

- [ ] **Step 2: Run the engine test and verify the missing method failure**

Run:

```bash
mise exec -- bundle exec ruby -Itest test/playback_engine_test.rb
```

Expected: FAIL with `NoMethodError: undefined method 'upcoming_items'`.

- [ ] **Step 3: Implement the mutex-protected snapshot**

Add beside `queue_items` in `PlaybackEngine`:

```ruby
def upcoming_items
  @mutex.synchronize do
    items = @queue.items
    @playing ? items.drop(1) : items
  end
end
```

Do not infer from `state[:next_track]`; all membership and playback state must be captured under the same mutex.

- [ ] **Step 4: Run the engine tests**

Run:

```bash
mise exec -- bundle exec ruby -Itest test/playback_engine_test.rb
```

Expected: PASS, including existing queue, Focus, history, and decoder recovery cases.

---

### Task 4: Build the Snapshot-Backed QueuedPane

**Files:**

- Create: `lib/rubyplayer/ui/queued_pane.rb`
- Create: `test/queued_pane_test.rb`
- Modify: `lib/rubyplayer.rb:25-32`

**Interfaces:**

- Consumes: `upcoming_source.call -> Array<Track>`, `history_source.call -> Array<Track>` newest first, config keys `glyphs.star` and `ui.format_track_queued`, `ListRowRenderer`, `DurationFormatter`, and `UI::Screen`.
- Produces: `QueuedPane#reload! -> true`, `#update_config(config) -> nil`, `#display_rows(height) -> Array<Hash>`, `#render(screen, x:, y:, w:, h:, theme:) -> nil`, and read-only `upcoming`/`previous` snapshots.

- [ ] **Step 1: Write failing pane tests for totals and history**

Create `test/queued_pane_test.rb` with helpers and core cases:

```ruby
require 'test_helper'
require 'stringio'

class QueuedPaneTest < Minitest::Test
  def setup
    @config = RubyPlayer::ConfigStore.new(path: '/nonexistent.rb', create_if_missing: false)
    @upcoming = []
    @history = []
    @pane = RubyPlayer::UI::QueuedPane.new(
      config: @config,
      upcoming_source: -> { @upcoming },
      history_source: -> { @history }
    )
  end

  def track(id, title:, duration_ms:, artist: 'Artist')
    RubyPlayer::Track.new(
      id: id, title: title, artist: artist, duration_ms: duration_ms
    )
  end

  def texts(height = 12)
    @pane.display_rows(height).map { |row| row[:text] }
  end

  def test_header_counts_full_queue_and_sums_known_duration
    @upcoming = [
      track(1, title: 'One', duration_ms: 60_000),
      track(2, title: 'Two', duration_ms: 65_000)
    ]
    @pane.reload!

    assert_equal 'Upcoming (2/2:05)', texts.first
  end

  def test_unknown_duration_appends_marker_to_known_sum
    @upcoming = [
      track(1, title: 'Known', duration_ms: 7_425_000),
      track(2, title: 'Unknown', duration_ms: nil)
    ]
    @pane.reload!

    assert_equal 'Upcoming (2/123:45 + ??)', texts.first
  end

  def test_all_unknown_duration_starts_with_zero_known_sum
    @upcoming = [track(1, title: 'Unknown', duration_ms: nil)]
    @pane.reload!

    assert_equal 'Upcoming (1/0:00 + ??)', texts.first
  end

  def test_previous_keeps_three_newest_events_and_duplicates
    repeated = track(1, title: 'Again', duration_ms: 60_000)
    @history = [
      repeated,
      repeated,
      track(2, title: 'Older', duration_ms: 60_000),
      track(3, title: 'Too old', duration_ms: 60_000)
    ]
    @pane.reload!

    previous = @pane.display_rows(12).drop_while { |row| row[:text] != 'Previously' }.drop(1)
    assert_equal %w[Again Again Older], previous.map { |row| row[:track].title }
  end
end
```

- [ ] **Step 2: Add failing allocation, empty-state, and render tests**

Append:

```ruby
def test_overflow_uses_last_upcoming_row_for_exact_hidden_count
  @upcoming = 6.times.map do |index|
    track(index, title: "Song #{index}", duration_ms: 60_000)
  end
  @history = 3.times.map do |index|
    track(20 + index, title: "Past #{index}", duration_ms: 60_000)
  end
  @pane.reload!

  assert_equal [
    'Upcoming (6/6:00)', 'Song 0 1:00 Artist', '+ 5 more',
    'Previously', 'Past 0 1:00 Artist', 'Past 1 1:00 Artist', 'Past 2 1:00 Artist'
  ], texts(7)
end

def test_short_height_preserves_previous_before_upcoming
  @upcoming = [track(1, title: 'Next', duration_ms: 60_000)]
  @history = 3.times.map do |index|
    track(10 + index, title: "Past #{index}", duration_ms: 60_000)
  end
  @pane.reload!

  assert_equal [
    'Previously', 'Past 0 1:00 Artist', 'Past 1 1:00 Artist', 'Past 2 1:00 Artist'
  ], texts(4)
end

def test_empty_sections_have_contextual_messages
  assert_equal [
    'Upcoming (0/0:00)', 'Queue empty',
    'Previously', 'No playback history yet'
  ], texts(4)
end

def test_render_draws_decorative_headers_and_compact_rows
  @upcoming = [track(1, title: 'Song', duration_ms: 60_000, artist: 'Band')]
  @pane.reload!
  screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 8, cols: 30)

  @pane.render(screen, x: 0, y: 0, w: 30, h: 8, theme: RubyPlayer::Theme::DEFAULT)
  lines = screen.instance_variable_get(:@back).map { |row| row.map(&:ch).join }

  assert_includes lines[0], '--- Upcoming (1/1:00)'
  assert_includes lines[1], 'Song 1:00 Band'
  assert_includes lines[2], '--- Previously'
end
```

- [ ] **Step 3: Run the pane test and verify the missing constant failure**

Run:

```bash
mise exec -- bundle exec ruby -Itest test/queued_pane_test.rb
```

Expected: FAIL with `NameError: uninitialized constant RubyPlayer::UI::QueuedPane`.

- [ ] **Step 4: Implement snapshot loading, totals, and row allocation**

Create `lib/rubyplayer/ui/queued_pane.rb` with this structure:

```ruby
# frozen_string_literal: true

module RubyPlayer
  module UI
    class QueuedPane
      HISTORY_LIMIT = 3

      attr_reader :upcoming, :previous

      def initialize(config:, upcoming_source:, history_source:)
        @upcoming_source = upcoming_source
        @history_source = history_source
        update_config(config)
        reload!
      end

      def update_config(config)
        @formatter = config['ui', 'format_track_queued']
        @star_glyph = config['glyphs', 'star']
        rebuild_rows
        nil
      end

      def reload!
        @upcoming = @upcoming_source.call.dup.freeze
        @previous = @history_source.call.first(HISTORY_LIMIT).dup.freeze
        rebuild_rows
        true
      end

      def display_rows(height)
        return [] unless height.positive?

        previous_block = previous_rows_for(height)
        remaining = height - previous_block.size
        return previous_block if remaining <= 0

        upcoming_rows_for(remaining) + previous_block
      end

      def render(screen, x:, y:, w:, h:, theme:)
        display_rows(h).each_with_index do |row, index|
          case row[:type]
          when :header
            screen.put(y + index, x, ListRowRenderer.header_line(row[:text], w),
                       fg: theme[:info], bold: true)
          when :empty
            screen.put(y + index, x, row[:text][0, w], fg: theme[:text_muted])
          else
            ListRowRenderer.render_track(
              screen, row, x: x, y: y + index, w: w,
              selected: false, bg: nil, theme: theme
            )
          end
        end
        nil
      end

      private

      def rebuild_rows
        return unless defined?(@upcoming) && defined?(@previous)

        @upcoming_rows = @upcoming.map { |track| build_track_row(track) }
        @previous_rows = @previous.map { |track| build_track_row(track) }
      end

      def build_track_row(track)
        ListRowRenderer.track(track, formatter: @formatter, star_glyph: @star_glyph)
      end

      def previous_rows_for(height)
        body = @previous_rows.empty? ? [{ type: :empty, text: 'No playback history yet' }] : @previous_rows
        body_capacity = [height - 1, 0].max
        [{ type: :header, text: 'Previously' }] + body.first(body_capacity)
      end

      def upcoming_rows_for(height)
        return [] unless height.positive?

        header = { type: :header, text: "Upcoming (#{@upcoming.size}/#{total_duration})" }
        body_capacity = height - 1
        return [header] unless body_capacity.positive?
        return [header, { type: :empty, text: 'Queue empty' }] if @upcoming_rows.empty?
        return [header] + @upcoming_rows if @upcoming_rows.size <= body_capacity

        visible_count = [body_capacity - 1, 0].max
        hidden_count = @upcoming_rows.size - visible_count
        [header] + @upcoming_rows.first(visible_count) +
          [{ type: :empty, text: "+ #{hidden_count} more" }]
      end

      def total_duration
        known_ms = @upcoming.filter_map(&:duration_ms).sum
        text = DurationFormatter.format(known_ms)
        @upcoming.any? { |track| track.duration_ms.nil? } ? "#{text} + ??" : text
      end
    end
  end
end
```

Add after `list_row_renderer` in `lib/rubyplayer.rb`:

```ruby
require_relative 'rubyplayer/ui/queued_pane'
```

- [ ] **Step 5: Run QueuedPane and shared renderer tests**

Run:

```bash
mise exec -- bundle exec ruby -Itest test/queued_pane_test.rb
mise exec -- bundle exec ruby -Itest test/list_row_renderer_test.rb
```

Expected: both files PASS.

---

### Task 5: Wire QueuedPane State, Events, Toggle, and Config Reload

**Files:**

- Modify: `lib/rubyplayer/ui/app.rb:19-95,315-354,506-516,881-958`
- Test: `test/app_rendering_theme_config_test.rb`
- Test: `test/app_playback_queue_test.rb`

**Interfaces:**

- Consumes: `QueuedPane.new`, `PlaybackEngine#upcoming_items`, `Library#history(limit: 3)`, `ConfigStore#persist_queued_pane`, and `:toggle_queued_pane`.
- Produces: `App#queued_pane`, runtime `@queued_pane_enabled`, private `toggle_queued_pane`, private `queued_pane_cols(cols) -> Integer`, and event/config-driven snapshot refresh.

- [ ] **Step 1: Write failing lifecycle and focus tests**

Add to `test/app_rendering_theme_config_test.rb`:

```ruby
def test_queued_pane_loads_upcoming_and_three_history_events
  library = @app.instance_variable_get(:@library)
  tracks = library.recently_added.first(2)
  @app.engine.enqueue_end(tracks)
  4.times do |index|
    library.record_history(
      track_id: tracks[index % tracks.size].id,
      started_at: "2026-08-01T00:0#{index}:00Z",
      ended_at: "2026-08-01T00:0#{index}:30Z"
    )
  end

  @app.refresh_panes

  assert_equal tracks.map(&:id), @app.queued_pane.upcoming.map(&:id)
  assert_equal 3, @app.queued_pane.previous.size
end

def test_tab_never_focuses_queued_pane
  6.times do
    @app.handle_key('tab')
    assert_includes %i[library tracks], @app.active_pane
  end
end
```

- [ ] **Step 2: Write failing toggle persistence and hot-reload tests**

Append:

```ruby
def test_queued_pane_toggle_persists_and_reflows
  select_library_kind(:folder)
  use_screen(cols: 108)

  @app.handle_key('b')

  refute @app.instance_variable_get(:@queued_pane_enabled)
  assert_includes File.read(File.join(@tmp, 'config.rb')), 'config.ui.queued_pane = false'
end

def test_enabling_queued_pane_while_narrow_reports_deferred_visibility
  select_library_kind(:folder)
  use_screen(cols: 100)
  @app.handle_key('b') # default on -> off

  @app.handle_key('b') # off -> on, still too narrow
  @app.render

  assert_includes back_buffer_text, 'Queued pane: ON (hidden until terminal is wider)'
end

def test_hot_reload_updates_queued_preference_width_and_formatter
  path = File.join(@tmp, 'config.rb')
  File.write(path, <<~RUBY)
    RubyPlayer.configure do |config|
      config.ui.queued_pane = false
      config.ui.queued_pane_width = 44
      config.ui.format_track_queued = ->(track, fmt) { fmt.text(track.title.upcase) }
    end
  RUBY

  force_config_reload

  refute @app.instance_variable_get(:@queued_pane_enabled)
  assert_equal 44, @app.instance_variable_get(:@config)['ui', 'queued_pane_width']
end

def test_idle_frames_do_not_reload_queued_snapshots
  pane = @app.queued_pane
  original_reload = pane.method(:reload!)
  reloads = 0
  pane.define_singleton_method(:reload!) do
    reloads += 1
    original_reload.call
  end
  @app.render_if_needed

  3.times { @app.render_if_needed }

  assert_equal 0, reloads
end

def test_playback_state_event_refreshes_queued_snapshot_once
  pane = @app.queued_pane
  original_reload = pane.method(:reload!)
  reloads = 0
  pane.define_singleton_method(:reload!) do
    reloads += 1
    original_reload.call
  end

  @app.instance_variable_get(:@bus).publish(:playback_state, playing: false, paused: false)
  @app.handle_events

  assert_equal 1, reloads
end
```

Call the included `force_config_reload` helper directly from the test body. Keep it private in `AppTestSupport`; Ruby permits a private method call without an explicit receiver.

- [ ] **Step 3: Run App tests and verify missing component/action failures**

Run:

```bash
mise exec -- bundle exec ruby -Itest test/app_rendering_theme_config_test.rb
mise exec -- bundle exec ruby -Itest test/app_playback_queue_test.rb
```

Expected: FAIL because `App#queued_pane`, initialization, toggle dispatch, and refresh wiring do not exist.

- [ ] **Step 4: Initialize QueuedPane and expose it for focused tests**

Extend the App reader list with `:queued_pane`. After `TracksPane` construction, add:

```ruby
@queued_pane = QueuedPane.new(
  config: @config,
  upcoming_source: -> { @engine.upcoming_items },
  history_source: lambda {
    @library.history(limit: QueuedPane::HISTORY_LIMIT).map { |entry| entry[:track] }
  }
)
@queued_pane_enabled = @config['ui', 'queued_pane']
```

- [ ] **Step 5: Dispatch and persist the toggle**

Add to `App#dispatch`:

```ruby
when :toggle_queued_pane then toggle_queued_pane
```

Add near album-art layout toggles:

```ruby
def toggle_queued_pane
  @queued_pane_enabled = !@queued_pane_enabled
  begin
    @config.persist_queued_pane(@queued_pane_enabled)
  rescue ConfigError => e
    @config_error = e
  end

  message = "Queued pane: #{@queued_pane_enabled ? 'ON' : 'OFF'}"
  if @queued_pane_enabled && queued_pane_cols(@screen.cols).zero? &&
     @library_pane.selected&.kind != :queue
    message += ' (hidden until terminal is wider)'
  end
  @status_line.set_message(message)
  invalidate_screen!
end
```

Add the final visibility calculation beside the existing art-width helper:

```ruby
def queued_pane_cols(cols)
  return 0 unless @queued_pane_enabled
  return 0 if @library_pane.selected&.kind == :queue

  width = @config['ui', 'queued_pane_width']
  cols - width > SINGLE_PANE_MAX_WIDTH ? width : 0
end
```

Task 6 uses this helper for layout; defining it here also lets toggle status distinguish narrow auto-hiding from the Playback Queue suppression rule.

- [ ] **Step 6: Refresh snapshots from lifecycle paths**

At the end of `refresh_panes`, add:

```ruby
@queued_pane.reload!
```

For a batch containing only `playback_state`, reload QueuedPane after processing events because normal-to-Focus changes `upcoming_items` without necessarily changing queue contents. Use one boolean to avoid duplicate reloads:

```ruby
refresh_queued = false
# inside event cases:
when :playback_state
  set_art(nil) unless payload[:playing]
  refresh_queued = true
# after event loop:
if refresh
  refresh_panes
elsif refresh_queued
  @queued_pane.reload!
end
```

Track-start, track-end, queue-change, and scan refreshes already flow through `refresh_panes` and therefore reload both panes once.

- [ ] **Step 7: Apply queued settings on hot reload**

After `@tracks_pane.update_config(@config)` in `reload_config_if_changed`, add:

```ruby
@queued_pane_enabled = @config['ui', 'queued_pane']
@queued_pane.update_config(@config)
invalidate_screen!
```

Keep theme preview ordering intact. `invalidate_screen!` is required because queued width can move the iTerm2 artwork region.

- [ ] **Step 8: Run lifecycle/config App tests**

Run:

```bash
mise exec -- bundle exec ruby -Itest test/app_rendering_theme_config_test.rb
mise exec -- bundle exec ruby -Itest test/app_playback_queue_test.rb
```

Expected: new lifecycle, toggle, and reload tests PASS.

---

### Task 6: Integrate Width Allocation and Preserve Playback Queue Behavior

**Files:**

- Modify: `lib/rubyplayer/ui/app.rb:1046-1120`
- Modify: `test/app_rendering_theme_config_test.rb`
- Modify: `test/app_playback_queue_test.rb`

**Interfaces:**

- Consumes: configured queued width/preference, selected Library row kind, existing `art_pane_cols`, `render_art_pane`, `place_art_corner`, and `QueuedPane#render`.
- Produces: layout order `Library | Tracks | Now Playing | Queued` and dynamic suppression without preference mutation.

- [ ] **Step 1: Write failing threshold and suppression tests**

Add to `test/app_rendering_theme_config_test.rb`:

```ruby
def test_queued_pane_appears_at_default_threshold_for_non_queue_view
  select_library_kind(:folder)
  use_screen(cols: 108)

  @app.render

  title_row = @app.instance_variable_get(:@screen).instance_variable_get(:@back)[0].map(&:ch).join
  assert_includes title_row, 'Library'
  assert_includes title_row, 'Tracks'
  assert_includes title_row, 'Queued'
end

def test_queued_pane_auto_hides_below_default_threshold_without_changing_preference
  select_library_kind(:folder)
  use_screen(cols: 107)

  @app.render

  title_row = @app.instance_variable_get(:@screen).instance_variable_get(:@back)[0].map(&:ch).join
  refute_includes title_row, 'Queued'
  assert @app.instance_variable_get(:@queued_pane_enabled)
end

def test_playback_queue_library_item_suppresses_queued_pane
  select_library_kind(:queue)
  use_screen(cols: 140)

  @app.render

  title_row = @app.instance_variable_get(:@screen).instance_variable_get(:@back)[0].map(&:ch).join
  assert_equal 1, title_row.scan('Playback Queue').size
  refute_includes title_row, 'Queued'
  assert @app.instance_variable_get(:@queued_pane_enabled)
end
```

The first test must select a folder because App intentionally starts on the top-level Playback Queue, where Queued is suppressed by requirement.

- [ ] **Step 2: Write failing artwork priority and pane-order tests**

Append:

```ruby
def test_queued_is_rightmost_after_dedicated_artwork_when_both_fit
  select_library_kind(:folder)
  @app.instance_variable_set(:@art_mode, :pane)
  use_screen(cols: 138)

  @app.render

  title_row = @app.instance_variable_get(:@screen).instance_variable_get(:@back)[0].map(&:ch).join
  assert_operator title_row.index('Tracks'), :<, title_row.index('Now Playing')
  assert_operator title_row.index('Now Playing'), :<, title_row.index('Queued')
end

def test_queued_has_priority_when_dedicated_artwork_does_not_fit
  select_library_kind(:folder)
  @app.instance_variable_set(:@art_mode, :pane)
  use_screen(cols: 108)

  @app.render

  title_row = @app.instance_variable_get(:@screen).instance_variable_get(:@back)[0].map(&:ch).join
  assert_includes title_row, 'Queued'
  refute_includes title_row, 'Now Playing'
end

def test_corner_art_stays_out_of_queued_column
  select_library_kind(:folder)
  @app.instance_variable_set(:@art_mode, :corner)
  use_screen(cols: 120)

  @app.render

  region = art_region
  queued_x = 120 - 36
  assert_operator region[:x] + region[:w], :<=, queued_x
end
```

Update the existing `test_pane_mode_reserves_right_hand_column` case to use the first width where both default side panes fit:

```ruby
use_screen(cols: 138)
@app.render

region = art_region
art_w = 30
queued_w = 36
assert_equal 138 - queued_w - art_w + 1, region[:x]
assert_equal 1, region[:y]
```

- [ ] **Step 3: Run rendering and queue tests and verify layout failures**

Run:

```bash
mise exec -- bundle exec ruby -Itest test/app_rendering_theme_config_test.rb
mise exec -- bundle exec ruby -Itest test/app_playback_queue_test.rb
```

Expected: FAIL because the current renderer only allocates Library, Tracks, and optional artwork.

- [ ] **Step 4: Reserve Queued before optional dedicated artwork**

Replace the wide-layout allocation in `render_panes` with this order:

```ruby
queued_cols = queued_pane_cols(cols)
without_queued = cols - queued_cols
art_cols = @art_mode == :pane ? art_pane_cols(without_queued) : 0
usable = without_queued - art_cols
lib_w = usable * @config['ui', 'library_pane_percent'] / 100
tracks_w = usable - lib_w
inset_h = @art_mode == :inset ? art_inset_rows(lib_w, content_h) : 0
```

Keep existing Library and Tracks drawing at `0...usable`. Render optional art after them, but constrain corner placement to `without_queued`:

```ruby
if inset_h.positive?
  @art_region = { x: 1, y: content_h - 1 - inset_h, w: lib_w - 2, h: inset_h }
elsif art_cols.positive?
  render_art_pane(usable, art_cols, content_h)
elsif @art_mode == :corner
  place_art_corner(without_queued, content_h)
end
```

Draw Queued last in the persistent pane layer:

```ruby
if queued_cols.positive?
  queued_x = cols - queued_cols
  draw_box(queued_x, 0, queued_cols, content_h, active: false, title: 'Queued')
  @queued_pane.render(
    @screen, x: queued_x + 1, y: 1,
    w: queued_cols - 2, h: content_h - 2, theme: @theme
  )
end
```

Continue calling `render_art_placeholder` after regions are established. Modals still render after all panes in `App#render`, preserving last-writer-wins z-order.

- [ ] **Step 5: Add queue-view regression assertions**

In `test/app_playback_queue_test.rb`, extend the existing removal and sorting cases to render at 140 columns while the top-level queue is selected, then assert only the interactive Tracks queue is present and removal still targets its selected row:

```ruby
use_screen(cols: 140)
@app.render
title_row = @app.instance_variable_get(:@screen).instance_variable_get(:@back)[0].map(&:ch).join

assert_equal 1, title_row.scan('Playback Queue').size
refute_includes title_row, 'Queued'
```

Do not route `x`, arrows, Tab, or filters into QueuedPane.

- [ ] **Step 6: Run all UI-focused tests**

Run:

```bash
mise exec -- bundle exec ruby -Itest test/list_row_renderer_test.rb
mise exec -- bundle exec ruby -Itest test/queued_pane_test.rb
mise exec -- bundle exec ruby -Itest test/tracks_pane_test.rb
mise exec -- bundle exec ruby -Itest test/app_playback_queue_test.rb
mise exec -- bundle exec ruby -Itest test/app_rendering_theme_config_test.rb
mise exec -- bundle exec ruby -Itest test/bottom_lines_test.rb
```

Expected: all files PASS.

---

### Task 7: Document, Record Durable Memory, Verify, and Commit

**Files:**

- Modify: `README.md:35-55,118-126,196-226`
- Modify: `examples/config.rb:13-52`
- Modify: `AGENTS.md` under `Gotchas` or `Refactor seams`
- Verify: all feature files from Tasks 1-6

**Interfaces:**

- Consumes: final settings, key, thresholds, pane order, files, and tested behavior.
- Produces: current user documentation, future-agent memory, one verified implementation commit.

- [ ] **Step 1: Update README navigation and file map**

Add navigation copy stating:

```markdown
- Wide terminals show a read-only **Queued** pane with upcoming tracks and the
  three latest playback-history entries. Press `B` to toggle it. It hides when
  the terminal cannot retain 72 columns for Library + Tracks and while the
  top-level **Playback Queue** view is selected.
```

Add file-map rows for `list_row_renderer.rb` and `queued_pane.rb`. Describe `TracksPane` as delegating shared individual-track drawing while retaining interaction and queue identity.

- [ ] **Step 2: Update README configuration behavior and settings table**

State that Queued preference uses its own managed block and hot reload applies its preference, width, and formatter. Add exact table rows:

```markdown
| `config.ui.format_track_queued` | callable | Queued-pane track formatter. |
| `config.ui.queued_pane` | `true` | Enable the read-only Queued pane when width permits. |
| `config.ui.queued_pane_width` | `36` | Queued pane width; positive integer columns. |
```

- [ ] **Step 3: Update packaged config example**

Add commented common settings:

```ruby
# config.ui.queued_pane = true
# config.ui.queued_pane_width = 36
```

Add a compact formatter example using the exact supported contract:

```ruby
# config.ui.format_track_queued = lambda do |track, fmt|
#   fmt.line(
#     fmt.text(track.title, bold: true),
#     fmt.duration(track.duration_ms, fg: :text_muted),
#     fmt.text(track.artist, italic: true)
#   )
# end
```

- [ ] **Step 4: Record durable memory without duplicating existing guidance**

Add one concise `AGENTS.md` gotcha after managed config persistence:

```markdown
- Queued-pane preference and effective visibility are separate: narrow width or
  the top-level Playback Queue hides it without persisting `false`. Reserve
  Queued width before optional dedicated artwork; neither pane receives focus.
```

Before adding it, compare with current `Architecture invariants`, `Gotchas`, and `Refactor seams`; merge into an existing statement if later edits already cover the same rule.

- [ ] **Step 5: Run format and whitespace checks**

Run:

```bash
git diff --check
mise exec -- bundle exec rubocop lib/rubyplayer/config.rb lib/rubyplayer/config_dsl.rb lib/rubyplayer/keymap.rb lib/rubyplayer/playback_engine.rb lib/rubyplayer/ui/list_row_renderer.rb lib/rubyplayer/ui/queued_pane.rb lib/rubyplayer/ui/tracks_pane.rb lib/rubyplayer/ui/app.rb lib/rubyplayer/ui/bottom_lines.rb test/list_row_renderer_test.rb test/queued_pane_test.rb test/config_test.rb test/keymap_test.rb test/playback_engine_test.rb test/tracks_pane_test.rb test/app_playback_queue_test.rb test/app_rendering_theme_config_test.rb test/bottom_lines_test.rb
```

Expected: no whitespace errors and RuboCop exits 0. If the repository's current RuboCop baseline reports pre-existing offenses in touched files, record exact output and fix only offenses introduced by this feature.

- [ ] **Step 6: Run the full test suite**

Run:

```bash
mise exec -- bundle exec rake test
```

Expected: all tests PASS with zero failures and zero errors. The rake prerequisite handles the native shim; no separate compile is necessary unless the suite reports a native build failure.

- [ ] **Step 7: Inspect final scope and preserve unrelated work**

Run:

```bash
git status --short
git diff --stat
git diff -- . ':!docs/superpowers/specs/2026-08-01-queued-pane-design.md' ':!docs/superpowers/plans/2026-08-01-queued-pane.md'
```

Expected: `.githooks/pre-commit` remains modified but unstaged and unchanged by this work. Review every feature diff for queue ordering, top-level suppression, persistence separation, and idle-render guarantees.

- [ ] **Step 8: Stage only implementation, tests, docs, and memory**

Run one explicit `git add` command listing only these paths:

```bash
git add AGENTS.md README.md examples/config.rb lib/rubyplayer.rb lib/rubyplayer/config.rb lib/rubyplayer/config_dsl.rb lib/rubyplayer/keymap.rb lib/rubyplayer/playback_engine.rb lib/rubyplayer/ui/app.rb lib/rubyplayer/ui/bottom_lines.rb lib/rubyplayer/ui/list_row_renderer.rb lib/rubyplayer/ui/queued_pane.rb lib/rubyplayer/ui/tracks_pane.rb test/app_playback_queue_test.rb test/app_rendering_theme_config_test.rb test/bottom_lines_test.rb test/config_test.rb test/keymap_test.rb test/list_row_renderer_test.rb test/playback_engine_test.rb test/queued_pane_test.rb test/tracks_pane_test.rb
```

Do not stage `.githooks/pre-commit`.

- [ ] **Step 9: Verify the staged patch and create the single feature commit**

Run:

```bash
git diff --cached --check
git diff --cached --stat
git status --short
git commit -m "feat(ui): add persistent queued pane"
```

Expected: staged patch contains only Queued feature implementation, tests, README/config example, and durable AGENTS memory. Commit succeeds; `.githooks/pre-commit` remains the user's unstaged modification.
