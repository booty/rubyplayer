# frozen_string_literal: true

module TestSupport
  # Tiny HES files whose drivers exercise exact PSG timing: one 8 KB ROM bank
  # mapped at $E000 holding init code, an interrupt handler, and its vector.
  # MPR0 maps I/O (PSG at $0800), MPR1 maps RAM at $2000.
  module HesBuilder
    BANK_BYTES = 0x2000
    BASE_ADDR = 0xE000
    VDP_VECTOR = 0xFFF8
    TIMER_VECTOR = 0xFFFA
    # HuC6280 PSG and interrupt registers, as libgme maps them.
    PSG_LATCH = 0x0800
    PSG_MASTER_BALANCE = 0x0801
    PSG_PERIOD_LOW = 0x0802
    PSG_PERIOD_HIGH = 0x0803
    PSG_CONTROL = 0x0804
    PSG_BALANCE = 0x0805
    PSG_DATA = 0x0806
    VDP_SELECT = 0x0000
    VDP_DATA = 0x0002
    TIMER_RELOAD = 0x0C00
    TIMER_ENABLE = 0x0C01
    IRQ_DISABLE = 0x1402
    IRQ_ACKNOWLEDGE = 0x1403
    COUNTER = 0x2000

    # A VBlank driver that, every 16th call, keys voice 0 on for about 1 ms
    # and off again: a note shorter than one driver period.
    def self.short_note_hes
      build(vector: VDP_VECTOR) do |asm|
        asm.label(:init)
        setup_square_voice(asm)
        asm.lda_imm(5).sta(VDP_SELECT).lda_imm(0x08).sta(VDP_DATA) # VDP register 5: VBlank interrupt on
        asm.lda_imm(0x05).sta(IRQ_DISABLE)                          # only the VDP interrupt
        asm.cli.rts
        asm.label(:irq)
        asm.pha.lda_abs(VDP_SELECT)                                 # acknowledge VBlank
        asm.inc(COUNTER).lda_abs(COUNTER).and_imm(0x0f).bne(:done)
        asm.stz(PSG_LATCH).lda_imm(0x9f).sta(PSG_CONTROL)           # key on, volume 31
        asm.ldy_imm(6).label(:outer).ldx_imm(0).label(:inner).dex.bne(:inner).dey.bne(:outer)
        asm.lda_imm(0x1f).sta(PSG_CONTROL)                          # key off
        asm.label(:done).pla.rti
      end
    end

    # A timer driver at about 100 Hz (never near libgme's 60 Hz driver-call
    # hook) that steps voice 0's volume on every call while it stays keyed.
    def self.timer_volume_hes
      build(vector: TIMER_VECTOR) do |asm|
        asm.label(:init)
        setup_square_voice(asm)
        asm.lda_imm(0x9f).sta(PSG_CONTROL)
        asm.lda_imm(69).sta(TIMER_RELOAD).lda_imm(1).sta(TIMER_ENABLE) # 70 * 1024 clocks
        asm.lda_imm(0x03).sta(IRQ_DISABLE)                             # only the timer interrupt
        asm.cli.rts
        asm.label(:irq)
        asm.pha.sta(IRQ_ACKNOWLEDGE)
        asm.inc(COUNTER).lda_abs(COUNTER).and_imm(0x1f).ora_imm(0x80).sta(PSG_CONTROL)
        asm.pla.rti
      end
    end

    # Voice 0: full balance, a 32-step square wave, period $100 (437 Hz).
    def self.setup_square_voice(asm)
      asm.lda_imm(0xff).sta(PSG_MASTER_BALANCE).stz(PSG_LATCH).sta(PSG_BALANCE)
      asm.stz(PSG_CONTROL)
      asm.ldy_imm(16).lda_imm(0x1f).label(:high).sta(PSG_DATA).dey.bne(:high)
      asm.ldy_imm(16).lda_imm(0x00).label(:low).sta(PSG_DATA).dey.bne(:low)
      asm.stz(PSG_PERIOD_LOW).lda_imm(1).sta(PSG_PERIOD_HIGH)
    end

    def self.build(vector:)
      asm = Assembler.new(BASE_ADDR)
      yield asm
      bank = asm.bytes.ljust(BANK_BYTES, "\0".b)
      handler = asm.address(:irq)
      bank[vector - BASE_ADDR, 2] = [handler].pack('S<')
      header = ['HESM', 0, 0, asm.address(:init), [0xff, 0xf8, 0, 0, 0, 0, 0, 0], 'DATA', BANK_BYTES, 0, 0]
      header.flatten.pack('a4CCS<C8a4L<L<L<') + bank
    end

    # Just the HuC6280 (65C02) opcodes the drivers above use.
    class Assembler
      OPCODES = { lda_imm: 0xa9, ldx_imm: 0xa2, ldy_imm: 0xa0, and_imm: 0x29, ora_imm: 0x09,
                  sta: 0x8d, stz: 0x9c, lda_abs: 0xad, inc: 0xee, bne: 0xd0,
                  dex: 0xca, dey: 0x88, pha: 0x48, pla: 0x68, cli: 0x58, rts: 0x60, rti: 0x40 }.freeze

      def initialize(origin)
        @origin = origin
        @bytes = +''.b
        @labels = {}
        @branches = []
      end

      def label(name)
        @labels[name] = @origin + @bytes.bytesize
        self
      end

      def address(name) = @labels.fetch(name)

      def bytes
        @branches.each do |offset, target|
          @bytes.setbyte(offset, (address(target) - (@origin + offset + 1)) & 0xff)
        end
        @bytes
      end

      %i[lda_imm ldx_imm ldy_imm and_imm ora_imm].each do |name|
        define_method(name) { |value| emit(OPCODES[name], value) }
      end

      %i[sta stz lda_abs inc].each do |name|
        define_method(name) { |addr| emit(OPCODES[name], addr & 0xff, addr >> 8) }
      end

      %i[dex dey pha pla cli rts rti].each do |name|
        define_method(name) { emit(OPCODES[name]) }
      end

      def bne(target)
        emit(OPCODES[:bne], 0)
        @branches << [@bytes.bytesize - 1, target]
        self
      end

      private

      def emit(*values)
        @bytes << values.pack('C*')
        self
      end
    end
  end
end
