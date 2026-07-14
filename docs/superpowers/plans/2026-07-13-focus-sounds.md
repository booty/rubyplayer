# Focus Sounds Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an infinite, SoX-backed Focus sound catalog selectable from the Library pane without adding sounds to the playback queue.

**Architecture:** Focus sounds are immutable in-memory values, rendered by a dedicated Tracks pane mode. `FocusPlayer` owns a direct `play` child process in its own process group. The app stops queue playback before starting Focus, and stops Focus before normal playback begins; queue contents remain unchanged.

**Tech Stack:** Ruby 4, Minitest, Process.spawn/kill/waitpid, SoX `play`, existing terminal UI and miniaudio output.

## Global Constraints

- Catalog contains exactly: Green, Rain, Fan, Brown, Beach Rain, Beach Rain (Dark), in that order.
- Preserve given recipe arguments exactly; invoke `play` with argument arrays, never a shell command string.
- Focus entries never enter `PlayQueue`, SQLite, ratings, or playback history.
- Focus entries run until stopped; normal playback replaces Focus and Focus replaces normal playback.
- `PlaybackEngine#stop` must preserve queue order and items.
- Tests must inject process functions; never require installed SoX or an audio device.
- Do not commit changes unless user explicitly asks.

---

### Task 1: Focus catalog and process lifecycle

**Files:**
- Create: `lib/rubyplayer/focus_sounds.rb`
- Create: `lib/rubyplayer/focus_player.rb`
- Modify: `lib/rubyplayer.rb`
- Test: `test/focus_sounds_test.rb`
- Test: `test/focus_player_test.rb`

**Interfaces:**
- Produces `RubyPlayer::FocusSound` with readers `id`, `title`, and `sox_args`.
- Produces `RubyPlayer::FocusSounds::ALL`, frozen ordered catalog of six `FocusSound` values.
- Produces `RubyPlayer::FocusPlayer#play(sound)`, `#stop`, `#playing?`, and `#current`.
- `FocusPlayer.new(spawn:, kill:, waitpid:, clock:, sleeper:)` accepts injectable process functions and defaults to `Process`/monotonic-clock behavior.

- [ ] **Step 1: Write catalog test first**

```ruby
class FocusSoundsTest < Minitest::Test
  def test_catalog_has_ordered_titles_and_green_recipe
    assert_equal ["Green", "Rain", "Fan", "Brown", "Beach Rain", "Beach Rain (Dark)"],
                 RubyPlayer::FocusSounds::ALL.map(&:title)
    assert_equal ["-n", "synth", "pinknoise", "highpass", "120", "lowpass", "2500",
                  "equalizer", "500", "1.0q", "+3", "equalizer", "1000", "1.0q", "+2",
                  "tremolo", "0.08", "12", "gain", "-12"],
                 RubyPlayer::FocusSounds::ALL.first.sox_args
  end
end
```

- [ ] **Step 2: Run catalog test; verify RED**

Run: `mise exec -- bundle exec ruby -Itest test/focus_sounds_test.rb`

Expected: failure because `RubyPlayer::FocusSounds` is undefined.

- [ ] **Step 3: Implement immutable catalog**

```ruby
module RubyPlayer
  FocusSound = Struct.new(:id, :title, :sox_args, keyword_init: true)

  module FocusSounds
    ALL = [
      FocusSound.new(id: :green, title: "Green", sox_args: ["-n", "synth", "pinknoise", "highpass", "120", "lowpass", "2500", "equalizer", "500", "1.0q", "+3", "equalizer", "1000", "1.0q", "+2", "tremolo", "0.08", "12", "gain", "-12"].freeze).freeze,
      FocusSound.new(id: :rain, title: "Rain", sox_args: ["-n", "synth", "pinknoise", "highpass", "300", "lowpass", "7000", "equalizer", "1600", "0.7q", "+3", "equalizer", "3500", "1.0q", "+2", "tremolo", "0.08", "12", "gain", "-15"].freeze).freeze,
      FocusSound.new(id: :fan, title: "Fan", sox_args: ["-n", "synth", "brownnoise", "highpass", "45", "lowpass", "1800", "equalizer", "120", "0.7q", "+4", "equalizer", "240", "0.8q", "+2", "equalizer", "900", "1.0q", "-2", "tremolo", "0.08", "12", "gain", "-11"].freeze).freeze,
      FocusSound.new(id: :brown, title: "Brown", sox_args: ["-n", "synth", "brownnoise", "highpass", "40", "lowpass", "1000", "tremolo", "0.08", "12", "gain", "-12"].freeze).freeze,
      FocusSound.new(id: :beach_rain, title: "Beach Rain", sox_args: ["-n", "synth", "pinknoise", "highpass", "80", "lowpass", "4500", "equalizer", "180", "0.8q", "+4", "equalizer", "650", "0.9q", "+3", "equalizer", "2500", "1.0q", "-3", "tremolo", "0.08", "45", "reverb", "35", "50", "60", "40", "0", "0", "gain", "-9"].freeze).freeze,
      FocusSound.new(id: :beach_rain_dark, title: "Beach Rain (Dark)", sox_args: ["-n", "synth", "brownnoise", "highpass", "45", "lowpass", "3000", "equalizer", "120", "0.8q", "+4", "equalizer", "500", "1.0q", "+2", "equalizer", "1800", "1.0q", "-2", "tremolo", "0.055", "38", "reverb", "30", "45", "55", "35", "0", "0", "gain", "-11"].freeze).freeze,
    ].freeze
  end
end
```

