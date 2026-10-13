# frozen_string_literal: true

require 'test_helper'
require 'stringio'
require 'rubyplayer/gbs/tracker'
require 'rubyplayer/nsf/tracker'
require 'rubyplayer/ui/screen'
require 'rubyplayer/ui/chip_live_view'

# Length counters travel from tracker details (in hardware ticks) to panel
# text (in ms). Renaming the detail keys once left no test exercising this
# path, so a producer/consumer key mismatch would only fail on a live page.
class LiveLengthCounterTest < Minitest::Test
  THEME = RubyPlayer::Theme::DEFAULT
  RATE = 44_100
  TRIGGER_FRAME = 4_410

  # Game Boy length counters tick at 256 Hz: 40 of a 64-tick load left is
  # 156 of 250 ms, and the envelope chart cuts off at the full load.
  def test_game_boy_square_shows_length_left_and_cutoff
    regs = Array.new(48, 0)
    regs[1] = 0x00 # NR11: length data 0, so the counter loads 64 ticks
    regs[2] = 0xc3 # NR12: volume 12, down, pace 3
    regs[4] = 0x40 # NR14: length counter on
    snapshot = RubyPlayer::Gbs::Snapshot.new(
      frame: TRIGGER_FRAME, regs: regs, volume: [12, 0, 0, 0], playing: 1, enabled: 1, triggers: 1,
      length: [40, 0, 0, 0], sweep_freq: 0, driver_period_cycles: 70_224, cpu_clock_hz: 4_194_304
    )
    tracker = RubyPlayer::Gbs::Tracker.new
    tracker.update(RubyPlayer::Gbs::LiveState.new(snapshots: [snapshot], latest: snapshot, generation: 1,
                                                  track_generation: 1, frame: TRIGGER_FRAME, sample_rate: RATE,
                                                  paused: false, mute_mask: 0))
    text = render('GBS', tracker.snapshot)

    assert_includes text, 'Length 156 ms left of 250 ms'
    assert_includes text, 'cut at 250 ms'
  end

  # NES length counters tick at half the ~240 Hz NTSC quarter-frame rate:
  # 30 ticks is 250 ms, all still ahead right at the trigger.
  def test_nes_pulse_shows_length_left_and_cutoff
    zero = RubyPlayer::Nsf::Snapshot.unpack(("\0" * RubyPlayer::Nsf::Snapshot::SIZE).b, 0)
    apu_regs = "\x8f".b + ("\0" * 19).b # $4000: 50% duty, envelope period 15, no loop
    snapshot = zero.with(frame: TRIGGER_FRAME, playing: 1, triggers: 1, driver_period_cycles: 29_830,
                         cpu_clock_hz: 1_789_773, voice_count: 5, apu_regs: apu_regs, apu_status: 1,
                         apu_volume: [15, 0, 0], apu_length: [30, 0, 0, 0, 0])
    tracker = RubyPlayer::Nsf::Tracker.new
    tracker.update(RubyPlayer::ChipLiveState.new(snapshots: [snapshot], latest: snapshot, generation: 1,
                                                 track_generation: 1, frame: TRIGGER_FRAME, sample_rate: RATE,
                                                 paused: false, mute_mask: 0))
    text = render('NSF', tracker.snapshot)

    assert_includes text, 'Length 250 ms left'
    assert_includes text, 'cut at 250 ms'
  end

  private

  def render(source, snapshot)
    view = RubyPlayer::UI::ChipLiveView.new(source: source)
    view.update(snapshot)
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 48, cols: 160)
    view.render(screen, x: 0, y: 0, width: 160, height: 48, theme: THEME, track_title: 'Track',
                        now_sample: snapshot.sample)
    screen.instance_variable_get(:@back).map { |row| row.map(&:ch).join }.join("\n")
  end
end
