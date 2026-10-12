# frozen_string_literal: true

require 'test_helper'
require_relative 'support/spc_fixture'
require 'rubyplayer/spc/brr'

class SpcBrrTest < Minitest::Test
  Brr = RubyPlayer::Spc::Brr

  def test_directory_entry_of_megaton_walk
    regs = SpcFixture.regs('earthbound-megaton-walk')
    entries = Brr.directory(SpcFixture.ram('earthbound-megaton-walk'), regs[0x5d], in_use: SpcFixture.in_use(regs))
    entry = entries.find { |item| item[:srcn] == 27 }

    assert_equal [0x95b0, 0xcdf0, true], entry.values_at(:start, :loop, :valid)
    assert_equal 1_600, entry[:info][:blocks]
    refute entry[:info][:looped]
  end

  # FF6 leaves directory slots 8-31 unused yet plays sample 32: scanning must
  # not stop at the first invalid slot.
  def test_sparse_directory_still_lists_samples_in_use
    entries = Brr.directory(SpcFixture.ram('aria-de-mezzo-carattere'), 0x1b, in_use: [32, 5])
    numbers = entries.map { |entry| entry[:srcn] }

    assert_includes numbers, 32
    assert_includes numbers, 5
    assert_equal (0..7).to_a + (32..37).to_a, numbers
  end

  # Junk slots past the real directory can pass sample checks by chance; the
  # gap rule keeps them out of every fixture's listing.
  def test_directory_listings_stop_at_the_real_directorys_end
    Dir[File.join(FIXTURES, 'spc', '*.spc')].each do |path|
      name = File.basename(path, '.spc')
      regs = SpcFixture.regs(name)
      in_use = SpcFixture.in_use(regs)
      entries = Brr.directory(SpcFixture.ram(name), regs[0x5d], in_use: in_use)

      assert_empty(entries.reject { |entry| entry[:srcn] < 64 }, name)
      assert_equal in_use.sort, (in_use & entries.map { |entry| entry[:srcn] }).sort, name
      assert_empty(entries.select { |entry| in_use.include?(entry[:srcn]) }.reject { |entry| entry[:valid] }, name)
    end
  end

  def test_sample_info_and_decode_of_a_hand_built_block
    ram = "\0".b * 0x10000
    # Shift 4, filter 0, end bit; nibbles 1, -1, 7, -8 then zeros.
    ram[0x300, 9] = [0x41, 0x1f, 0x78, 0, 0, 0, 0, 0, 0].pack('C*')

    assert_equal({ blocks: 1, samples: 16, bytes: 9, looped: false, end_addr: 0x300 },
                 Brr.sample_info(ram, 0x300, 0x300))
    assert_equal [8, -8, 56, -64], Brr.decode(ram, 0x300, max_samples: 4)
  end

  def test_decode_stops_at_the_end_block
    ram = "\0".b * 0x10000
    ram[0x300, 9] = [0x01, *Array.new(8, 0x11)].pack('C*')

    assert_equal 16, Brr.decode(ram, 0x300, max_samples: 100).size
  end
end
