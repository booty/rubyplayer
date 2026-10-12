# frozen_string_literal: true

require_relative 'snapshot'
require_relative 'chips'
require_relative 'vrc7'
require_relative '../vgm/snapshot'
require_relative '../vgm/note_log'
require_relative '../vgm/pitch'

module RubyPlayer
  module Nsf
    # Turns the stream of NSF chip snapshots into the channel model the VGM
    # live page draws (Vgm::Snapshot): the 2A03 and each expansion chip, with
    # note history. It must see every snapshot in order: note starts and
    # stops come from consecutive states, and a note shorter than a render
    # would otherwise be lost.
    #
    # Times are converted from output frames to the 44.1 kHz samples the
    # live page counts in.
    class Tracker
      VRC7_REGISTERS = [0x10, 0x20, 0x30].freeze
      KEY_ON = 0x10

      attr_reader :snapshot, :now_sample

      def initialize
        reset(nil)
      end

      # Feeds an engine ChipLiveState. Returns whether the channel model
      # changed (a new snapshot or a new generation).
      def update(live)
        @sample_rate = live.sample_rate
        changed = live.generation != @generation
        reset(live.generation) if changed
        @track_generation = live.track_generation
        @now_sample = to_sample(live.frame)
        live.snapshots.each { |state| ingest(state) }
        return changed unless live.snapshots.any? || (changed && @latest)

        @snapshot = build
        true
      end

      private

      def reset(generation)
        @generation = generation
        @notes = Hash.new { |hash, key| hash[key] = Vgm::NoteLog.new }
        @vrc7 = nil
        @vrc7_registers = nil
        @latest = nil
        @playing = 0
        @trigger_samples = {}
        @release_samples = {}
        @snapshot = nil
        @now_sample = 0
      end

      def to_sample(frame) = frame * Vgm::SAMPLE_RATE / @sample_rate

      def ingest(state)
        sample = to_sample(state.frame)
        Chips.for(state).each { |chip| ingest_chip(chip, state, sample) }
        ingest_vrc7(state, sample) if state.chip?(:vrc7)
        @playing = state.playing
        @latest = state
      end

      def ingest_chip(chip, state, sample)
        notes = @notes[chip.key]
        chip.channels.each_with_index do |channel, index|
          voice = channel.voice
          was = @playing[voice] == 1
          now = state.playing[voice] == 1
          midi = channel.pitch_hz && Vgm::Pitch.midi(channel.pitch_hz)
          if now && (state.triggers[voice] == 1 || !was)
            @trigger_samples[voice] = sample
            notes.on(index, sample, midi)
          elsif now
            notes.note(index, sample, midi)
          elsif was
            @release_samples[voice] = sample
            notes.off(index, sample)
          end
        end
      end

      # Rebuilds the register writes since the previous snapshot (every
      # register, for a new model). A key on that stayed on but was
      # retriggered between snapshots is replayed as key off, key on.
      def ingest_vrc7(state, sample)
        previous = @vrc7 && @vrc7_registers
        @vrc7 ||= Vrc7.new
        base = Voices.new(state.chips).base(:vrc7)
        current = state.vrc7_custom + state.vrc7_regs
        8.times { |register| write_vrc7(register, current.getbyte(register), previous&.getbyte(register), sample) }
        6.times do |channel|
          [0x10, 0x30, 0x20].each do |register|
            index = 8 + (channel * 3) + VRC7_REGISTERS.index(register)
            before = previous&.getbyte(index)
            if register == 0x20 && state.triggers[base + channel] == 1 && before&.anybits?(KEY_ON)
              @vrc7.write(register: register + channel, value: before & ~KEY_ON, sample: sample)
              before = nil # the key on must be written again
            end
            write_vrc7(register + channel, current.getbyte(index), before, sample)
          end
        end
        @vrc7_registers = current
      end

      def write_vrc7(register, value, before, sample)
        @vrc7.write(register: register, value: value, sample: sample) unless value == before
      end

      def build
        state = @latest
        chips = Chips.for(state).map { |chip| chip_snapshot(chip) }
        chips << vrc7_snapshot(state) if @vrc7
        Vgm::Snapshot.new(generation: @track_generation, revision: @generation, sample: to_sample(state.frame),
                          status: :ready, message: nil, loop_count: 0, chips: chips, warnings: [])
      end

      def chip_snapshot(chip)
        channels = chip.channels.each_with_index.map { |channel, index| channel_snapshot(chip, channel, index) }
        Vgm::ChipSnapshot.new(id: "#{chip.key}:0", name: chip.name, clock_hz: chip.clock_hz, channels: channels,
                              details: { **chip.details, events: @notes[chip.key].packed })
      end

      def channel_snapshot(chip, channel, index)
        voice = channel.voice
        pitch = channel.pitch_hz
        Vgm::ChannelSnapshot.new(
          id: "#{chip.key}:0:#{index}", label: channel.label, kind: channel.kind,
          state: @latest.playing[voice] == 1 ? :enabled : :off, last_trigger_sample: @trigger_samples[voice],
          pitch_hz: pitch, note: nil, pan: :lr, patch: nil,
          details: { **channel.details, voice: voice, release_sample: @release_samples[voice],
                                        pitch_cents: pitch && Vgm::Pitch.note_and_cents(pitch)&.last }
        )
      end

      # The OPLL model's channels, labelled for the NSF page and tagged with
      # their libgme voices (the page mutes NSF channels by voice).
      def vrc7_snapshot(state)
        base = Voices.new(state.chips).base(:vrc7)
        chip = @vrc7.snapshot(sample: to_sample(state.frame))
        channels = chip.channels.each_with_index.map do |channel, index|
          channel.with(label: "VRC7 #{channel.label}", details: channel.details.merge(voice: base + index))
        end
        chip.with(channels: channels)
      end
    end
  end
end
