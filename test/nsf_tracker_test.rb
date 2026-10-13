# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/backends/nsf_native'
require 'rubyplayer/chip_timeline'
require 'rubyplayer/nsf/tracker'
require_relative 'support/rip_fixtures'

class NsfTrackerTest < Minitest::Test
  NoteLog = RubyPlayer::Vgm::NoteLog
  Snapshot = RubyPlayer::Nsf::Snapshot
  Rips = TestSupport::RipFixtures
  RATE = 44_100
  CHUNK = 16_384

  def setup
    @tracker = RubyPlayer::Nsf::Tracker.new
  end

  # Pulse 1 keyed at 0.1 s, re-triggered at 0.2 s, silent at 0.3 s.
  def test_triggers_and_silence_become_note_events
    ingest(state(frame: 4_410, playing: 1, triggers: 1),
           state(frame: 8_820, playing: 1, triggers: 1),
           state(frame: 13_230))
    events = events_for('2a03')

    assert_equal(%i[on on off], events.map(&:kind))
    assert_equal [4_410, 8_820, 13_230], events.map(&:sample)
    assert_equal [0, 0, 0], events.map(&:channel)
  end

  def test_channels_carry_their_libgme_voice_for_muting
    ingest(state(chips: 0x01, voice_count: 8, playing: 1 << 5))
    chips = @tracker.snapshot.chips.to_h { |chip| [chip.id, chip] }

    assert_equal([0, 1, 2, 3, 4], chips.fetch('2a03:0').channels.map { |channel| channel.details[:voice] })
    # libgme numbers the VRC6 saw first; the page lists the pulses first.
    assert_equal([6, 7, 5], chips.fetch('vrc6:0').channels.map { |channel| channel.details[:voice] })
    assert_equal ['VRC6 Pulse 1', 'VRC6 Pulse 2', 'VRC6 Saw'], chips.fetch('vrc6:0').channels.map(&:label)
    assert_equal :enabled, chips.fetch('vrc6:0').channels.last.state
  end

  def test_pulse_pitch_comes_from_the_period
    regs = [0xbf, 0x08, 0xfd, 0x00].pack('C4') + ("\0" * 16)
    ingest(state(apu_regs: regs, playing: 1))
    pulse = channel('2a03', 0)

    # 1789773 / (16 * 254) = 440.4 Hz.
    assert_in_delta 440.4, pulse.pitch_hz, 0.1
    assert_equal 50, pulse.details[:duty]
  end

  def test_a_new_generation_restarts_history
    ingest(state(frame: 4_410, playing: 1, triggers: 1))
    ingest(state(frame: 0), generation: 2)

    assert_empty events_for('2a03')
  end

  # The same note again, with nothing changed but a retrigger: the
  # synthesized key off must be followed by key on, not leave it off.
  def test_vrc7_retriggers_with_unchanged_registers_stay_keyed_on
    note = vrc7_note(frame: 4_410, triggers: 1 << 5)
    ingest(note, note.with(frame: 8_820))
    channel = vrc7_channel(0)

    assert_equal :key_on, channel.state
    # The OPLL model logs the replayed key off and key on together.
    assert_equal([[:on, 4_410], [:off, 8_820], [:on, 8_820]], events_for('vrc7').map do |event|
      [event.kind, event.sample]
    end)
  end

  # A seek or track change starts a new model; it must get every register,
  # including those equal to the previous generation's.
  def test_vrc7_state_is_complete_after_a_new_generation
    note = vrc7_note(frame: 4_410, triggers: 1 << 5)
    ingest(note)
    ingest(note.with(frame: 0), generation: 2)
    channel = vrc7_channel(0)

    assert_equal :key_on, channel.state
    assert_equal 'Piano', channel.details[:program_name]
    refute_nil channel.pitch_hz
  end

  def test_every_rip_maps_to_its_chips
    expected = { mega_man_2: %w[2a03], castlevania_3_japan: %w[2a03 vrc6], lagrange_point: %w[2a03 vrc7],
                 metroid_fds: %w[2a03 fds], just_breed: %w[2a03 mmc5], erika_to_satoru: %w[2a03 n163],
                 gimmick: %w[2a03 s5b], gimmick_europe: %w[2a03] }
    expected.each do |name, chips|
      tracker = played(name)

      assert_equal chips, tracker.snapshot.chips.map { |chip| chip.id.split(':').first }, name
      # The expansion chip, or the 2A03 alone, plays notes (Lagrange Point
      # opens on the VRC7 only).
      notes = NoteLog.decode(tracker.snapshot.chips.last.details[:events]).count { |event| event.kind == :on }

      assert_operator notes, :>, 0, "#{name} #{chips.last} played no notes"
    end
  end

  def test_pal_rips_name_the_pal_chip
    apu = played(:gimmick_europe).snapshot.chips.first

    assert_equal 'Ricoh 2A07', apu.name
    assert apu.details[:pal]
  end

  # VRC7 channels are OPLL channels: programs from the VRC7 ROM, key on and
  # off, each tagged with its libgme voice.
  def test_vrc7_channels_come_from_the_opll_model
    chip = played(:lagrange_point).snapshot.chips.find { |entry| entry.id.start_with?('vrc7') }

    assert_equal 'Konami VRC7', chip.name
    assert_equal (1..6).map { |number| "VRC7 FM #{number}" }, chip.channels.map(&:label)
    assert_equal((5..10).to_a, chip.channels.map { |entry| entry.details[:voice] })
    assert(chip.channels.all? { |entry| entry.kind == :tone })
    assert(chip.channels.any? { |entry| RubyPlayer::Nsf::Vrc7::PROGRAM_NAMES.include?(entry.details[:program_name]) })
  end

  # Erika uses all eight Namco 163 channels; Rolling Thunder four.
  def test_n163_enables_channels_from_channel_1
    erika = played(:erika_to_satoru).snapshot.chips.last
    rolling = played(:rolling_thunder_japan).snapshot.chips.last

    assert_equal 8, erika.details[:active]
    assert_equal 4, rolling.details[:active]
    assert_equal(([true] * 4) + ([false] * 4), rolling.channels.map { |entry| entry.details[:enabled] })
    assert_equal((5..12).to_a.reverse, rolling.channels.map { |entry| entry.details[:voice] })
  end

  private

  def played(name)
    @played ||= {}
    @played[name] ||= begin
      handle = RubyPlayer::Backends::NsfNative.new.open(Rips.path(name), 0, sample_rate: RATE)
      timeline = RubyPlayer::ChipTimeline.new
      tracker = RubyPlayer::Nsf::Tracker.new
      30.times do |chunk|
        handle.read(CHUNK)
        timeline.push(*handle.take_snapshots, origin_frame: chunk * CHUNK, snapshot_type: Snapshot)
        frame = (chunk + 1) * CHUNK
        tracker.update(live(timeline.take_through(frame, limit: 4_096), frame: frame))
      end
      handle.close
      tracker
    end
  end

  def ingest(*states, generation: 1)
    @tracker.update(live(states, frame: states.last.frame, generation: generation))
  end

  def live(states, frame:, generation: 1)
    RubyPlayer::ChipLiveState.new(snapshots: states, latest: states.last, generation: generation, track_generation: 1,
                                  frame: frame, sample_rate: RATE, paused: false, mute_mask: 0)
  end

  def state(**fields)
    @zero ||= Snapshot.unpack(("\0" * Snapshot::SIZE).b, 0).with(play_period: 29_830, clock_rate: 1_789_773,
                                                                 voice_count: 5)
    @zero.with(**fields)
  end

  # VRC7 channel 1 keyed on: FNUM $80, block 1, ROM instrument 3 (Piano).
  def vrc7_note(**fields)
    regs = ([0x80, 0x12, 0x30] + ([0] * 15)).pack('C*')
    state(chips: 0x02, voice_count: 11, playing: 1 << 5, vrc7_regs: regs, **fields)
  end

  def vrc7_channel(index) = @tracker.snapshot.chips.find { |entry| entry.id.start_with?('vrc7') }.channels[index]

  def events_for(key)
    chip = @tracker.snapshot.chips.find { |entry| entry.id.start_with?(key) }
    NoteLog.decode(chip.details[:events])
  end

  def channel(key, index) = @tracker.snapshot.chips.find { |entry| entry.id.start_with?(key) }.channels[index]
end
