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
    @log.on(0, NoteLog::HISTORY_SAMPLES + (2 * RubyPlayer::Vgm::SAMPLE_RATE), 61)

    assert_equal [61], NoteLog.decode(@log.packed).map(&:midi)
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
