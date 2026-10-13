# frozen_string_literal: true

require_relative '../chip_timeline'

module RubyPlayer
  module Hes
    VOICES = 6
    VOICE_NAMES = ['Wave 1', 'Wave 2', 'Wave 3', 'Wave 4', 'Multi 1', 'Multi 2'].freeze
    WAVE_STEPS = 32

    # One HuC6280 PSG state record from librp_hes (rp_hes_snapshot in
    # ext/rp_hes/rp_hes.h), taken when what is heard changes. `frame` is
    # relative to the first frame of the read that produced it until a
    # timeline makes it absolute. Bit fields are bit i for voice i; per-voice
    # arrays have one entry per voice. `period` is the 12-bit timer value,
    # not Hz. `wave` stays one packed String (32 bytes per voice) so a record
    # does not allocate 192 Integers.
    Snapshot = Data.define(:frame, :playing, :triggers, :master_balance, :selected_channel, :period, :control,
                           :balance, :noise, :dac, :wave, :output_left, :output_right, :vblank_period_cycles,
                           :cpu_clock_hz) do
      # Constants live in the class body below; a define block's lexical scope
      # is Hes, so they need a qualified lookup here.
      def self.unpack(packed, index)
        fields = packed.unpack(self::FORMAT, offset: index * self::SIZE)
        new(frame: fields[0], playing: fields[1], triggers: fields[2], master_balance: fields[3],
            selected_channel: fields[4], period: fields[5, VOICES].freeze, control: fields[11, VOICES].freeze,
            balance: fields[17, VOICES].freeze, noise: fields[23, VOICES].freeze, dac: fields[29, VOICES].freeze,
            wave: fields[35].freeze, output_left: fields[36, VOICES].freeze,
            output_right: fields[42, VOICES].freeze, vblank_period_cycles: fields[48], cpu_clock_hz: fields[49])
      end

      # Voice `voice`'s 32 five-bit wave samples.
      def wave_samples(voice) = wave.byteslice(voice * WAVE_STEPS, WAVE_STEPS).bytes
    end

    class Snapshot
      SIZE = 268
      # int32 frame; uint8 playing, triggers, master_balance, selected_channel;
      # uint16 period[6]; uint8 control[6], balance[6], noise[6], dac[6],
      # wave[6][32]; int16 output_left[6], output_right[6]; uint32
      # vblank_period_cycles, cpu_clock_hz.
      FORMAT = 'l<C4S<6C24a192s<12L<2'
    end

    LiveState = ChipLiveState
  end
end
