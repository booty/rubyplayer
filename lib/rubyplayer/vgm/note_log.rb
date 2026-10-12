# frozen_string_literal: true

require_relative 'snapshot'

module RubyPlayer
  module Vgm
    # Bounded history of one chip's note starts, stops, and pitch changes, so
    # the live page can draw what each channel played over the last seconds.
    #
    # Snapshots are published at the UI refresh rate and only the latest is
    # kept, so notes shorter than a refresh would be lost if the UI sampled
    # channel state; the replay sees every write and records them here.
    #
    # Events are kept packed (one String) because every snapshot and every
    # one-second checkpoint carries a copy.
    class NoteLog
      KINDS = %i[on off note].freeze
      # channel, kind index, MIDI note (-1 for none), source sample
      FORMAT = 'CCcL<'
      EVENT_BYTES = 7
      HISTORY_SAMPLES = 20 * SAMPLE_RATE
      MAX_EVENTS = 4_096
      PRUNE_SLACK = 256
      NO_NOTE = -1
      private_constant :EVENT_BYTES, :PRUNE_SLACK, :NO_NOTE

      Event = Data.define(:channel, :kind, :midi, :sample)

      def self.decode(packed)
        return [] if packed.nil? || packed.empty?

        packed.unpack(FORMAT * (packed.bytesize / EVENT_BYTES)).each_slice(4).map do |channel, kind, midi, sample|
          Event.new(channel: channel, kind: KINDS.fetch(kind), midi: midi == NO_NOTE ? nil : midi, sample: sample)
        end
      end

      def initialize
        @buffer = +''.b
        @last_midi = {}
      end

      def on(channel, sample, midi)
        @last_midi[channel] = midi
        append(channel, 0, midi, sample)
      end

      def off(channel, sample)
        append(channel, 1, nil, sample)
      end

      # Pitch moves within a held note; vibrato that stays on one note is not
      # a change.
      def note(channel, sample, midi)
        return if midi.nil? || @last_midi[channel] == midi

        @last_midi[channel] = midi
        append(channel, 2, midi, sample)
      end

      def packed = @buffer.dup.freeze

      def dump_state = { events: packed, last_midi: @last_midi.dup }

      def restore_state(state)
        @buffer = state.fetch(:events).b
        @last_midi = state.fetch(:last_midi).dup
        self
      end

      private

      def append(channel, kind, midi, sample)
        @buffer << [channel, kind, midi || NO_NOTE, sample].pack(FORMAT)
        prune(sample)
      end

      # Trims in batches (a second's worth or PRUNE_SLACK events past the
      # limits) so the buffer is not recopied on every append.
      def prune(sample)
        count = @buffer.bytesize / EVENT_BYTES
        return unless count > MAX_EVENTS + PRUNE_SLACK ||
                      sample - sample_at(0) > HISTORY_SAMPLES + SAMPLE_RATE

        drop = [count - MAX_EVENTS, 0].max
        drop += 1 while drop < count - 1 && sample - sample_at(drop) > HISTORY_SAMPLES
        @buffer = @buffer.byteslice((drop * EVENT_BYTES)..)
      end

      def sample_at(index) = @buffer.unpack1('L<', offset: (index * EVENT_BYTES) + 3)
    end
  end
end
