# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/vgm/note_log'

class VgmNoteLogTest < Minitest::Test
  NoteLog = RubyPlayer::Vgm::NoteLog

  def setup
    @log = NoteLog.new
  end

  def test_records_starts_stops_and_pitch_changes_in_order
    @log.on(0, 100, 60)
    @log.note(0, 200, 62)
    @log.off(0, 300)
    @log.on(3, 400, nil)

    events = NoteLog.decode(@log.packed)

    assert_equal([[0, :on, 60, 100], [0, :note, 62, 200], [0, :off, nil, 300], [3, :on, nil, 400]],
                 events.map { |event| [event.channel, event.kind, event.midi, event.sample] })
  end

  # Vibrato rewrites the frequency every frame without leaving the note.
  def test_pitch_writes_on_the_same_note_are_not_changes
    @log.on(1, 0, 64)
    5.times { |index| @log.note(1, index * 10, 64) }
    @log.note(1, 60, nil)

    assert_equal 1, NoteLog.decode(@log.packed).size
  end

  def test_old_events_are_dropped
    @log.on(0, 0, 60)
    @log.off(0, 100)
    @log.on(0, NoteLog::HISTORY_SAMPLES + (2 * RubyPlayer::Vgm::SAMPLE_RATE), 61)

    assert_equal [61], NoteLog.decode(@log.packed).map(&:midi)
  end

  # Channel 0 is held from the start; pruning must not drop its only start.
  def test_notes_held_across_the_cut_restart_at_the_boundary
    @log.on(0, 0, 60)
    @log.note(0, 10, 62)
    @log.on(1, 20, 70)
    @log.off(1, 30)
    late = NoteLog::HISTORY_SAMPLES + (2 * RubyPlayer::Vgm::SAMPLE_RATE)
    @log.on(2, late, 64)

    events = NoteLog.decode(@log.packed)

    assert_equal([[0, :on, 62, late - NoteLog::HISTORY_SAMPLES], [2, :on, 64, late]],
                 events.map { |event| [event.channel, event.kind, event.midi, event.sample] })
  end

  # A start without a pitch may say what sounds instead (noise, DAC
  # samples), since a voice can change modes after the event.
  def test_unpitched_starts_keep_their_sound_across_the_cut
    @log.on(0, 0, nil, unpitched: :noise)
    @log.on(1, 10, nil, unpitched: :dac)
    @log.on(2, 20, nil)
    @log.on(3, 30, 60)

    assert_equal([:noise, :dac, nil, nil], NoteLog.decode(@log.packed).map(&:unpitched))
    assert_equal([nil, nil, nil, 60], NoteLog.decode(@log.packed).map(&:midi))
    @log.on(4, NoteLog::HISTORY_SAMPLES + (2 * RubyPlayer::Vgm::SAMPLE_RATE), 64)

    assert_equal([:noise, :dac, nil, nil, nil], NoteLog.decode(@log.packed).map(&:unpitched))
  end

  def test_late_events_are_kept_in_sample_order
    @log.on(0, 100, 60)
    @log.on(1, 300, 61)
    @log.off(0, 200)

    assert_equal [100, 200, 300], NoteLog.decode(@log.packed).map(&:sample)
  end

  def test_event_count_is_bounded
    (NoteLog::MAX_EVENTS + 1_000).times { |index| @log.on(0, index, index % 128) }

    events = NoteLog.decode(@log.packed)

    assert_operator events.size, :<=, NoteLog::MAX_EVENTS + 256
    assert_equal NoteLog::MAX_EVENTS + 999, events.last.sample
  end

  def test_state_round_trip_is_independent
    @log.on(0, 10, 60)
    state = @log.dump_state
    copy = NoteLog.new.restore_state(state)
    @log.on(1, 20, 61)
    copy.note(0, 30, 60)

    assert_equal 1, NoteLog.decode(copy.packed).size
    assert_equal 2, NoteLog.decode(@log.packed).size
    assert_predicate @log.packed, :frozen?
  end
end
