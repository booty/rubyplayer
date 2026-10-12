# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'rubyplayer/backends/nsf_native'
require 'rubyplayer/chip_timeline'
require 'rubyplayer/nsf/tracker'
require_relative 'support/rip_fixtures'
require_relative 'support/nsf_builder'

# Whether librp_nsf's chip snapshots describe what is heard, and when: the
# live page draws notes and levels from nothing else.
class NsfNativeSnapshotTest < Minitest::Test
  RATE = 48_000
  CHUNK = 16_384
  NoteLog = RubyPlayer::Vgm::NoteLog
  Rips = TestSupport::RipFixtures

  def test_notes_shorter_than_a_driver_call_are_recorded
    audio, snapshots, tracker = play_short_notes
    events = NoteLog.decode(tracker.snapshot.chips.first.details[:events]).select { |event| event.channel.zero? }
    triggered = snapshots.select { |snapshot| snapshot.triggers.anybits?(1) }

    assert_operator audio.unpack('e*').map(&:abs).max, :>, 0.01
    assert_operator triggered.size, :>=, 10
    assert(triggered.all? { |snapshot| snapshot.playing.anybits?(1) })
    assert_equal(triggered.size, events.count { |event| event.kind == :on })
    events.each_slice(2) do |on, off|
      assert_equal(%i[on off], [on.kind, off.kind])
      # At most two half frames (8.3 ms each) after the trigger.
      assert_operator off.sample - on.sample, :<=, 17 * 44_100 / 1000
    end
  end

  # Raw PCM has no enable or length counter: it sounds while the driver keeps
  # changing the level, and stops when the writes do.
  def test_mmc5_pcm_plays_while_its_level_changes
    audio, snapshots = play_built(TestSupport::NsfBuilder.mmc5_pcm_nsf, chunks: 6)
    pcm = 1 << 7 # 2A03 voices 0-4, MMC5 pulses 5-6, PCM 7
    sounding = snapshots.select { |snapshot| snapshot.playing.anybits?(pcm) }
    stopped = snapshots.find { |snapshot| snapshot.frame > sounding.last.frame }

    assert_operator audio.unpack('e*').map(&:abs).max, :>, 0.1
    assert_operator sounding.first.frame, :<, RATE / 10
    # 64 driver calls (~1.07 s) of writes, then off within a short hold.
    assert_in_delta 1.07 * RATE, sounding.last.frame, 0.05 * RATE
    refute stopped.playing.anybits?(pcm)
    assert_in_delta sounding.last.frame + (RATE / 20), stopped.frame, 0.02 * RATE
  end

  # The FDS volume envelope runs on its own between driver writes; each
  # audible gain step must be recorded when it happens.
  def test_fds_envelope_steps_are_recorded_as_they_happen
    audio, snapshots = play_built(TestSupport::NsfBuilder.fds_fade_nsf, chunks: 2)
    gains = snapshots.map(&:fds_env_gain)
    fading = snapshots.each_cons(2).select { |before, after| after.fds_env_gain < before.fds_env_gain }

    assert_operator audio.unpack('e*').map(&:abs).max, :>, 0.05
    assert_equal 32, gains.first
    assert_equal 0, gains.last
    assert_equal gains.sort.reverse, gains
    assert_operator fading.size, :>=, 30
    # Steps of 232 × 8 × 11 clocks (~11.4 ms) each, after one at once (libgme
    # starts the envelope's delay at 0).
    step = 232 * 8 * 11 * RATE / 1_789_773.0

    fading.drop(1).each { |before, after| assert_in_delta step, after.frame - before.frame, step / 4 }
    refute snapshots.last.playing.anybits?(1 << 5)
  end

  # After a seek, the state shown must be the state heard at the new
  # position, even when libgme has emulated past it, and later states must
  # arrive when they are heard.
  def test_snapshots_after_a_seek_match_uninterrupted_playback
    [[:mega_man_2, 1], [:mega_man_2, 333], [:castlevania_3_japan, 2_500], [:lagrange_point, 5_000]].each do |name, ms|
      reference = played_snapshots(name, seconds: 7)
      handle = RubyPlayer::Backends::NsfNative.new.open(Rips.path(name), 0, sample_rate: RATE)

      assert handle.seek(ms)
      packed, count = handle.capture_now
      captured = Array.new(count) { |index| RubyPlayer::Nsf::Snapshot.unpack(packed, index) }
      target = ms * RATE / 1000
      heard = reference.rfind { |snapshot| snapshot.frame <= target }

      assert_equal 0, captured.first.frame
      assert_equal state(heard), state(captured.first), "#{name} at #{ms} ms"
      ahead = captured.drop(1)
      expected = reference.select { |snapshot| snapshot.frame > target }.first(ahead.size)

      assert_equal(expected.map { |snapshot| [snapshot.frame - target, state(snapshot)] },
                   ahead.map { |snapshot| [snapshot.frame, state(snapshot)] }, "#{name} at #{ms} ms")
      handle.close
    end
  end

  private

  # `chunks` reads of an NSF built in memory: [audio, absolute-frame snapshots].
  def play_built(bytes, chunks:)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'built.nsf')
      File.binwrite(path, bytes)
      handle = RubyPlayer::Backends::NsfNative.new.open(path, 0, sample_rate: RATE)
      audio = +''.b
      snapshots = Array.new(chunks) do |chunk|
        audio << handle.read(CHUNK)
        absolute(handle, chunk)
      end
      handle.close
      [audio, snapshots.flatten]
    end
  end

  # 10 chunks of the short-note NSF through the native player and tracker:
  # [audio, absolute-frame snapshots, tracker].
  def play_short_notes
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'short.nsf')
      File.binwrite(path, TestSupport::NsfBuilder.short_note_nsf)
      handle = RubyPlayer::Backends::NsfNative.new.open(path, 0, sample_rate: RATE)
      tracker = RubyPlayer::Nsf::Tracker.new
      audio = +''.b
      snapshots = []
      10.times do |chunk|
        audio << handle.read(CHUNK)
        batch = absolute(handle, chunk)
        snapshots.concat(batch)
        tracker.update(RubyPlayer::ChipLiveState.new(snapshots: batch, latest: batch.last, generation: 1,
                                                     track_generation: 1, frame: (chunk + 1) * CHUNK,
                                                     sample_rate: RATE, paused: false, mute_mask: 0))
      end
      handle.close
      [audio, snapshots, tracker]
    end
  end

  # The latest read's snapshots, at absolute output frames.
  def absolute(handle, chunk)
    packed, count = handle.take_snapshots
    Array.new(count) do |index|
      snapshot = RubyPlayer::Nsf::Snapshot.unpack(packed, index)
      snapshot.with(frame: (chunk * CHUNK) + snapshot.frame)
    end
  end

  def played_snapshots(name, seconds:)
    @played ||= {}
    @played[name] ||= begin
      handle = RubyPlayer::Backends::NsfNative.new.open(Rips.path(name), 0, sample_rate: RATE)
      snapshots = Array.new(seconds * RATE / CHUNK) do |chunk|
        handle.read(CHUNK)
        absolute(handle, chunk)
      end
      handle.close
      snapshots.flatten
    end
  end

  def state(snapshot) = snapshot.to_h.except(:frame, :triggers)
end
