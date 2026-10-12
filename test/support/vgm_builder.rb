# frozen_string_literal: true

require 'stringio'
require 'zlib'

# Small byte-level VGM fixture writer. It intentionally does not call the
# production reader so tests can verify the parser against independent bytes.
class VgmBuilder
  HEADER_SIZE = 0x40

  attr_reader :commands

  def initialize(sn76489_clock: 3_579_545, ym2612_clock: nil, ym2413_clock: nil,
                 ym2151_clock: nil)
    @commands = +''.b
    @sn76489_clock = sn76489_clock
    @ym2612_clock = ym2612_clock
    @ym2413_clock = ym2413_clock
    @ym2151_clock = ym2151_clock
    @loop_command_offset = nil
    @total_samples = 0
  end

  def psg(value)
    @commands << [0x50, value].pack('C*')
    self
  end

  def psg_stereo(value)
    @commands << [0x4f, value].pack('C*')
    self
  end

  def ym2612(port, register, value)
    @commands << [port.zero? ? 0x52 : 0x53, register, value].pack('C*')
    self
  end

  def ym2413(register, value)
    @commands << [0x51, register, value].pack('C*')
    self
  end

  def data_block(type:, data:)
    payload = String(data).b
    @commands << [0x67, 0x66, type].pack('C*')
    @commands << [payload.bytesize].pack('V') << payload
    self
  end

  def pcm_seek(address)
    @commands << [0xe0, address].pack('CV')
    self
  end

  def dac_wait(samples)
    remaining = Integer(samples)
    raise ArgumentError, 'wait must be nonnegative' if remaining.negative?

    while remaining.positive?
      count = [remaining, 15].min
      @commands << [0x80 + count].pack('C')
      @total_samples += count
      remaining -= count
    end
    self
  end

  def wait_override(command:, samples:)
    @commands << [0x64, command, samples].pack('CCv')
    self
  end

  def raw_command(bytes)
    @commands << String(bytes).b
    self
  end

  def wait(samples)
    remaining = Integer(samples)
    raise ArgumentError, 'wait must be nonnegative' if remaining.negative?

    while remaining.positive?
      count = [remaining, 65_535].min
      @commands << [0x61, count].pack('Cv')
      @total_samples += count
      remaining -= count
    end
    self
  end

  def loop_here
    @loop_command_offset = HEADER_SIZE + @commands.bytesize
    self
  end

  def end
    @commands << "\x66".b
    self
  end

  def bytes
    commands = @commands.dup
    commands << "\x66".b unless commands.getbyte(-1) == 0x66

    header = Array.new(HEADER_SIZE, 0).pack('C*')
    header[0, 4] = 'Vgm '.b
    write_u32(header, 0x04, HEADER_SIZE + commands.bytesize - 4)
    write_u32(header, 0x08, 0x0000_0151)
    write_u32(header, 0x0c, @sn76489_clock || 0)
    write_u32(header, 0x10, @ym2413_clock || 0)
    write_u32(header, 0x30, @ym2151_clock || 0)
    write_u32(header, 0x18, @total_samples)
    write_u32(header, 0x1c, @loop_command_offset - 0x1c) if @loop_command_offset
    write_u32(header, 0x2c, @ym2612_clock || 0)
    header + commands
  end

  def gzip
    io = StringIO.new(''.b)
    gzip = Zlib::GzipWriter.new(io)
    gzip.write(bytes)
    gzip.finish
    io.string
  end

  private

  def write_u32(buffer, offset, value)
    buffer[offset, 4] = [value].pack('V')
  end
end