Add `require_relative "rubyplayer/focus_sounds"` to `lib/rubyplayer.rb` before UI files.

- [ ] **Step 4: Run catalog test; verify GREEN**

Run: `mise exec -- bundle exec ruby -Itest test/focus_sounds_test.rb`

Expected: catalog test passes with zero failures and errors.

- [ ] **Step 5: Write lifecycle tests first**

```ruby
def player(spawn:, kill: ->(*) {}, waitpid: ->(*) { 1 },
           clock: -> { 0.0 }, sleeper: ->(_) {})
  FocusPlayer.new(spawn: spawn, kill: kill, waitpid: waitpid,
                  clock: clock, sleeper: sleeper)
end

def test_play_spawns_play_in_its_own_process_group
  calls = []
  player = player(spawn: ->(*args, **opts) { calls << [args, opts]; 42 })
  player.play(FocusSounds::ALL.first)

  assert_equal [["play", *FocusSounds::ALL.first.sox_args], { pgroup: true }], calls.first
  assert player.playing?
  assert_equal FocusSounds::ALL.first, player.current
end

def test_play_replaces_and_stops_current_sound
  killed = []
  pids = [42, 43]
  player = player(spawn: ->(*) { pids.shift }, kill: ->(*args) { killed << args })
  player.play(FocusSounds::ALL.first)
  player.play(FocusSounds::ALL[1])

  assert_includes killed, ["TERM", -42]
  assert_equal FocusSounds::ALL[1], player.current
end

def test_stop_kills_process_group_when_term_does_not_exit
  killed = []
  times = [0.0, 0.0, 1.1]
  player = player(spawn: ->(*) { 42 }, kill: ->(*args) { killed << args },
                  waitpid: ->(*) { nil }, clock: -> { times.shift || 1.1 })
  player.play(FocusSounds::ALL.first)
  player.stop

  assert_includes killed, ["TERM", -42]
  assert_includes killed, ["KILL", -42]
  refute player.playing?
  assert_nil player.current
end

def test_play_reports_missing_sox
  player = player(spawn: ->(*) { raise Errno::ENOENT })

  error = assert_raises(FocusPlayer::Error) { player.play(FocusSounds::ALL.first) }
  assert_equal "sox play executable not found", error.message
end
```

- [ ] **Step 6: Run lifecycle tests; verify RED**

Run: `mise exec -- bundle exec ruby -Itest test/focus_player_test.rb`

Expected: failure because `RubyPlayer::FocusPlayer` is undefined.

- [ ] **Step 7: Implement `FocusPlayer`**

```ruby
class FocusPlayer
  class Error < StandardError; end

  def initialize(spawn: Process.method(:spawn), kill: Process.method(:kill),
                 waitpid: Process.method(:waitpid),
                 clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                 sleeper: Kernel.method(:sleep))
    @spawn, @kill, @waitpid, @clock, @sleeper = spawn, kill, waitpid, clock, sleeper
  end

  def play(sound)
    stop
    @pid = @spawn.call("play", *sound.sox_args, pgroup: true)
    @current = sound
    true
  rescue Errno::ENOENT
    raise Error, "sox play executable not found"
  end
end
```

Implement `stop` by clearing `@pid`/`@current`, sending `TERM` to negative PID, polling `waitpid(pid, Process::WNOHANG)` for up to one second, then sending `KILL` and reaping only when still alive. Treat `Errno::ESRCH` and `Errno::ECHILD` as already stopped. `playing?` returns whether `@pid` exists; `current` returns `@current`. Add `require_relative "rubyplayer/focus_player"` after catalog require.

- [ ] **Step 8: Run new tests; verify GREEN**

Run: `mise exec -- bundle exec ruby -Itest test/focus_sounds_test.rb test/focus_player_test.rb`

Expected: all Focus catalog and process lifecycle tests pass without SoX installed.

### Task 2: Add Focus Library and Tracks pane modes

