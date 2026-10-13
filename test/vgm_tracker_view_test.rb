# frozen_string_literal: true

require 'test_helper'
require 'stringio'
require 'rubyplayer/ui/screen'
require 'rubyplayer/vgm/note_log'
require 'rubyplayer/vgm/snapshot'
require 'rubyplayer/ui/vgm_tracker_view'

class VgmTrackerViewTest < Minitest::Test
  Vgm = RubyPlayer::Vgm
  THEME = RubyPlayer::Theme::DEFAULT

  def setup
    @view = RubyPlayer::UI::VgmTrackerView.new
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
    psg.on(0, 0, nil)
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

  private

  def snapshot(chips:, sample: 0, revision: 1, status: :ready, message: nil)
    Vgm::Snapshot.new(generation: 1, revision: revision, sample: sample, status: status,
                      message: message, loop_count: 0, chips: chips, warnings: [])
  end

  def chip(id, name, labels, notes)
    channels = labels.each_with_index.map do |label, index|
      Vgm::ChannelSnapshot.new(id: "#{id}:#{index}", label: label, kind: label == 'Noise' ? :noise : :tone,
                               state: :key_on, last_trigger_sample: nil, pitch_hz: nil, note: nil,
                               pan: :lr, patch: nil, details: {})
    end
    Vgm::ChipSnapshot.new(id: id, name: name, clock_hz: 7_670_454, channels: channels,
                          details: { events: notes.packed })
  end

  def render(width:, height:, now_sample: 0)
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: height, cols: width)
    @view.render(screen, x: 0, y: 0, width: width, height: height, theme: THEME,
                         track_title: 'Song', now_sample: now_sample)
    screen.instance_variable_get(:@back).map { |row| row.map(&:ch).join }
  end
end
