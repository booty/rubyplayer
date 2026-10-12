# frozen_string_literal: true

module RubyPlayer
  module Spc
    VOICES = 8

    # One S-DSP state record from librp_spc (rp_spc_snapshot in
    # ext/rp_spc/rp_spc.h). `frame` is relative to the first frame of the read
    # that produced it; Spc::Timeline turns that into an output-timeline frame.
    Snapshot = Data.define(:frame, :regs, :env, :env_mode, :brr_addr, :attack_edges) do
      # Constants live in the class body below; a define block's lexical scope
      # is Spc, so they need a qualified lookup here.
      def self.unpack(packed, index)
        fields = packed.unpack(self::FORMAT, offset: index * self::SIZE)
        new(frame: fields[0], regs: fields[1, 128].freeze, env: fields[129, VOICES].freeze,
            env_mode: fields[137, VOICES].freeze, brr_addr: fields[145, VOICES].freeze,
            attack_edges: fields[153])
      end
    end

    # What the Now Playing live page renders: the snapshot being heard (nil
    # until the first one plays) and the latest SPC RAM copy.
    LiveState = Data.define(:snapshot, :ram, :paused)

    class Snapshot
      SIZE = 176
      # uint32 frame, uint8 regs[128], uint16 env[8], uint8 env_mode[8],
      # uint16 brr_addr[8], uint8 attack_edges, 3 pad bytes.
      FORMAT = 'L<C128S<8C8S<8Cx3'
      ENV_MODES = %i[release attack decay sustain].freeze
    end
  end
end
