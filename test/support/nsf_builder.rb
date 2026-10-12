# frozen_string_literal: true

module TestSupport
  # Hand-assembled NSF files for tests that need exact, known driver behavior.
  module NsfBuilder
    LOAD = 0x8000

    # A one-song NTSC NSF at $8000: `init` then `play` (6502 bytes).
    def self.nsf(init, play, chips: 0, title: 'Test')
      header = ['NESM', 0x1a, 1, 1, 1, LOAD, LOAD, LOAD + init.size, title, '', '', 16_666, "\0" * 8, 20_000,
                0, chips, "\0" * 4].pack('a4CCCCS<S<S<a32a32a32S<a8S<CCa4')
      header + (init + play).pack('C*')
    end

    # Starts a pulse 1 note with the shortest length counter load (2 half
    # frames, under 17 ms) every 16th call: audible, but over by the next
    # call.
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
      nsf(init, play, title: 'Short notes')
    end

    # MMC5 PCM: the first 64 calls toggle $5011 between 0 and 127 (a 30 Hz
    # square), then the writes stop.
    def self.mmc5_pcm_nsf
      play = [0xa5, 0x01, 0xc9, 0x40,       # LDA $01; CMP #$40      call counter
              0xb0, 0x0b, 0xe6, 0x01,       # BCS +11; INC $01       stop for good after 64 calls
              0xa5, 0x00, 0x49, 0x7f,       # LDA $00; EOR #$7F
              0x85, 0x00, 0x8d, 0x11, 0x50, # STA $00; STA $5011     PCM level 0 / 127
              0x60]                         # RTS
      nsf([0x60], play, chips: 0x08, title: 'MMC5 PCM')
    end

    # FDS: init loads a sawtooth wave and starts one note at gain 32 with a
    # decreasing envelope; the driver never writes again, so the note fades
    # out on its own (32 steps of ~11 ms).
    def self.fds_fade_nsf
      init = [0xa9, 0x80, 0x8d, 0x89, 0x40, # $4089: wave RAM writable
              0xa2, 0x3f,                   # LDX #$3F
              0x8a, 0x9d, 0x40, 0x40,       # loop: TXA; STA $4040,X  sawtooth
              0xca, 0x10, 0xf9,             # DEX; BPL loop
              0xa9, 0x00, 0x8d, 0x89, 0x40, # $4089: wave RAM playing, master volume 100%
              0xa9, 0xe8, 0x8d, 0x8a, 0x40, # $408A: envelope base speed
              0xa9, 0xa0, 0x8d, 0x80, 0x40, # $4080: gain 32 now
              0xa9, 0x0a, 0x8d, 0x80, 0x40, # $4080: then decrease, speed 10
              0xa9, 0x00, 0x8d, 0x82, 0x40, # $4082: frequency low
              0xa9, 0x02, 0x8d, 0x83, 0x40, # $4083: frequency high 2: ~218 Hz, wave on
              0x60]                         # RTS
      nsf(init, [0x60], chips: 0x04, title: 'FDS fade')
    end
  end
end
