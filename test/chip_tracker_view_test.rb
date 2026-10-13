# frozen_string_literal: true

require 'test_helper'
require 'stringio'
require 'minitest/mock'
require 'rubyplayer/ui/screen'
require 'rubyplayer/vgm/note_log'
require 'rubyplayer/vgm/snapshot'
require 'rubyplayer/ui/chip_tracker_view'

class ChipTrackerViewTest < Minitest::Test
  Vgm = RubyPlayer::Vgm
  THEME = RubyPlayer::Theme::DEFAULT

  def setup
    @view = RubyPlayer::UI::ChipTrackerView.new
  end

  # A note shorter than one row must survive an on/off pair in the same bucket.
  def test_rows_show_short_notes_pitch_changes_and_unpitched_starts
    fm = Vgm::NoteLog.new
    fm.on(0, 2_205, 60)
    fm.off(0, 3_000)
    fm.on(1, 4_410, 60)
    fm.note(1, 5_000, 62)
    fm.note(1, 7_000, 64)
    psg = Vgm::NoteLog.new
    psg.on(0, 0, nil, unpitched: :noise)
    @view.update(snapshot(chips: [chip('ym2612:0', 'YM2612', %w[FM1 FM2], fm),
                                  chip('sn76489:0', 'SN76489', ['Noise'], psg)], sample: 8_820))

    text = render(width: 65, height: 12, now_sample: 8_820).join("\n")

    assert_match(/0:00\.05.*C-4!/, text)
    # A note that starts and glides in one row shows both; a later glide-only row has no start.
    assert_match(/0:00\.10 +\.\.\. +C-4>D-4/, text)
    assert_match(/0:00\.15 +\.\.\. +>E-4/, text)
    assert_match(/0:00\.00.*NOI/, text)
    assert_includes text, 'YM2612'
    assert_includes text, 'SN76489'
  end

  def test_channel_window_moves_and_resets_for_new_revision
    notes = Vgm::NoteLog.new
    @view.update(snapshot(chips: [chip('ym2612:0', 'YM2612', %w[FM1 FM2 FM3 FM4], notes)]))
    first = render(width: 32, height: 9).join("\n")

    assert_includes first, 'FM1'
    refute_includes first, 'FM4'
    3.times { assert @view.handle_key('right') }
    moved = render(width: 32, height: 9).join("\n")

    assert_includes moved, 'FM4'
    assert_includes moved, '4/4'
    @view.update(snapshot(chips: [chip('ym2612:0', 'YM2612', %w[FM1 FM2 FM3 FM4], notes)], revision: 2))

    assert_includes render(width: 32, height: 9).join("\n"), 'FM1'
    refute @view.handle_key('up')
  end

  def test_pruned_note_log_keeps_a_held_note_visible_at_its_boundary
    notes = Vgm::NoteLog.new
    notes.on(0, 0, 60)
    notes.on(1, 22 * Vgm::SAMPLE_RATE, 62)
    @view.update(snapshot(chips: [chip('ym2612:0', 'YM2612', %w[FM1 FM2], notes)],
                          sample: 2 * Vgm::SAMPLE_RATE))

    assert_match(/0:02\.00.*C-4/, render(width: 50, height: 10,
                                         now_sample: 2 * Vgm::SAMPLE_RATE).join("\n"))
  end

  def test_status_and_paused_playhead_follow_the_heard_sample
    assert_includes render(width: 50, height: 10).join("\n"), 'Loading'
    @view.update(snapshot(chips: [], status: :ready, message: 'Catching up'))

    assert_includes render(width: 50, height: 10).join("\n"), 'Catching up'

    @view.update(snapshot(chips: [], status: :unsupported, message: 'Chip unavailable'))

    assert_includes render(width: 50, height: 10).join("\n"), 'Chip unavailable'
    @view.update(snapshot(chips: [], status: :error, message: nil))

    assert_includes render(width: 50, height: 10).join("\n"), 'Error'

    @view.update(snapshot(chips: [chip('ym2612:0', 'YM2612', ['FM1'], Vgm::NoteLog.new)]))
    # Pausing stops the heard sample, so the playhead row holds still.
    paused = render(width: 50, height: 10, now_sample: 4_410)

    assert paused.any? { |row| row.include?('0:00.10') }
    assert_equal paused, render(width: 50, height: 10, now_sample: 4_410)
  end

  def test_rendering_stays_inside_its_rectangle
    @view.update(snapshot(chips: [chip('ym2612:0', 'YM2612', ['FM1'], Vgm::NoteLog.new)]))
    [[26, 8], [12, 5]].each do |width, height|
      screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: height + 4, cols: width + 6)
      @view.render(screen, x: 3, y: 2, width: width, height: height, theme: THEME,
                           track_title: 'Song', now_sample: 0)
      screen.instance_variable_get(:@back).each_with_index do |row, row_index|
        row.each_with_index do |cell, column|
          next if row_index.between?(2, height + 1) && column.between?(3, width + 2)

          assert_equal ' ', cell.ch
        end
      end
    end
  end

  # Both VGM pages receive every snapshot; only the page on screen should
  # pay to decode note history.
  def test_note_history_decodes_on_render_not_update
    notes = Vgm::NoteLog.new
    decodes = 0
    decode = Vgm::NoteLog.method(:decode)
    Vgm::NoteLog.stub(:decode, lambda { |packed|
      decodes += 1
      decode.call(packed)
    }) do
      3.times do |index|
        notes.on(0, index * 2_205, 60 + index)
        @view.update(snapshot(chips: [chip('ym2612:0', 'YM2612', ['FM1'], notes)], sample: index * 2_205))
      end

      assert_equal 0, decodes
      text = render(width: 40, height: 10, now_sample: 4_410).join("\n")

      assert_equal 1, decodes
      assert_includes text, 'D-4'
      render(width: 40, height: 10, now_sample: 4_410)

      assert_equal 1, decodes
    end
  end

  def test_title_names_the_source
    view = RubyPlayer::UI::ChipTrackerView.new(source: 'HES')
    view.update(snapshot(chips: [chip('huc6280:0', 'HuC6280 PSG', ['Wave 1'], Vgm::NoteLog.new)]))

    assert_includes render(width: 60, height: 8, view: view).join("\n"), 'Song · HES TRACKER · 0:00.00'
    assert_includes render(width: 60, height: 8).join("\n"), 'VGM TRACKER'
  end

  # Starts without a pitch are labeled by the sound each event recorded,
  # not the voice's current mode: an HES Multi voice switches between wave,
  # noise, and direct DAC.
  def test_unpitched_starts_are_labeled_by_their_recorded_sound
    notes = Vgm::NoteLog.new
    notes.on(0, 0, nil, unpitched: :noise)
    notes.on(1, 0, nil, unpitched: :dac)
    notes.on(2, 0, nil)
    @view.update(snapshot(chips: [chip('huc6280:0', 'HuC6280 PSG', %w[Multi1 Multi2 Other], notes,
                                       kinds: %i[huc_wave huc_wave huc_wave])]))

    assert_match(/0:00\.00 +NOI +DAC +PCM/, render(width: 50, height: 8).join("\n"))
  end

  # A chip's name heads its first visible column and may span its others,
  # but never runs into the next chip's.
  def test_chip_names_head_each_chip_once
    notes = Vgm::NoteLog.new
    @view.update(snapshot(chips: [chip('huc6280:0', 'HuC6280 PSG', %w[W1 W2], notes),
                                  chip('sn76489:0', 'SN76489 PSG LONG NAME', ['T1'], notes)]))
    header = render(width: 60, height: 8)[1]

    assert_equal 1, header.scan('HuC6280 PSG').size
    assert_match(/SN76489 PS HuC6280 PSG/, header)
  end

  # Native chip trackers count now_sample from player launch; the time
  # column shows the track position instead, with rows on its 50 ms grid.
  def test_time_column_follows_the_track_position
    launch_sample = 10 * Vgm::SAMPLE_RATE
    notes = Vgm::NoteLog.new
    notes.on(0, launch_sample - 2_205, 60)
    @view.update(snapshot(chips: [chip('huc6280:0', 'HuC6280 PSG', ['Wave 1'], notes)], sample: launch_sample))
    text = render(width: 40, height: 8, now_sample: launch_sample, position_ms: 2_000).join("\n")

    assert_includes text, 'TRACKER · 0:02.00'
    assert_match(/0:01\.95 +C-4/, text)
    refute_includes text, '0:10'
    # A later render's millisecond rounding must not shift the grid.
    later = render(width: 40, height: 8, now_sample: launch_sample + 2_205, position_ms: 2_049).join("\n")

    assert_match(/0:01\.95 +C-4/, later)
    assert_includes later, 'TRACKER · 0:02.05'
  end

  private

  def snapshot(chips:, sample: 0, revision: 1, status: :ready, message: nil)
    Vgm::Snapshot.new(generation: 1, revision: revision, sample: sample, status: status,
                      message: message, loop_count: 0, chips: chips, warnings: [])
  end

  def chip(id, name, labels, notes, kinds: [])
    channels = labels.each_with_index.map do |label, index|
      kind = kinds[index] || (label == 'Noise' ? :noise : :tone)
      Vgm::ChannelSnapshot.new(id: "#{id}:#{index}", label: label, kind: kind,
                               state: :key_on, last_trigger_sample: nil, pitch_hz: nil, note: nil,
                               pan: :lr, patch: nil, details: {})
    end
    Vgm::ChipSnapshot.new(id: id, name: name, clock_hz: 7_670_454, channels: channels,
                          details: { events: notes.packed })
  end

  def render(width:, height:, now_sample: 0, position_ms: nil, view: @view)
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: height, cols: width)
    view.render(screen, x: 0, y: 0, width: width, height: height, theme: THEME,
                        track_title: 'Song', now_sample: now_sample, position_ms: position_ms)
    screen.instance_variable_get(:@back).map { |row| row.map(&:ch).join }
  end
end