**Files:**
- Modify: `lib/rubyplayer/ui/library_pane.rb`
- Modify: `lib/rubyplayer/ui/tracks_pane.rb`
- Test: `test/library_pane_test.rb`
- Test: `test/tracks_pane_test.rb`

**Interfaces:**
- `LibraryPane::SPECIALS` includes `[:focus, "Focus"]` immediately after favorites.
- `TracksPane.new(library:, config:, queue_source:, focus_source:)` accepts `focus_source`, a callable returning `FocusSound` values.
- `TracksPane#selected_focus_sound` returns selected `FocusSound` only in `:focus` mode; otherwise `nil`.

- [ ] **Step 1: Write pane tests first**

```ruby
def test_specials_include_focus_after_favorites
  assert_equal %i[queue history favorites focus folder], kinds
  assert_equal :focus, @pane.rows[3].kind
end

def test_focus_view_lists_catalog_in_declared_order
  focus = RubyPlayer::FocusSounds::ALL
  pane = RubyPlayer::UI::TracksPane.new(library: @lib, config: @config,
                                        queue_source: -> { [] }, focus_source: -> { focus })
  pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :focus, depth: 0))

  assert_equal focus.map(&:title), pane.display_rows.map { |row| row[:text] }
  assert_equal focus.first, pane.selected_focus_sound
end
```

Add tests proving `selected_track` is `nil` in Focus mode, `toggle_group` and sort actions do not reorder Focus, and navigation changes `selected_focus_sound`.

- [ ] **Step 2: Run pane tests; verify RED**

Run: `mise exec -- bundle exec ruby -Itest test/library_pane_test.rb test/tracks_pane_test.rb`

Expected: failures because `:focus` and `focus_source:` do not exist.

- [ ] **Step 3: Implement special rows and Focus row rendering**

```ruby
SPECIALS = [
  [:queue, "Playback Queue"],
  [:history, "History"],
  [:favorites, "Favorite Tracks"],
  [:focus, "Focus"],
].freeze

def focus_rows
  @focus_source.call.map do |sound|
    { type: :focus, text: sound.title,
      segments: [{ text: sound.title, field: "title" }], focus_sound: sound }
  end
end

def selected_focus_sound
  row = display_rows[@selection]
  row && row[:type] == :focus ? row[:focus_sound] : nil
end
```

Render `:focus` rows through existing `render_track_row`, so selected and unselected colors match normal tracks. In `reload!`, choose `@focus_source.call` for `:focus`; use `focus_rows` for `display_rows`; make sort/group actions no-ops and preserve declared order in Focus mode. Add `when :focus then ["#{@glyphs['playlist']} Focus", ""]` to `LibraryPane#label_for`.

- [ ] **Step 4: Run pane tests; verify GREEN**

Run: `mise exec -- bundle exec ruby -Itest test/library_pane_test.rb test/tracks_pane_test.rb`

Expected: all existing pane tests and new Focus pane tests pass.

### Task 3: Stop queue playback without mutating queue

**Files:**
- Modify: `lib/rubyplayer/playback_engine.rb`
- Test: `test/playback_engine_test.rb`

**Interfaces:**
- Produces `PlaybackEngine#stop`, an asynchronous command that ends current decoding/audio but does not call `PlayQueue#advance!`.

- [ ] **Step 1: Write engine test first**

```ruby
def test_stop_ends_playback_without_advancing_queue
  first = make_track("shantae.gbs")
  second = make_track("shantae.gbs", subtune: 1)
  @engine.enqueue_now([first, second])
  wait_for_event(:track_started)

  @engine.stop
  wait_for { !@engine.state[:playing] }

  assert_equal [first.id, second.id], @engine.queue_items.map(&:id)
  assert_nil @engine.state[:track]
end
```

- [ ] **Step 2: Run engine test; verify RED**

Run: `mise exec -- bundle exec ruby -Itest test/playback_engine_test.rb -n /stop_ends_playback/`

Expected: failure because `PlaybackEngine#stop` is undefined.

- [ ] **Step 3: Implement stop command**

```ruby
def stop = @commands << :stop_playback

# In #run command dispatch:
when :stop_playback then stop_playback
```

Add a private `stop_playback` method that closes the handle, pauses and flushes `AudioOutput`, resets `@current`, `@playing`, and `@paused` under `@mutex`, then publishes `:playback_state`. It must not record history, call `advance!`, or mutate `@queue`.

- [ ] **Step 4: Run engine test; verify GREEN**

Run: `mise exec -- bundle exec ruby -Itest test/playback_engine_test.rb -n /stop_ends_playback/`

Expected: pass with both original track IDs still in the queue.

### Task 4: Wire Focus and normal playback handoff in app

**Files:**
- Modify: `lib/rubyplayer/ui/app.rb`
- Test: `test/app_test.rb`

