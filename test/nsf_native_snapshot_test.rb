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
