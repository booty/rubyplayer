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
      # channel, kind index, MIDI note (negative: an unpitched sound code),
      # source sample
      FORMAT = 'CCcL<'
      EVENT_BYTES = 7
      HISTORY_SAMPLES = 20 * SAMPLE_RATE
      MAX_EVENTS = 4_096
      PRUNE_SLACK = 256
      NO_NOTE = -1
      # What a start without a pitch plays, when its recorder knows: a voice
      # can change modes later (HES Multi voices), so it is kept per event.
      UNPITCHED_CODES = { noise: -2, dac: -3 }.freeze
      UNPITCHED_SOUNDS = UNPITCHED_CODES.invert.freeze
      private_constant :EVENT_BYTES, :PRUNE_SLACK, :NO_NOTE, :UNPITCHED_CODES, :UNPITCHED_SOUNDS

      # `unpitched` is :noise, :dac, or nil (pitched, or not known).
      Event = Data.define(:channel, :kind, :midi, :sample, :unpitched) do
        def initialize(unpitched: nil, **) = super
      end

      def self.decode(packed)
        return [] if packed.nil? || packed.empty?

        packed.unpack(FORMAT * (packed.bytesize / EVENT_BYTES)).each_slice(4).map do |channel, kind, code, sample|
          Event.new(channel: channel, kind: KINDS.fetch(kind), midi: code.negative? ? nil : code, sample: sample,
                    unpitched: UNPITCHED_SOUNDS[code])
        end
      end

      def initialize
        @buffer = +''.b
        @last_midi = {}
      end

      def on(channel, sample, midi, unpitched: nil)
        @last_midi[channel] = midi
        append(channel, 0, midi || UNPITCHED_CODES.fetch(unpitched, NO_NOTE), sample)
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

      # Keeps events in sample order: pruning and the history lanes depend
      # on it, and a DAC burst's end is logged late, at its last write, after
      # other channels may have logged later events.
      def append(channel, kind, code, sample)
        event = [channel, kind, code || NO_NOTE, sample].pack(FORMAT)
        index = @buffer.bytesize / EVENT_BYTES
        index -= 1 while index.positive? && sample_at(index - 1) > sample
        @buffer.insert(index * EVENT_BYTES, event)
        prune(sample_at((@buffer.bytesize / EVENT_BYTES) - 1))
      end

      # Trims in batches (a second's worth or PRUNE_SLACK events past the
      # limits) so the buffer is not recopied on every append.
      def prune(sample)
        count = @buffer.bytesize / EVENT_BYTES
        return unless count > MAX_EVENTS + PRUNE_SLACK ||
                      sample - sample_at(0) > HISTORY_SAMPLES + SAMPLE_RATE

        drop = [count - MAX_EVENTS, 0].max
        drop += 1 while drop < count - 1 && sample - sample_at(drop) > HISTORY_SAMPLES
        return if drop.zero?

        boundary = (sample - HISTORY_SAMPLES).clamp(sample_at(drop - 1), sample_at(drop))
        @buffer = held_at_cut(drop, boundary) + @buffer.byteslice((drop * EVENT_BYTES)..)
      end

      # A note held across the cut would lose its only start event and
      # vanish from the history, so each still-held channel restarts at the
      # boundary with the pitch (or unpitched sound) it had there.
      def held_at_cut(drop, boundary)
        held = {}
        self.class.decode(@buffer.byteslice(0, drop * EVENT_BYTES)).each do |event|
          case event.kind
          when :on then held[event.channel] = event.midi || UNPITCHED_CODES.fetch(event.unpitched, NO_NOTE)
          when :off then held.delete(event.channel)
          when :note then held[event.channel] = event.midi if held.key?(event.channel)
          end
        end
        held.map { |channel, code| [channel, 0, code, boundary].pack(FORMAT) }.join.b
      end

      def sample_at(index) = @buffer.unpack1('L<', offset: (index * EVENT_BYTES) + 3)
    end
  end
end
