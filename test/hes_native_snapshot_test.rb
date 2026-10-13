# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'rubyplayer/backends/hes_native_lib'
require 'rubyplayer/hes/snapshot'
require_relative 'support/hes_builder'
require_relative 'support/rip_fixtures'

# Whether librp_hes's PSG snapshots describe what is heard, and when: the
# live page draws notes and levels from nothing else.
class HesNativeSnapshotTest < Minitest::Test
  Lib = RubyPlayer::Backends::HesNativeLib
  Snapshot = RubyPlayer::Hes::Snapshot
  Rips = TestSupport::RipFixtures
  RATE = 48_000
  CHUNK = 16_384
  PSG_CLOCK_HZ = 7_159_091
  # 262 scanlines of 455 clocks: libgme's HES VBlank period.
  VBLANK_PERIOD_CYCLES = 119_210
  VBLANK_FRAMES = RATE * VBLANK_PERIOD_CYCLES / PSG_CLOCK_HZ

  def test_snapshot_layout_unpacks_every_field
    values = [-7, 0b10_1010, 0b01_0101, 0xa5, 3, *(0x101..0x106), *(0x21..0x26), *(0x31..0x36), *(0x41..0x46),
              *(0x51..0x56), (0...192).map { |byte| byte & 0x1f }.pack('C*'), *(-6..-1), *(1001..1006), 119_210,
              PSG_CLOCK_HZ]
    snapshot = Snapshot.unpack("#{'x' * Snapshot::SIZE}#{values.pack(Snapshot::FORMAT)}".b, 1)

    assert_equal Snapshot::SIZE, Lib.rp_hes_snapshot_size
    assert_equal Snapshot::SIZE, values.pack(Snapshot::FORMAT).bytesize
    assert_equal [-7, 0b10_1010, 0b01_0101, 0xa5, 3], snapshot.to_h.values_at(:frame, :playing, :triggers,
                                                                              :master_balance, :selected_channel)
    assert_equal [0x101, 0x21, 0x31, 0x41, 0x51],
                 %i[period control balance noise dac].map { snapshot.public_send(it).first }
    assert_equal (32...64).map { |byte| byte & 0x1f }, snapshot.wave_samples(1)
    assert_equal [-6, -1, 1001, 1006], [*snapshot.output_left.minmax, *snapshot.output_right.minmax]
    assert_equal [119_210, PSG_CLOCK_HZ], [snapshot.vblank_period_cycles, snapshot.cpu_clock_hz]
  end

  # Five seconds of each rip: frames in order at a bounded rate, with the
  # emulator's clock and VBlank period. The first record is the state left by
  # the leading-silence skip (frame 0), or by the first driver call when the
  # track starts sounding at once.
  def test_real_rips_record_heard_time_snapshots
    { air_zonk: 1, alien_crush: 0, blazing_lazers: 0, dungeon_explorer: 0 }.each do |name, track|
      handle = open_rip(name, track)
      chunks = Array.new((5 * RATE) / CHUNK) { play(handle) }
      snapshots = chunks.flatten

      assert_operator chunks.first.first.frame, :<, VBLANK_FRAMES, "#{name} first record"
      chunks.each { |batch| assert_equal batch.map(&:frame).sort, batch.map(&:frame), "#{name} frame order" }
      assert_operator snapshots.size, :<=, 5 * 260, "#{name} snapshot rate"
      assert(snapshots.any? { |snapshot| snapshot.playing.positive? }, "#{name} never sounded")
      assert_equal [[VBLANK_PERIOD_CYCLES, PSG_CLOCK_HZ]],
                   snapshots.map { [it.vblank_period_cycles, it.cpu_clock_hz] }.uniq
    ensure
      Lib.rp_hes_close(handle) if handle
    end
  end

  # After a seek, the state shown must be the state heard at the new
  # position, even when libgme has emulated past it, and later states must
  # arrive when they are heard.
  def test_snapshots_after_a_seek_match_uninterrupted_playback
    seeks = [[:air_zonk, 1, 10], [:air_zonk, 1, 2_500], [:blazing_lazers, 0, 333], [:blazing_lazers, 0, 4_000]]
    seeks.each do |name, track, ms|
      reference = absolute(Array.new((6 * RATE) / CHUNK) { play(@reference_handle ||= open_rip(name, track)) })
      handle = open_rip(name, track)

      assert_equal 1, Lib.rp_hes_seek(handle, ms)
      Lib.rp_hes_capture_now(handle)
      captured = snapshots(handle)
      target = ms * RATE / 1000
      heard = reference.rfind { |snapshot| snapshot.frame <= target }
      expected = reference.select { |snapshot| snapshot.frame > target }

      assert_equal 0, captured.first.frame
      assert_equal state(heard), state(captured.first), "#{name} at #{ms} ms"
      ahead = captured.drop(1)

      assert_equal expected.first(ahead.size).map { |snapshot| [snapshot.frame - target, state(snapshot)] },
                   ahead.map { |snapshot| [snapshot.frame, state(snapshot)] }, "#{name} at #{ms} ms"
    ensure
      Lib.rp_hes_close(handle) if handle
      Lib.rp_hes_close(@reference_handle) if @reference_handle
      @reference_handle = nil
    end
  end

  # A key on and off inside one driver call must both reach the history,
  # the first with its trigger bit.
  def test_notes_shorter_than_a_driver_call_are_recorded
    built(:short_note_hes) do |handle|
      batches = Array.new(10) { play(handle) }
      snapshots = absolute(batches)
      triggered = snapshots.each_index.select { |index| snapshots[index].triggers.anybits?(1) }

      assert_operator @peak, :>, 0.01
      assert_operator triggered.size, :>=, 10
      triggered.each do |index|
        on, off = snapshots[index, 2]

        assert on.playing.anybits?(1), "trigger at frame #{on.frame} not sounding"
        refute off.playing.anybits?(1), "note at frame #{on.frame} never ended"
        assert_operator off.frame - on.frame, :<, VBLANK_FRAMES
      end
    end
  end

  # libgme calls its driver hook only near 60 Hz, so a 100 Hz timer driver
  # never triggers it; its volume steps must still arrive, but not every
  # write as its own record.
  def test_timer_driver_changes_arrive_at_a_bounded_rate
    built(:timer_volume_hes) do |handle|
      snapshots = absolute(Array.new((3 * RATE) / CHUNK) { play(handle) })
      seconds = snapshots.last.frame.fdiv(RATE)

      assert_operator snapshots.size / seconds, :>=, 50
      assert_operator snapshots.size / seconds, :<=, 250
      assert_operator snapshots.map { it.control.first & 0x1f }.uniq.size, :>, 20
    end
  end

  private

  def open_rip(name, track)
    path = Rips.path(name)
    open_data(File.binread(path), track, m3u: File.binread(path.sub(/\.hes\z/, '.m3u')))
  end

  def open_data(bytes, track, m3u: nil)
    handle = Lib.rp_hes_open(*buffer(bytes), RATE)

    refute_predicate handle, :null?
    assert_equal 1, Lib.rp_hes_load_m3u(handle, *buffer(m3u)) if m3u

    assert_equal 1, Lib.rp_hes_start_track(handle, track)
    handle
  end

  def built(builder)
    handle = open_data(TestSupport::HesBuilder.public_send(builder), 0)
    yield handle
  ensure
    Lib.rp_hes_close(handle) if handle
  end

  # One chunk of audio; returns that chunk's snapshots (frames relative to it).
  def play(handle)
    output = FFI::MemoryPointer.new(:float, CHUNK * 2)

    assert_equal 1, Lib.rp_hes_play(handle, output, CHUNK)
    @peak = [@peak || 0, *output.read_array_of_float(CHUNK * 2).map(&:abs)].max
    snapshots(handle)
  end

  def snapshots(handle)
    count = Lib.rp_hes_snapshot_count(handle)
    packed = count.zero? ? ''.b : Lib.rp_hes_snapshots(handle).read_bytes(count * Snapshot::SIZE)
    Array.new(count) { |index| Snapshot.unpack(packed, index) }
  end

  # Per-chunk snapshots at absolute output frames.
  def absolute(batches)
    batches.each_with_index.flat_map do |batch, chunk|
      batch.map { |snapshot| snapshot.with(frame: (chunk * CHUNK) + snapshot.frame) }
    end
  end

  def state(snapshot) = snapshot.to_h.except(:frame, :triggers)

  def buffer(bytes)
    data = FFI::MemoryPointer.new(:uchar, bytes.bytesize)
    data.put_bytes(0, bytes)
    [data, bytes.bytesize]
  end
end