**Interfaces:**
- `UI::App.new(argv: [], config_path: nil, data_path: nil, null_audio: false, io_out: $stdout, focus_player: nil)` accepts injected `FocusPlayer`; defaults to `FocusPlayer.new`.
- `UI::App#play_focus(sound)` stops engine playback then starts `FocusPlayer`.
- `UI::App#shutdown` stops Focus before closing audio/database.

- [ ] **Step 1: Write app tests first**

```ruby
class FakeFocusPlayer
  attr_reader :played, :stop_calls
  def initialize = (@played = []; @stop_calls = 0)
  def play(sound) = @played << sound
  def stop = (@stop_calls += 1)
end

def select_tracks_for(kind)
  @app.instance_variable_set(:@active_pane, :library)
  20.times { @app.handle_key("up") }
  index = @app.library_pane.rows.index { |row| row.kind == kind }
  index.times { @app.handle_key("down") }
  @app.handle_key("tab")
end

def start_normal_playback
  select_tracks_for(:folder)
  @app.handle_key("enter")
  wait_until { @app.engine.state[:playing] }
end

def test_focus_enter_stops_queue_playback_and_keeps_queue
  start_normal_playback
  queued_ids = @app.engine.queue_items.map(&:id)
  select_tracks_for(:focus)

  @app.handle_key("enter")

  wait_until { !@app.engine.state[:playing] }
  assert_equal [RubyPlayer::FocusSounds::ALL.first], @focus_player.played
  assert_equal queued_ids, @app.engine.queue_items.map(&:id)
end

def test_normal_playback_stops_focus
  select_tracks_for(:focus)
  @app.handle_key("enter")
  select_tracks_for(:folder)

  @app.handle_key("enter")

  assert_operator @focus_player.stop_calls, :>=, 1
end

def test_focus_cannot_be_queued
  select_tracks_for(:focus)
  before = @app.engine.queue_items

  @app.handle_key("q")
  @app.render
  assert_equal before, @app.engine.queue_items
  assert_includes @app.instance_variable_get(:@io_out).string, "Focus sounds cannot be queued"

  @app.handle_key("n")
  assert_equal before, @app.engine.queue_items
end
```

Initialize the app in test setup with `focus_player: @focus_player`.

- [ ] **Step 2: Run app tests; verify RED**

Run: `mise exec -- bundle exec ruby -Itest test/app_test.rb -n '/focus|normal_playback_stops_focus/'`

Expected: failure because app has no Focus player or Focus routing.

- [ ] **Step 3: Implement app wiring**

```ruby
@focus_player = focus_player || FocusPlayer.new
@tracks_pane = TracksPane.new(library: @library, config: @config,
                              queue_source: -> { @engine.queue_items },
                              focus_source: -> { FocusSounds::ALL })

def play_now
  sound = @active_pane == :tracks && @tracks_pane.selected_focus_sound
  return play_focus(sound) if sound
  enqueue(:now)
end

def play_focus(sound)
  @engine.stop
  @focus_player.play(sound)
  @status_line.set_message("Playing focus: #{sound.title}")
rescue FocusPlayer::Error => e
  @status_line.set_message(e.message)
end
```

Route `:play_now` to `play_now`. In `enqueue`, stop Focus before calling any engine enqueue method. In `toggle_play`, stop Focus before sending a normal play/pause command only when engine is not already playing. For Focus selection, reject `:enqueue_front` and `:enqueue_end` with `"Focus sounds cannot be queued"`. `shutdown` calls `@focus_player.stop` before engine/audio/database cleanup. Keep every normal queue action unchanged outside Focus mode.

- [ ] **Step 4: Run app tests; verify GREEN**

Run: `mise exec -- bundle exec ruby -Itest test/app_test.rb`

Expected: all app tests pass, including Focus start/stop and queue-preservation behavior.

### Task 5: Document requirement and run full regression suite

**Files:**
- Modify: `README.md`

**Interfaces:**
- README Requirements states SoX is required for Focus sounds.
- README feature description explains Focus runs six infinite synthesized recipes and remains outside the queue.

- [ ] **Step 1: Update README**

```markdown
- Homebrew: `libgme`, `libopenmpt`, `sox`
```

Add one short Focus paragraph near Running: select `Focus`, enter a sound from Tracks, and start any normal track to stop it. State that Focus sounds are not queued or persisted.

- [ ] **Step 2: Run focused tests**

Run: `mise exec -- bundle exec ruby -Itest test/focus_sounds_test.rb test/focus_player_test.rb test/library_pane_test.rb test/tracks_pane_test.rb test/playback_engine_test.rb test/app_test.rb`

Expected: all focused suites pass with zero failures and errors.

- [ ] **Step 3: Run full regression suite**

Run: `mise exec -- bundle exec rake test`

Expected: native shim compiles if needed, then all Minitest suites pass with zero failures and errors.
