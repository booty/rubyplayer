# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/hes/tracker'
require 'rubyplayer/backends/hes_native'
require_relative 'support/rip_fixtures'

class HesTrackerTest < Minitest::Test
  Snapshot = RubyPlayer::Hes::Snapshot
  LiveState = RubyPlayer::Hes::LiveState
  NoteLog = RubyPlayer::Vgm::NoteLog
  RATE = 48_000
  PSG_CLOCK_HZ = 7_159_091
  KEY_ON = 0x80
  DIRECT_DAC = 0x40
  NOISE_ON = 0x80
  # 7,159,091 / (64 * period): 440.4 Hz (A4) and 522.7 Hz (C5).
  A4_PERIOD = 254
  C5_PERIOD = 214

  def setup
    @tracker = RubyPlayer::Hes::Tracker.new
  end

  def test_key_on_pitch_change_and_key_off_become_note_history
    feed(state(frame: 4_800, playing: 0b1, triggers: 0b1, periods: { 0 => A4_PERIOD }),
         state(frame: 9_600, playing: 0b1, periods: { 0 => C5_PERIOD }),
         state(frame: 14_400, playing: 0))

    events = NoteLog.decode(chip.details[:events])

    assert_equal(%i[on note off], events.map(&:kind))
    assert_equal [4_410, 8_820, 13_230], events.map(&:sample)
    assert_equal [69, 72, nil], events.map(&:midi)
    assert_equal 13_230, channel(0).details[:release_sample]
  end

  # A gate retrigger while sounding is a new note.
  def test_retriggers_start_new_notes
    feed(state(frame: 0, playing: 0b1, triggers: 0b1, periods: { 0 => A4_PERIOD }),
         state(frame: 800, playing: 0b1, triggers: 0b1, periods: { 0 => A4_PERIOD }))

    assert_equal(%i[on on], NoteLog.decode(chip.details[:events]).map(&:kind))
    assert_equal 735, channel(0).last_trigger_sample
  end

  def test_wave_voices_carry_pitch_wave_volume_gain_and_pan
    controls = { 0 => KEY_ON | 31 }
    feed(state(frame: 0, playing: 0b1, periods: { 0 => A4_PERIOD }, controls: controls, balances: { 0 => 0xf0 },
               gains: { 0 => [1200, 0] }))
    wave = channel(0)

    assert_equal ['huc6280:0:0', 'Wave 1', :huc_wave, :enabled], [wave.id, wave.label, wave.kind, wave.state]
    assert_in_delta 440.4, wave.pitch_hz, 0.1
    assert_equal :l, wave.pan
    assert_equal({ voice: 0, mode: :wave, period_register: A4_PERIOD, volume: 31, gain_left: 1200, gain_right: 0,
                   balance_left: 15, balance_right: 0, key_on: true },
                 wave.details.slice(:voice, :mode, :period_register, :volume, :gain_left, :gain_right,
                                    :balance_left, :balance_right, :key_on))
    assert_equal (0...32).map { |step| step & 0x1f }, wave.details[:samples]
    assert_equal ['huc6280:0', 'HuC6280 PSG', PSG_CLOCK_HZ], [chip.id, chip.name, chip.clock_hz]
  end

  # Noise belongs to voices 5-6 only; direct DAC to any voice. Neither has a
  # pitch, so their notes carry none.
  def test_noise_and_direct_dac_modes_have_no_pitch
    feed(state(frame: 0, playing: 0b11_0001, triggers: 0b11_0001,
               periods: { 0 => A4_PERIOD, 4 => A4_PERIOD, 5 => A4_PERIOD },
               controls: { 0 => KEY_ON | DIRECT_DAC | 31, 4 => KEY_ON | 31, 5 => KEY_ON | 31 },
               noises: { 0 => NOISE_ON | 3, 4 => NOISE_ON | 0x1f }, dacs: { 0 => 17 }))
    dda = channel(0)
    noise = channel(4)

    assert_equal [:huc_dda, :dda, nil, 17], [dda.kind, dda.details[:mode], dda.pitch_hz, dda.details[:dac_sample]]
    assert_equal [:huc_noise, :noise, nil, 31], [noise.kind, noise.details[:mode], noise.pitch_hz,
                                                 noise.details[:noise_rate_code]]
    assert_in_delta PSG_CLOCK_HZ / 64.0, noise.details[:noise_lfsr_hz], 0.01
    assert_equal :huc_wave, channel(5).kind
    events = NoteLog.decode(chip.details[:events])

    assert_equal [nil, nil, 69], events.map(&:midi)
    assert_equal [:dac, :noise, nil], events.map(&:unpitched)
  end

  def test_unkeyed_and_silent_voices_are_off
    feed(state(frame: 0, playing: 0, controls: { 0 => 31 }))

    assert_equal [:off] * 6, chip.channels.map(&:state)
    assert_equal :none, channel(1).pan
    refute channel(0).details[:key_on]
  end

  def test_new_history_generation_restarts_history_only
    feed(state(frame: 0, playing: 0b1, triggers: 0b1, periods: { 0 => A4_PERIOD }))
    track_generation = @tracker.snapshot.generation
    feed(state(frame: 96_000, playing: 0), generation: 2)

    assert_empty NoteLog.decode(chip.details[:events])
    assert_equal track_generation, @tracker.snapshot.generation
    assert_equal 88_200, @tracker.now_sample
  end

  # Native playback of a real rip reaches all six rows and note history.
  def test_native_snapshots_feed_six_rows_and_history
    handle = RubyPlayer::Backends::HesNative.new.open(TestSupport::RipFixtures.path(:air_zonk), 1, sample_rate: RATE)
    6.times do |chunk|
      handle.read(16_384)
      packed, count = handle.take_snapshots
      states = Array.new(count) do |index|
        snapshot = Snapshot.unpack(packed, index)
        snapshot.with(frame: (chunk * 16_384) + snapshot.frame)
      end
      @tracker.update(live(states, generation: 1)) unless states.empty?
    end

    assert_equal (0...6).map { "huc6280:0:#{it}" }, chip.channels.map(&:id)
    assert_operator NoteLog.decode(chip.details[:events]).count { it.kind == :on }, :>, 5
  ensure
    handle&.close
  end

  private

  def feed(*states, generation: 1)
    @tracker.update(live(states, generation: generation))
  end

  def live(states, generation:)
    LiveState.new(snapshots: states, latest: states.last, generation: generation, track_generation: 7,
                  frame: states.last&.frame || 0, sample_rate: RATE, paused: false, mute_mask: 0)
  end

  def chip = @tracker.snapshot.chips.first
  def channel(index) = chip.channels[index]

  def state(frame:, playing: 0, triggers: 0, periods: {}, controls: nil, balances: {}, noises: {}, dacs: {},
            gains: {})
    controls ||= (0...6).to_h { |voice| [voice, playing[voice] == 1 ? KEY_ON | 31 : 0] }
    per_voice = ->(values, default) { Array.new(6) { |voice| values.fetch(voice, default) } }
    gains = per_voice.call(gains, nil)
    Snapshot.new(frame: frame, playing: playing, triggers: triggers, master_balance: 0xff, selected_channel: 0,
                 period: per_voice.call(periods, 0), control: per_voice.call(controls, 0),
                 balance: per_voice.call(balances, 0xff), noise: per_voice.call(noises, 0),
                 dac: per_voice.call(dacs, 0), wave: (0...192).map { it & 0x1f }.pack('C*'),
                 output_left: side_gains(gains, playing, 0), output_right: side_gains(gains, playing, 1),
                 vblank_period_cycles: 119_210, cpu_clock_hz: PSG_CLOCK_HZ)
  end

  # Each voice's given [left, right] gain on `side`, else a nominal gain
  # when it is playing.
  def side_gains(gains, playing, side)
    gains.each_with_index.map do |gain, voice|
      next gain[side] if gain

      playing[voice] == 1 ? 1000 : 0
    end
  end
end
