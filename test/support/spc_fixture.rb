# frozen_string_literal: true

# Reads the DSP registers and RAM an .spc file was dumped with.
module SpcFixture
  RAM_OFFSET = 0x100
  DSP_OFFSET = 0x10100

  module_function

  def path(name) = File.join(FIXTURES, 'spc', "#{name}.spc")
  def regs(name) = File.binread(path(name)).byteslice(DSP_OFFSET, 128).bytes
  def ram(name) = File.binread(path(name)).byteslice(RAM_OFFSET, 0x10000)
  def in_use(regs) = Array.new(8) { |voice| regs[(voice * 0x10) + 4] }.uniq
end
