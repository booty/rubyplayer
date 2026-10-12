# frozen_string_literal: true

module RubyPlayer
  module Gbs
    VOICES = 4
    VOICE_NAMES = ['Square 1', 'Square 2', 'Wave', 'Noise'].freeze

    # One Game Boy APU state record from librp_gbs (rp_gbs_snapshot in
    # ext/rp_gbs/rp_gbs.h), taken when what is heard changes. `frame` is
    # relative to the first frame of the read that produced it until a
    # timeline makes it absolute. `regs` are $FF10-$FF3F; bit fields are bit i
    # for voice i.
    Snapshot = Data.define(:frame, :regs, :volume, :playing, :enabled, :triggers, :length, :sweep_freq,
                           :play_period, :clock_rate) do
      # Constants live in the class body below; a define block's lexical scope
      # is Gbs, so they need a qualified lookup here.
      def self.unpack(packed, index)
        fields = packed.unpack(self::FORMAT, offset: index * self::SIZE)
        new(frame: fields[0], regs: fields[1, 48].freeze, volume: fields[49, VOICES].freeze,
            playing: fields[53], enabled: fields[54], triggers: fields[55], length: fields[56, VOICES].freeze,
            sweep_freq: fields[60], play_period: fields[61], clock_rate: fields[62])
      end

      # Music-driver calls per second (VBlank is ~59.7 Hz; timer drivers vary).
      def driver_hz = play_period.positive? ? clock_rate.fdiv(play_period) : nil
    end

    class Snapshot
      SIZE = 80
      # int32 frame, uint8 regs[48], uint8 volume[4], uint8 playing, enabled,
      # triggers, pad, uint16 length[4], uint16 sweep_freq, pad, uint32
      # play_period, uint32 clock_rate.
      FORMAT = 'l<C48C4CCCxS<4S<x2L<L<'
    end

    # What the Now Playing live page consumes: every snapshot heard since the
    # previous call, oldest first (so short notes are not lost between
    # renders), the newest of them, a generation that changes whenever
    # playback jumps (seek, new track) and history must restart, one that
    # changes only per track (the page keeps its selection across seeks),
    # and the output frame being heard at `sample_rate`.
    LiveState = Data.define(:snapshots, :latest, :generation, :track_generation, :frame, :sample_rate, :paused,
                            :mute_mask)
  end
end
