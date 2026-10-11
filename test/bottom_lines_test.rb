require 'test_helper'
require 'stringio'

class BottomLinesTest < Minitest::Test
  def screen = @screen ||= RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 3, cols: 60)
  def glyphs = RubyPlayer::DEFAULTS['glyphs']
  def theme = RubyPlayer::Theme::DEFAULT

  def track = RubyPlayer::Track.new(title: 'Flash Man', artist: 'Capcom', duration_ms: 120_000)

  def test_playback_line_playing
    line = RubyPlayer::UI::PlaybackLine.new(glyphs: glyphs)
    state = { track: track, playing: true, paused: false, position_ms: 65_000 }
    line.render(screen, row: 0, w: 60, state: state, levels: [0.0, 0.5, 1.0], theme: theme)
    out = screen.flush

    assert_includes out, 'Flash Man'
    assert_includes out, '1:05/2:00'
    assert_includes out, glyphs['eq_chars'][-1] # full-level bar char present
  end

  def test_playback_line_uses_unknown_duration_placeholder
    line = RubyPlayer::UI::PlaybackLine.new(glyphs: glyphs)
    unknown_track = RubyPlayer::Track.new(title: 'Unknown', duration_ms: nil)
    state = { track: unknown_track, playing: true, paused: false, position_ms: nil }

    line.render(screen, row: 0, w: 60, state: state, levels: [], theme: theme)

    assert_includes screen.flush, '?:??/?:??'
  end

  def test_playback_line_shows_next_track_while_playing
    line = RubyPlayer::UI::PlaybackLine.new(glyphs: glyphs)
    next_track = RubyPlayer::Track.new(title: 'Bubble Man')
    state = { track: track, next_track: next_track, playing: true, paused: false,
              position_ms: 65_000, focus_sound: nil }

    line.render(screen, row: 0, w: 60, state: state, levels: [], theme: theme)

    assert_includes screen.flush, 'Next: Bubble Man'
  end

  def test_playback_line_shows_focus_and_paused_queue
    line = RubyPlayer::UI::PlaybackLine.new(glyphs: glyphs)
    sound = RubyPlayer::FocusSounds::ALL.first
    next_track = RubyPlayer::Track.new(title: 'Bubble Man')
    state = { track: nil, next_track: next_track, focus_sound: sound,
              playing: false, paused: false, position_ms: 0 }

    line.render(screen, row: 0, w: 60, state: state, levels: [], theme: theme)
    out = screen.flush

    assert_includes out, 'Focus'
    assert_includes out, sound.title
    assert_includes out, '∞'
    assert_includes out, 'Queue paused'
    assert_includes out, 'Next: Bubble Man'
  end

  def test_playback_line_shows_queued_next_when_stopped
    line = RubyPlayer::UI::PlaybackLine.new(glyphs: glyphs)
    next_track = RubyPlayer::Track.new(title: 'Bubble Man')
    state = { track: nil, next_track: next_track, focus_sound: nil,
              playing: false, paused: false, position_ms: 0 }

    line.render(screen, row: 0, w: 60, state: state, levels: [], theme: theme)

    assert_includes screen.flush, 'stopped · Next: Bubble Man'
  end

  def test_playback_line_truncates_context_before_eq_bars
    line = RubyPlayer::UI::PlaybackLine.new(glyphs: glyphs)
    narrow = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 3, cols: 24)
    next_track = RubyPlayer::Track.new(title: 'A Very Long Upcoming Track')
    state = { track: track, next_track: next_track, focus_sound: nil,
              playing: true, paused: false, position_ms: 65_000 }

    line.render(narrow, row: 0, w: 24, state: state, levels: [1.0, 1.0], theme: theme)
    back = narrow.instance_variable_get(:@back)[0].map(&:ch).join

    assert_equal 24, back.size
    assert_equal glyphs['eq_chars'][-1] * 2, back[-2, 2]
  end

  def test_playback_line_stopped
    line = RubyPlayer::UI::PlaybackLine.new(glyphs: glyphs)
    line.render(screen, row: 0, w: 60,
                        state: { track: nil, playing: false, paused: false, position_ms: 0 },
                        levels: [], theme: theme)

    assert_includes screen.flush, 'stopped'
  end

  def test_status_line_message_expires
    now = [100.0]
    line = RubyPlayer::UI::StatusLine.new(seconds: 5, clock: -> { now[0] })
    line.set_message('45 tracks enqueued')

    before_screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 3, cols: 60)
    line.render(before_screen, row: 1, w: 60, default: '3 folders', theme: theme)

    assert_includes before_screen.flush, '45 tracks enqueued'

    now[0] = 106.0
    after_screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 3, cols: 60)
    line.render(after_screen, row: 1, w: 60, default: '3 folders', theme: theme)
    out = after_screen.flush

    assert_includes out, '3 folders'
    refute_includes out, 'enqueued'
  end

  def hotkey_rows(pane: :tracks, width: 160, keymap: RubyPlayer::Keymap.new, toggle_states: {})
    output = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 4, cols: width)
    RubyPlayer::UI::HotkeyLine.new(keymap: keymap).render(output, row: 1, w: width, pane: pane,
                                                                  theme: theme, toggle_states: toggle_states)
    output.instance_variable_get(:@back).drop(1)
  end

  def test_hotkeys_have_stable_categories_and_logical_separators
    play, queue, view = hotkey_rows.map { |row| row.map(&:ch).join.rstrip }

    assert_match(/^PLAY /, play)
    assert_includes play, '<:restart/prev'
    assert_includes play, '>:next'
    assert_includes play, ' │ '
    assert_match(/^QUEUE /, queue)
    assert_includes queue, 'Q:queue next'
    assert_includes queue, '^R:redo'
    assert_match(/^VIEW /, view)
    assert_includes view, 'G:group'
    assert_includes view, 'E:year'
    assert view.end_with?('?:help')
  end

  def test_hotkey_keys_and_colons_are_bold_while_descriptions_are_dim
    rows = hotkey_rows
    queue = rows[1]
    index = queue.map(&:ch).join.index('X:remove')

    refute_nil index
    assert queue[index, 2].all?(&:bold)
    refute queue[index, 2].any?(&:dim)
    assert queue[index + 2, 6].all?(&:dim)
    refute queue[index + 2, 6].any?(&:bold)
    assert rows[0][0, 4].all?(&:italic)
  end

  def test_hotkey_context_changes_without_moving_playback_or_queue_rows
    tracks = hotkey_rows.map { |row| row.map(&:ch).join }
    library = hotkey_rows(pane: :library).map { |row| row.map(&:ch).join }
    queued = hotkey_rows(pane: :queued).map { |row| row.map(&:ch).join }

    assert_equal tracks[0], library[0]
    assert_equal tracks[0], queued[0]
    assert_match(/^QUEUE /, library[1])
    refute_includes library[1], 'X:remove'
    assert_match(/^LIBRARY /, library[2])
    assert_includes library[2], 'X:remove'
    assert_includes library[2], 'R:rename'
    refute_includes queued[2], 'G:group'
  end

  def test_narrow_footer_shortens_labels_and_keeps_help_at_right_edge
    play, queue, view = hotkey_rows(width: 60).map { |row| row.map(&:ch).join }

    assert_includes play, '<:prev/start'
    assert_includes play, ']:fwd'
    assert_includes queue, 'Q:next'
    assert_includes queue, 'N:last'
    assert_includes view, 'I:info'
    assert_equal '?:help', view[-6, 6]
    refute_includes view, 'Y:title'
  end

  def test_help_reserves_space_even_in_a_very_narrow_footer
    view = hotkey_rows(width: 20).last.map(&:ch).join

    assert_match(/^VIEW /, view)
    assert_equal '?:help', view[-6, 6]
    refute_includes view, 'Tab:'
  end

  def test_footer_uses_effective_remapped_keys_including_help
    map = RubyPlayer::Keymap.new('global' => { 'ctrl_p' => 'toggle_play', 'space' => 'show_help',
                                               '?' => 'quit', 'ctrl_h' => 'show_help' },
                                 'tracks' => { 'x' => 'show_track_info' })
    play, queue, view = hotkey_rows(keymap: map).map { |row| row.map(&:ch).join.rstrip }

    assert_includes play, '^P:pause'
    refute_includes play, 'Space:pause'
    refute_includes queue, 'X:remove'
    assert_includes view, 'X:info'
    assert view.end_with?('^H:help')
    refute_includes view, '?:help'
  end

  def test_queued_pane_binding_has_human_label
    labels = RubyPlayer::UI::HotkeyLine::LABELS

    assert_equal 'queue bar', labels[:toggle_queued_pane]
  end

  def test_feature_toggle_labels_show_current_state_without_decorating_transport
    [false, true].each do |enabled|
      rows = hotkey_rows(toggle_states: { toggle_skip_disliked: enabled, toggle_group: enabled })
      play, _, view = rows.map { |row| row.map(&:ch).join }
      suffix = enabled ? '(on)' : '(off)'

      assert_includes play, "S:skip disliked #{suffix}"
      assert_includes view, "G:group #{suffix}"
      assert_includes play, 'Space:pause  '
      index = play.index("skip disliked #{suffix}")

      assert rows[0][index, "skip disliked #{suffix}".size].all?(&:dim)
    end
  end

  def test_compact_toggle_labels_keep_the_state_and_help_anchor
    play, _, view = hotkey_rows(width: 99, toggle_states: { toggle_skip_disliked: true })
                    .map { |row| row.map(&:ch).join }

    assert_includes play, 'S:skip1 (on)'
    assert_includes view, 'G:group (off)'
    assert_equal '?:help', view[-6, 6]
  end
end
