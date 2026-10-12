# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'rubyplayer/backends/gbs_native'
require 'rubyplayer/gbs/tracker'

# Whether librp_gbs's APU snapshots describe what is heard, and when: the
# live page draws notes and levels from nothing else.
class GbsNativeSnapshotTest < Minitest::Test
  RATE = 48_000
  CHUNK = 16_384
  SHANTAE = File.join(FIXTURES, 'shantae.gbs')
  NoteLog = RubyPlayer::Vgm::NoteLog

  # A VBlank-driven GBS whose play routine starts a one-tick (1/256 s) square
  # 1 note every 16th call: audible, but over long before the next call.
  def self.short_note_gbs
    init = [0x3e, 0x80, 0xe0, 0x26, # LD A,$80; LDH (NR52),A  power on
            0x3e, 0x77, 0xe0, 0x24, # LD A,$77; LDH (NR50),A  full master volume
            0x3e, 0xff, 0xe0, 0x25, # LD A,$FF; LDH (NR51),A  every voice to both sides
            0xc9]                   # RET
    play = [0x21, 0x00, 0xc0,       # LD HL,$C000             call counter
            0x34, 0x7e,             # INC (HL); LD A,(HL)
            0xe6, 0x0f, 0xc0,       # AND $0F; RET NZ         every 16th call
            0x3e, 0x3f, 0xe0, 0x11, # LD A,$3F; LDH (NR11),A  length 1 tick
            0x3e, 0xf0, 0xe0, 0x12, # LD A,$F0; LDH (NR12),A  volume 15, held
            0x3e, 0x00, 0xe0, 0x13, # LD A,$00; LDH (NR13),A
            0x3e, 0xc7, 0xe0, 0x14, # LD A,$C7; LDH (NR14),A  trigger, length on
            0xc9]                   # RET
    load = 0x400
    header = ['GBS', 1, 1, 1, load, load, load + init.size, 0xfffe, 0, 0, 'Short notes', '', '']
             .pack('a3CCCS<S<S<S<CCa32a32a32')
    header + (init + play).pack('C*')
  end

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
      # At most one length tick (3.9 ms) after the trigger.
      assert_operator off.sample - on.sample, :<=, 4 * 44_100 / 1000
    end
  end

  # After a seek, the state shown must be the state heard at the new
  # position, even when libgme has emulated past it, and later states must
  # arrive when they are heard.
  def test_snapshots_after_a_seek_match_uninterrupted_playback
    [[1, 1], [1, 10], [1, 333], [0, 2_500], [1, 5_000]].each do |track, ms|
      reference = played_snapshots(track, seconds: 7)
      handle = RubyPlayer::Backends::GbsNative.new.open(SHANTAE, track, sample_rate: RATE)

      assert handle.seek(ms)
      packed, count = handle.capture_now
      captured = Array.new(count) { |index| RubyPlayer::Gbs::Snapshot.unpack(packed, index) }
      target = ms * RATE / 1000
      expected = reference.select { |snapshot| snapshot.frame > target }
      heard = reference.rfind { |snapshot| snapshot.frame <= target }

      assert_equal 0, captured.first.frame
      assert_equal state(heard), state(captured.first), "track #{track} at #{ms} ms"
      ahead = captured.drop(1)

      assert_equal expected.first(ahead.size).map { |snapshot| [snapshot.frame - target, state(snapshot)] },
                   ahead.map { |snapshot| [snapshot.frame, state(snapshot)] }, "track #{track} at #{ms} ms"
      handle.close
    end
  end

  private

  # 10 chunks of the short-note GBS through the native player and tracker:
  # [audio, absolute-frame snapshots, tracker].
  def play_short_notes
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'short.gbs')
      File.binwrite(path, self.class.short_note_gbs)
      handle = RubyPlayer::Backends::GbsNative.new.open(path, 0, sample_rate: RATE)
      tracker = RubyPlayer::Gbs::Tracker.new
      audio = +''.b
      snapshots = []
      10.times do |chunk|
        audio << handle.read(CHUNK)
        batch = absolute(handle, chunk)
        snapshots.concat(batch)
        tracker.update(live(batch, (chunk + 1) * CHUNK))
      end
      handle.close
      [audio, snapshots, tracker]
    end
  end

  # The latest read's snapshots, at absolute output frames.
  def absolute(handle, chunk)
    packed, count = handle.take_snapshots
    Array.new(count) do |index|
      snapshot = RubyPlayer::Gbs::Snapshot.unpack(packed, index)
      snapshot.with(frame: (chunk * CHUNK) + snapshot.frame)
    end
  end

  def played_snapshots(track, seconds:)
    @played ||= {}
    @played[track] ||= begin
      handle = RubyPlayer::Backends::GbsNative.new.open(SHANTAE, track, sample_rate: RATE)
      snapshots = Array.new(seconds * RATE / CHUNK) do |chunk|
        handle.read(CHUNK)
        absolute(handle, chunk)
      end
      handle.close
      snapshots.flatten
    end
  end

  def state(snapshot) = snapshot.to_h.except(:frame, :triggers)

  def live(snapshots, frame)
    RubyPlayer::Gbs::LiveState.new(snapshots: snapshots, latest: snapshots.last, generation: 1, track_generation: 1,
                                   frame: frame, sample_rate: RATE, paused: false, mute_mask: 0)
  end
end
