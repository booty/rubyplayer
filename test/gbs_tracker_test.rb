# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/gbs/tracker'

class GbsTrackerTest < Minitest::Test
  Snapshot = RubyPlayer::Gbs::Snapshot
  LiveState = RubyPlayer::Gbs::LiveState
  NoteLog = RubyPlayer::Vgm::NoteLog
  RATE = 48_000

  def setup
    @tracker = RubyPlayer::Gbs::Tracker.new
  end

  def test_triggers_pitch_changes_and_stops_become_note_history
    feed(state(frame: 4_800, playing: 0b1, triggers: 0b1, square1: 1750),
         state(frame: 9_600, playing: 0b1, square1: 1798),
         state(frame: 14_400, playing: 0))

    events = NoteLog.decode(@tracker.snapshot.chips.first.details[:events])

    assert_equal(%i[on note off], events.map(&:kind))
    assert_equal [4_410, 8_820, 13_230], events.map(&:sample)
    assert_equal [69, 72, nil], events.map(&:midi)
  end

  # A retrigger while sounding is a new note; a held note that only keeps
  # sounding is not.
  def test_retriggers_start_new_notes
    feed(state(frame: 0, playing: 0b1, triggers: 0b1, square1: 1750),
         state(frame: 800, playing: 0b1, square1: 1750),
         state(frame: 1_600, playing: 0b1, triggers: 0b1, square1: 1750))

    assert_equal(%i[on on], NoteLog.decode(@tracker.snapshot.chips.first.details[:events]).map(&:kind))
    assert_equal 1_470, channel(0).last_trigger_sample
  end

  def test_channels_carry_pitch_state_pan_and_register_details
    regs = Array.new(48, 0)
    regs[1] = 0b1000_0000 # square 1: 50% duty
    regs[2] = 0xf3        # volume 15, down, pace 3
    regs[0x0a] = 0x80     # wave DAC on
    regs[0x0c] = 0x20     # wave output 100%
    regs[0x0d] = 0x00
    regs[0x0e] = 0x06 # wave period 1536: 128 Hz
    regs[0x12] = 0x18 # noise: shift 1, 7-bit, divisor 0
    regs[21] = 0b0001_0010 # square 1 left only, square 2 right only
    regs[32] = 0x0f
    feed(state(frame: 0, playing: 0b0101, regs: regs, square1: 1750, volume: [9, 0, 1, 0]))

    square = channel(0)

    assert_equal :enabled, square.state
    assert_in_delta 440.0, square.pitch_hz, 0.5
    assert_equal :l, square.pan
    assert_equal 50, square.details[:duty]
    assert_equal [15, false, 3], square.details.values_at(:initial_volume, :envelope_up, :envelope_pace)
    assert_equal 9, square.details[:volume]
    assert_equal :r, channel(1).pan
    assert_equal :off, channel(1).state

    wave = channel(2)

    assert_in_delta 128.0, wave.pitch_hz, 0.01
    assert_equal 100, wave.details[:level]
    assert_equal [0, 15, *Array.new(30, 0)], wave.details[:samples]
    # 7-bit noise repeats every 127 steps: 524288 / 0.5 / 4 / 127 Hz.
    assert_in_delta 2_064.1, channel(3).pitch_hz, 0.1
  end

  def test_chip_line_details
    regs = Array.new(48, 0)
    regs[20] = 0x53
    regs[22] = 0x80
    feed(state(frame: 0, regs: regs))
    details = @tracker.snapshot.chips.first.details

    assert_equal [true, 5, 3, true], details.values_at(:power, :master_left, :master_right, :vblank_driver)
    assert_in_delta 59.73, details[:driver_hz], 0.01
  end

  # A seek (new history generation) restarts history but keeps the page's
  # track generation, so its selection survives.
  def test_new_history_generation_restarts_history_only
    feed(state(frame: 0, playing: 0b1, triggers: 0b1, square1: 1750))
    track_generation = @tracker.snapshot.generation
    feed(state(frame: 96_000, playing: 0), generation: 2)

    assert_empty NoteLog.decode(@tracker.snapshot.chips.first.details[:events])
    assert_equal track_generation, @tracker.snapshot.generation
    assert_equal 88_200, @tracker.now_sample
  end

  def test_update_reports_whether_the_model_changed
    assert feed(state(frame: 0))
    refute @tracker.update(live([], generation: 1))
  end

  private

  def feed(*states, generation: 1)
    @tracker.update(live(states, generation: generation))
  end

  def live(states, generation:)
    LiveState.new(snapshots: states, latest: states.last, generation: generation, track_generation: 7,
                  frame: states.last&.frame || 0, sample_rate: RATE, paused: false, mute_mask: 0)
  end

  def channel(index) = @tracker.snapshot.chips.first.channels[index]

  def state(frame:, playing: 0, triggers: 0, regs: nil, square1: nil, volume: [15, 15, 1, 15])
    regs = (regs || Array.new(48, 0)).dup
    if square1
      regs[3] = square1 & 0xff
      regs[4] = (regs[4] & ~7) | (square1 >> 8)
    end
    Snapshot.new(frame: frame, regs: regs, volume: volume, playing: playing, enabled: playing, triggers: triggers,
                 length: [0, 0, 0, 0], sweep_freq: square1.to_i, driver_period_cycles: 70_224, cpu_clock_hz: 4_194_304)
  end
end
