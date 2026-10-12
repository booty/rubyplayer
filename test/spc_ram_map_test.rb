# frozen_string_literal: true

require 'test_helper'
require_relative 'support/spc_fixture'
require 'rubyplayer/spc/dsp'
require 'rubyplayer/spc/brr'
require 'rubyplayer/spc/ram_map'

class SpcRamMapTest < Minitest::Test
  Spc = RubyPlayer::Spc

  def test_regions_cover_ram_without_gaps
    regions = regions_for('earthbound-megaton-walk')

    assert_equal 0, regions.first[:from]
    assert_equal 0x10000, regions.last[:to]
    regions.each_cons(2) { |left, right| assert_equal left[:to], right[:from] }
    assert_equal %i[directory echo other samples], regions.map { |region| region[:kind] }.uniq.sort
  end

  def test_maximum_echo_buffer_on_confusing_melody
    echo = regions_for('confusing-melody').select { |region| region[:kind] == :echo }

    assert_equal([[0x7900, 0x7900 + 30_720]], echo.map { |region| region.values_at(:from, :to) })
  end

  def test_directory_region_starts_at_dir
    directory = regions_for('earthbound-megaton-walk').find { |region| region[:kind] == :directory }

    assert_equal 0x6c00, directory[:from]
  end

  private

  def regions_for(name)
    regs = SpcFixture.regs(name)
    global = Spc::Dsp.global(regs)
    directory = Spc::Brr.directory(SpcFixture.ram(name), global[:dir], in_use: SpcFixture.in_use(regs))
    Spc::RamMap.regions(global: global, directory: directory)
  end
end
