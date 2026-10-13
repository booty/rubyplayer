# frozen_string_literal: true

require_relative 'snapshot'
require_relative 'chips'
require_relative 'vrc7'
require_relative '../chip_tracker'

module RubyPlayer
  module Nsf
    # Turns NSF chip snapshots into the live page's view snapshot (see
    # ChipTracker): the 2A03 and each expansion chip, each with its own note
    # history, numbered by libgme voice.
    class Tracker < ChipTracker
      VRC7_REGISTERS = [0x10, 0x20, 0x30].freeze
      KEY_ON = 0x10

      private

      def reset_format_state
        @notes = Hash.new { |hash, key| hash[key] = Vgm::NoteLog.new }
        @vrc7 = nil
        @vrc7_registers = nil
      end

      def ingest(native_snapshot, sample)
        Chips.for(native_snapshot).each { |chip| ingest_chip(chip, native_snapshot, sample) }
        ingest_vrc7(native_snapshot, sample) if native_snapshot.chip?(:vrc7)
      end

      def ingest_chip(chip, native_snapshot, sample)
        notes = @notes[chip.key]
        chip.channels.each_with_index do |channel, index|
          midi = channel.pitch_hz && Vgm::Pitch.midi(channel.pitch_hz)
          record_note(notes, index, channel.voice, native_snapshot, sample, midi)
        end
      end

      # Rebuilds the register writes since the previous snapshot (every
      # register, for a new model). A key on that stayed on but was
      # retriggered between snapshots is replayed as key off, key on.
      def ingest_vrc7(native_snapshot, sample)
        previous = @vrc7 && @vrc7_registers
        @vrc7 ||= Vrc7.new
        base = Voices.new(native_snapshot.chips).base(:vrc7)
        current = native_snapshot.vrc7_custom + native_snapshot.vrc7_regs
        8.times { |register| write_vrc7(register, current.getbyte(register), previous&.getbyte(register), sample) }
        6.times do |channel|
          [0x10, 0x30, 0x20].each do |register|
            index = 8 + (channel * 3) + VRC7_REGISTERS.index(register)
            before = previous&.getbyte(index)
            if register == 0x20 && native_snapshot.triggers[base + channel] == 1 && before&.anybits?(KEY_ON)
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

      def build_view_snapshot(native_snapshot)
        chips = Chips.for(native_snapshot).map { |chip| chip_snapshot(chip) }
        chips << vrc7_snapshot(native_snapshot) if @vrc7
        view_snapshot(native_snapshot, chips)
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
      def vrc7_snapshot(native_snapshot)
        base = Voices.new(native_snapshot.chips).base(:vrc7)
        chip = @vrc7.snapshot(sample: to_sample(native_snapshot.frame))
        channels = chip.channels.each_with_index.map do |channel, index|
          channel.with(label: "VRC7 #{channel.label}", details: channel.details.merge(voice: base + index))
        end
        chip.with(channels: channels)
      end
    end
  end
end
