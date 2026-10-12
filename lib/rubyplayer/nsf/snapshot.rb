# frozen_string_literal: true

module RubyPlayer
  module Nsf
    # NSF header expansion-chip flags.
    CHIPS = { vrc6: 0x01, vrc7: 0x02, fds: 0x04, mmc5: 0x08, n163: 0x10, s5b: 0x20 }.freeze

    # libgme's voice numbers (its mute bits) for an NSF's chips: the 2A03's
    # five, then each present expansion chip's, in libgme's order.
    class Voices
      ORDER = [[:vrc6, 3], [:n163, 8], [:s5b, 3], [:fds, 1], [:mmc5, 3], [:vrc7, 6]].freeze
      APU = 5

      attr_reader :count

      def initialize(chips)
        @bases = {}
        @count = APU
        ORDER.each do |chip, size|
          next unless chips.anybits?(CHIPS.fetch(chip))

          @bases[chip] = @count
          @count += size
        end
      end

      # First voice of `chip`, or nil when the NSF does not use it.
      def base(chip) = chip == :apu ? 0 : @bases[chip]

      def chips = @bases.keys
    end

    # One chip state record from librp_nsf (rp_nsf_snapshot in
    # ext/rp_nsf/rp_nsf.h), taken when what is heard changes. `frame` is
    # relative to the first frame of the read that produced it until a
    # timeline makes it absolute. Bit fields are by libgme voice (Voices).
    # Register blocks stay binary Strings (read with #getbyte): most of a
    # record is chips the NSF lacks, and the tracker reads few of them.
    Snapshot = Data.define(:frame, :playing, :triggers, :play_period, :clock_rate, :chips, :pal, :voice_count,
                           :apu_regs, :apu_status, :apu_frame_mode, :apu_volume, :tri_linear, :dmc_dac,
                           :apu_length, :dmc_address, :mmc5_regs, :mmc5_status, :mmc5_volume, :mmc5_pcm,
                           :mmc5_length, :vrc6_regs, :s5b_regs, :vrc7_custom, :vrc7_regs, :fds_regs, :fds_env_gain,
                           :fds_sweep_gain, :fds_wave, :fds_mod, :n163, :n163_active) do
      # Constants live in the class body below; a define block's lexical scope
      # is Nsf, so they need a qualified lookup here.
      def self.unpack(packed, index)
        fields = packed.unpack(self::FORMAT, offset: index * self::SIZE)
        offset = 0
        new(**self::COUNTS.to_h do |name, count|
          value = count == 1 ? fields[offset] : fields[offset, count].freeze
          offset += count
          [name, value]
        end)
      end

      # Music-driver calls per second (NTSC ~60.1 Hz, PAL 50 Hz; NSFs may
      # set their own rate).
      def driver_hz = play_period.positive? ? clock_rate.fdiv(play_period) : nil

      def chip?(chip) = chips.anybits?(CHIPS.fetch(chip))
      def pal? = pal == 1
    end

    class Snapshot
      SIZE = 380
      # int32 frame; uint32 playing, triggers, play_period, clock_rate; uint8
      # chips, pal, voice_count, pad; 2A03: regs[20], status, frame mode,
      # volume[3], linear counter, DMC DAC, pad, uint16 length[5], DMC
      # address; MMC5: regs[8], status, volume[2], PCM, uint16 length[2];
      # VRC6 regs[9]; 5B regs[14]; VRC7 custom[8], regs[18]; FDS regs[19],
      # envelope gain, sweep gain, pad, wave[64], mod[32]; N163 RAM[128],
      # active channels, pad[3].
      FORMAT = 'l<L<4CCCxa20CCC3CCxS<5S<a8CC2CS<2a9a14a8a18a19CCxa64a32a128Cx3'
      # How many unpacked values each field takes, in FORMAT order; arrays
      # where more than one.
      COUNTS = members.to_h { |name| [name, 1] }.merge(apu_volume: 3, apu_length: 5, mmc5_volume: 2,
                                                       mmc5_length: 2).freeze
    end
  end
end
