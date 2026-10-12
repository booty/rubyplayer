# frozen_string_literal: true

module TestSupport
  # Hand-assembled NSF files for tests that need exact, known driver behavior.
  module NsfBuilder
    # An NTSC NSF whose play routine starts a pulse 1 note with the shortest
    # length counter load (2 half frames, under 17 ms) every 16th call: audible,
    # but over by the next call.
    def self.short_note_nsf
      init = [0xa9, 0x01, 0x8d, 0x15, 0x40, # LDA #$01; STA $4015  pulse 1 on
              0xa9, 0x00, 0x85, 0x00,       # LDA #$00; STA $00    call counter
              0x60]                         # RTS
      play = [0xe6, 0x00, 0xa5, 0x00,       # INC $00; LDA $00
              0x29, 0x0f, 0xd0, 0x14,       # AND #$0F; BNE +20    every 16th call
              0xa9, 0x1f, 0x8d, 0x00, 0x40, # $4000: duty 12.5%, constant volume 15
              0xa9, 0x00, 0x8d, 0x01, 0x40, # $4001: sweep off
              0xa9, 0x80, 0x8d, 0x02, 0x40, # $4002: period low
              0xa9, 0x18, 0x8d, 0x03, 0x40, # $4003: length index 3 (2), period high 0
              0x60]                         # RTS
      load = 0x8000
      header = ['NESM', 0x1a, 1, 1, 1, load, load, load + init.size, 'Short notes', '', '', 16_666, "\0" * 8, 20_000,
                0, 0, "\0" * 4].pack('a4CCCCS<S<S<a32a32a32S<a8S<CCa4')
      header + (init + play).pack('C*')
    end
  end
end
