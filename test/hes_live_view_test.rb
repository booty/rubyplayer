# frozen_string_literal: true

require 'test_helper'
require 'stringio'
require 'rubyplayer/backends/hes_native'
require 'rubyplayer/chip_timeline'
require 'rubyplayer/hes/tracker'
require 'rubyplayer/ui/screen'
require 'rubyplayer/ui/chip_live_view'
require_relative 'support/rip_fixtures'

# The VGM live page drawing HuC6280 PSG state from a real HES track.
class HesLiveViewTest < Minitest::Test
  THEME = RubyPlayer::Theme::DEFAULT
  SIZES = [[200, 60], [160, 48], [120, 40], [90, 30], [70, 20], [50, 12]].freeze
  CHANNELS = ['1 Wave 1', '2 Wave 2', '3 Wave 3', '4 Wave 4', '5 Multi 1', '6 Multi 2'].freeze
  RATE = 48_000
  CHUNK = 16_384
  Hes = RubyPlayer::Hes

  # Plays 6 s of Blazing Lazers' first playlist track (five wave voices and a
  # direct-DAC voice on Multi 1) through the native player, timeline, and
  # tracker, as the app does.
  def self.tracker
    @tracker ||= begin
      path = TestSupport::RipFixtures.path(:blazing_lazers)
      handle = RubyPlayer::Backends::HesNative.new.open(path, 0, sample_rate: RATE)
      timeline = RubyPlayer::ChipTimeline.new
      tracker = Hes::Tracker.new
      18.times do |chunk|
        handle.read(CHUNK)
        timeline.push(*handle.take_snapshots, origin_frame: chunk * CHUNK, snapshot_type: Hes::Snapshot)
        frame = chunk * CHUNK
        tracker.update(Hes::LiveState.new(snapshots: timeline.take_through(frame, limit: 2_048), latest: nil,
                                          generation: 1, track_generation: 1, frame: frame, sample_rate: RATE,
                                          paused: false, mute_mask: 0))
      end
      handle.close
      tracker
    end
  end

  def setup
    @view = RubyPlayer::UI::ChipLiveView.new(source: 'HES')
    @view.update(self.class.tracker.snapshot)
  end

  def test_every_size_lists_every_channel_inside_the_rectangle
    SIZES.each do |cols, rows|
      lines = render(cols: cols, rows: rows)
      visible = CHANNELS.select { |label| lines.any? { |line| line.start_with?(label) } }

      # Short terminals scroll the table; the selected row stays visible.
      assert_includes visible, CHANNELS.first, "#{cols}x#{rows}"
      assert_equal CHANNELS, visible, "#{cols}x#{rows}" if rows >= 30
    end
  end

  def test_short_terminals_scroll_to_every_channel
    seen = 6.times.flat_map do
      lines = render(cols: 50, rows: 12)
      @view.handle_key('down')
      CHANNELS.select { |label| lines.any? { |line| line.start_with?(label) } }
    end

    assert_equal CHANNELS, seen.uniq.sort
  end

  def test_nothing_is_drawn_outside_the_rectangle
    SIZES.each do |cols, rows|
      screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: rows + 4, cols: cols + 6)
      @view.render(screen, x: 3, y: 2, width: cols, height: rows, theme: THEME, track_title: 'Song',
                           now_sample: self.class.tracker.now_sample)
      screen.instance_variable_get(:@back).each_with_index do |row, row_index|
        row.each_with_index do |cell, column|
          inside = row_index.between?(2, rows + 1) && column.between?(3, cols + 2)

          assert_equal ' ', cell.ch, "drew at #{row_index},#{column} for #{cols}x#{rows}" unless inside
        end
      end
    end
  end

  # Levels come from libgme's gain, not the sound itself, so they are
  # labeled estimates.
  def test_wide_layout_shows_the_chip_wave_voice_and_estimated_levels
    text = render(cols: 160, rows: 48).join("\n")

    ['HES LIVE', 'HuC6280 PSG · 7.16 MHz · master L15 R15 · VBlank 60.1 Hz', 'Level (est.)', 'Period ',
     '32-step 5-bit wave', 'Wave RAM · 32 × 5-bit', 'History · last'].each { |expected| assert_includes text, expected }
  end

  def test_direct_dac_voice_shows_its_sample_without_a_note
    text = multi_one_text(control: 0xdf, dac: 17)

    assert_includes text, 'Multi 1 · direct DAC'
    assert_includes text, 'DAC sample $11 (17/31)'
    refute_includes text, 'Wave RAM · 32 × 5-bit'
    refute_match(/^5 Multi 1 +\S+ +[A-G]#?-?\d/, text)
  end

  def test_noise_voice_shows_its_lfsr_without_a_note
    text = multi_one_text(control: 0x9f, noise: 0x9f)

    assert_includes text, 'Multi 1 · noise'
    assert_includes text, 'Noise rate 31 · LFSR clock 111.9 kHz'
    refute_match(/^5 Multi 1 +\S+ +[A-G]#?-?\d/, text)
  end

  def test_each_voice_is_its_own_libgme_voice
    bits = Array.new(6) do |index|
      @view.instance_variable_set(:@selected_index, index)
      @view.selected_mute_bits
    end

    assert_equal [1, 2, 4, 8, 16, 32], bits
    assert_equal 0x3f, @view.all_mute_bits
  end

  def test_waiting_message_names_the_source
    view = RubyPlayer::UI::ChipLiveView.new(source: 'HES')
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 10, cols: 80)
    view.render(screen, x: 0, y: 0, width: 80, height: 10, theme: THEME)

    assert_includes screen.instance_variable_get(:@back).map { |row| row.map(&:ch).join }.join, 'Waiting for HES state'
  end

  private

  # The wide page with Multi 1 (voice 4) selected, keyed with `control`,
  # `noise`, and `dac`, every other voice off.
  def multi_one_text(control:, noise: 0, dac: 0)
    snapshot = Hes::Snapshot.new(frame: 0, playing: 0b1_0000, triggers: 0b1_0000, master_balance: 0xff,
                                 selected_channel: 4, period: [0] * 6, control: [0, 0, 0, 0, control, 0],
                                 balance: [0xff] * 6, noise: [0, 0, 0, 0, noise, 0], dac: [0, 0, 0, 0, dac, 0],
                                 wave: "\0" * 192, output_left: [0, 0, 0, 0, 30_000, 0],
                                 output_right: [0, 0, 0, 0, 30_000, 0], vblank_period_cycles: 119_210,
                                 cpu_clock_hz: 7_159_091)
    tracker = Hes::Tracker.new
    tracker.update(Hes::LiveState.new(snapshots: [snapshot], latest: snapshot, generation: 1, track_generation: 1,
                                      frame: 0, sample_rate: RATE, paused: false, mute_mask: 0))
    view = RubyPlayer::UI::ChipLiveView.new(source: 'HES')
    view.update(tracker.snapshot)
    4.times { view.handle_key('down') }
    render(cols: 160, rows: 48, view: view, now_sample: 0).join("\n")
  end

  def render(cols:, rows:, view: @view, now_sample: self.class.tracker.now_sample)
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: rows, cols: cols)
    view.render(screen, x: 0, y: 0, width: cols, height: rows, theme: THEME, track_title: 'Blazing Lazers',
                        now_sample: now_sample)
    screen.instance_variable_get(:@back).map { |row| row.map(&:ch).join }
  end
end
