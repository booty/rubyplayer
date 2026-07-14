require "test_helper"
require "stringio"

class BottomLinesTest < Minitest::Test
  def screen = @screen ||= RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 3, cols: 60)
  def glyphs = RubyPlayer::DEFAULTS["glyphs"]
  def theme = RubyPlayer::Theme::DEFAULT

  def track = RubyPlayer::Track.new(title: "Flash Man", artist: "Capcom", duration_ms: 120_000)

  def test_playback_line_playing
    line = RubyPlayer::UI::PlaybackLine.new(glyphs: glyphs)
    state = { track: track, playing: true, paused: false, position_ms: 65_000 }
    line.render(screen, row: 0, w: 60, state: state, levels: [0.0, 0.5, 1.0], theme: theme)
    out = screen.flush
    assert_includes out, "Flash Man"
    assert_includes out, "1:05/2:00"
    assert_includes out, glyphs["eq_chars"][-1] # full-level bar char present
  end

  def test_playback_line_shows_next_track_while_playing
    line = RubyPlayer::UI::PlaybackLine.new(glyphs: glyphs)
    next_track = RubyPlayer::Track.new(title: "Bubble Man")
    state = { track: track, next_track: next_track, playing: true, paused: false,
              position_ms: 65_000, focus_sound: nil }

    line.render(screen, row: 0, w: 60, state: state, levels: [], theme: theme)

    assert_includes screen.flush, "Next: Bubble Man"
  end

  def test_playback_line_shows_focus_and_paused_queue
    line = RubyPlayer::UI::PlaybackLine.new(glyphs: glyphs)
    sound = RubyPlayer::FocusSounds::ALL.first
    next_track = RubyPlayer::Track.new(title: "Bubble Man")
    state = { track: nil, next_track: next_track, focus_sound: sound,
              playing: false, paused: false, position_ms: 0 }

    line.render(screen, row: 0, w: 60, state: state, levels: [], theme: theme)
    out = screen.flush

    assert_includes out, "Focus"
    assert_includes out, sound.title
    assert_includes out, "∞"
    assert_includes out, "Queue paused"
    assert_includes out, "Next: Bubble Man"
  end

  def test_playback_line_shows_queued_next_when_stopped
    line = RubyPlayer::UI::PlaybackLine.new(glyphs: glyphs)
    next_track = RubyPlayer::Track.new(title: "Bubble Man")
    state = { track: nil, next_track: next_track, focus_sound: nil,
              playing: false, paused: false, position_ms: 0 }

    line.render(screen, row: 0, w: 60, state: state, levels: [], theme: theme)

    assert_includes screen.flush, "stopped · Next: Bubble Man"
  end

  def test_playback_line_truncates_context_before_eq_bars
    line = RubyPlayer::UI::PlaybackLine.new(glyphs: glyphs)
    narrow = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 3, cols: 24)
    next_track = RubyPlayer::Track.new(title: "A Very Long Upcoming Track")
    state = { track: track, next_track: next_track, focus_sound: nil,
              playing: true, paused: false, position_ms: 65_000 }

    line.render(narrow, row: 0, w: 24, state: state, levels: [1.0, 1.0], theme: theme)
    back = narrow.instance_variable_get(:@back)[0].map(&:ch).join

    assert_equal 24, back.size
    assert_equal glyphs["eq_chars"][-1] * 2, back[-2, 2]
  end

  def test_playback_line_stopped
    line = RubyPlayer::UI::PlaybackLine.new(glyphs: glyphs)
    line.render(screen, row: 0, w: 60,
                state: { track: nil, playing: false, paused: false, position_ms: 0 },
                levels: [], theme: theme)
    assert_includes screen.flush, "stopped"
  end

  def test_status_line_message_expires
    now = [100.0]
    line = RubyPlayer::UI::StatusLine.new(seconds: 5, clock: -> { now[0] })
    line.set_message("45 tracks enqueued")

    before_screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 3, cols: 60)
    line.render(before_screen, row: 1, w: 60, default: "3 folders", theme: theme)
    assert_includes before_screen.flush, "45 tracks enqueued"

    now[0] = 106.0
    after_screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 3, cols: 60)
    line.render(after_screen, row: 1, w: 60, default: "3 folders", theme: theme)
    out = after_screen.flush
    assert_includes out, "3 folders"
    refute_includes out, "enqueued"
  end

  def test_hotkey_line_lists_pane_bindings
    line = RubyPlayer::UI::HotkeyLine.new(keymap: RubyPlayer::Keymap.new)
    line.render(screen, row: 2, w: 60, pane: :tracks, theme: theme)
    out = screen.flush
    assert_includes out, "G:group"
  end

  def test_hotkey_line_wraps_whole_pairs_across_h_rows
    line = RubyPlayer::UI::HotkeyLine.new(keymap: RubyPlayer::Keymap.new)
    wide = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 4, cols: 60)
    line.render(wide, row: 1, w: 60, h: 2, pane: :tracks, theme: theme)
    back = wide.instance_variable_get(:@back)
    row1 = back[1].map(&:ch).join.rstrip
    row2 = back[2].map(&:ch).join.rstrip
    # two rows hold more than one 60-col row could
    refute_empty row2
    assert_operator (row1 + row2).size, :>, 60
    # pairs wrap whole: no row ends or starts mid-pair
    # pairs are joined by exactly two spaces; labels themselves may contain
    # single spaces ("play now"), so only the double-space is a separator
    all_pairs = "#{row1}  #{row2}".split("  ")
    assert_includes all_pairs, "G:group"
    assert(all_pairs.all? { |p| p.include?(":") }, "broken pair in #{all_pairs.inspect}")
  end

  def test_hotkey_line_defaults_to_one_row
    line = RubyPlayer::UI::HotkeyLine.new(keymap: RubyPlayer::Keymap.new)
    wide = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 4, cols: 60)
    line.render(wide, row: 1, w: 60, pane: :tracks, theme: theme)
    back = wide.instance_variable_get(:@back)
    assert_empty back[2].map(&:ch).join.rstrip
  end
end
