# frozen_string_literal: true

require_relative '../chip_timeline'

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
                           :driver_period_cycles, :cpu_clock_hz) do
      # Constants live in the class body below; a define block's lexical scope
      # is Gbs, so they need a qualified lookup here.
      def self.unpack(packed, index)
        fields = packed.unpack(self::FORMAT, offset: index * self::SIZE)
        new(frame: fields[0], regs: fields[1, 48].freeze, volume: fields[49, VOICES].freeze,
            playing: fields[53], enabled: fields[54], triggers: fields[55], length: fields[56, VOICES].freeze,
            sweep_freq: fields[60], driver_period_cycles: fields[61], cpu_clock_hz: fields[62])
      end

      # Music-driver calls per second (VBlank is ~59.7 Hz; timer drivers vary).
      def driver_hz = driver_period_cycles.positive? ? cpu_clock_hz.fdiv(driver_period_cycles) : nil
    end

    class Snapshot
      SIZE = 80
      # int32 frame, uint8 regs[48], uint8 volume[4], uint8 playing, enabled,
      # triggers, pad, uint16 length[4], uint16 sweep_freq, pad, uint32
      # driver_period_cycles, uint32 cpu_clock_hz.
      FORMAT = 'l<C48C4CCCxS<4S<x2L<L<'
    end

    LiveState = ChipLiveState
  end
end
