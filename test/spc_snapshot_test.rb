# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/backends/snes_spc'
require 'rubyplayer/spc/snapshot'

class SpcSnapshotTest < Minitest::Test
  SPC = File.join(FIXTURES, 'spc', 'earthbound-megaton-walk.spc')
  RATE = 48_000
  CHUNK = 16_384
  # libgme's resampler emulates ~50 ms per call and we snapshot once per call.
  SNAPSHOT_STEP_FRAMES = RATE / 20

  def setup
    @handle = RubyPlayer::Backends::SnesSpc.new.open(SPC, 0, sample_rate: RATE)
  end

  def teardown
    @handle.close
  end

  def test_each_read_yields_evenly_spaced_snapshots
    @handle.read(CHUNK)
    snapshots = decoded_snapshots

    assert_includes 6..7, snapshots.size
    assert_equal [SNAPSHOT_STEP_FRAMES], snapshots.map(&:frame).each_cons(2).map { |a, b| b - a }.uniq
  end

  def test_registers_match_the_files_dsp_state_near_the_start
    file_regs = File.binread(SPC).byteslice(0x10100, 128).bytes
    @handle.read(CHUNK)
    regs = decoded_snapshots.first.regs

    { dir: 0x5d, esa: 0x6d, edl: 0x7d }.each do |name, address|
      assert_equal file_regs[address], regs[address], name.to_s
    end
    fir = (0..7).map { |tap| (tap * 0x10) + 0x0f }

    assert_equal file_regs.values_at(*fir), regs.values_at(*fir)
  end

  def test_voice_state_is_in_range_and_notes_register_as_attack_edges
    snapshots = Array.new(10) do
      @handle.read(CHUNK)
      decoded_snapshots
    end.flatten

    assert(snapshots.all? { |snapshot| snapshot.env.all? { |level| level.between?(0, 0x7ff) } })
    assert(snapshots.all? { |snapshot| snapshot.env_mode.all? { |mode| mode.between?(0, 3) } })
    refute_equal 0, snapshots.map(&:attack_edges).reduce(0, :|)
  end

  def test_snapshots_are_only_from_the_latest_read
    @handle.read(CHUNK)
    first, = @handle.take_snapshots
    @handle.read(CHUNK)
    second, count = @handle.take_snapshots

    refute_equal first, second
    assert_equal count * RubyPlayer::Spc::Snapshot::SIZE, second.bytesize
  end

  def test_ram_copy_holds_the_sample_directory
    @handle.read(CHUNK)
    ram = @handle.copy_ram

    assert_equal 0x10000, ram.bytesize
    assert_predicate ram, :frozen?
    assert_equal 0x95b0, ram.byteslice(0x6c00 + (27 * 4), 2).unpack1('v')
  end

  def test_closed_handle_has_no_snapshots_or_ram
    @handle.close

    assert_equal ['', 0], @handle.take_snapshots
    assert_nil @handle.copy_ram
  end

  private

  def decoded_snapshots
    packed, count = @handle.take_snapshots
    Array.new(count) { |index| RubyPlayer::Spc::Snapshot.unpack(packed, index) }
  end
end
