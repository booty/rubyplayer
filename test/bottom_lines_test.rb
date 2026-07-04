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
end
