# frozen_string_literal: true

require 'test_helper'
require 'stringio'
require 'rubyplayer/backends/gbs_native'
require 'rubyplayer/chip_timeline'
require 'rubyplayer/gbs/tracker'
require 'rubyplayer/ui/screen'
require 'rubyplayer/ui/vgm_live_view'

# The VGM live page drawing Game Boy APU state from a real GBS track.
class GbsLiveViewTest < Minitest::Test
  THEME = RubyPlayer::Theme::DEFAULT
  SIZES = [[200, 60], [160, 48], [120, 40], [90, 30], [70, 20], [50, 12]].freeze
  CHANNELS = ['1 Square 1', '2 Square 2', '3 Wave', '4 Noise'].freeze
  RATE = 48_000
  CHUNK = 16_384

  # Plays 12 s of Shantae track 2 (all four channels busy by then) through the
  # native player, timeline, and tracker, as the app does.
  def self.tracker
    @tracker ||= begin
      handle = RubyPlayer::Backends::GbsNative.new.open(File.join(FIXTURES, 'shantae.gbs'), 1, sample_rate: RATE)
      timeline = RubyPlayer::ChipTimeline.new
      tracker = RubyPlayer::Gbs::Tracker.new
      36.times do |chunk|
        handle.read(CHUNK)
        timeline.push(*handle.take_snapshots, origin_frame: chunk * CHUNK, record: RubyPlayer::Gbs::Snapshot)
        frame = chunk * CHUNK
        tracker.update(RubyPlayer::Gbs::LiveState.new(snapshots: timeline.take_through(frame, limit: 2_048),
                                                      latest: nil, generation: 1, track_generation: 1, frame: frame,
                                                      sample_rate: RATE, paused: false, mute_mask: 0))
      end
      handle.close
      tracker
    end
  end

  def setup
    @view = RubyPlayer::UI::VgmLiveView.new(source: 'GBS')
    @view.update(self.class.tracker.snapshot)
  end

  def test_every_size_lists_every_channel_inside_the_rectangle
    SIZES.each do |cols, rows|
      lines = render(cols: cols, rows: rows)

      CHANNELS.each { |label| assert(lines.any? { |line| line.start_with?(label) }, "#{label} at #{cols}x#{rows}") }
    end
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

  def test_wide_layout_shows_the_chip_square_details_envelope_and_history
    text = render(cols: 160, rows: 48).join("\n")

    ['GBS LIVE', 'Game Boy APU · 4.19 MHz · power on', 'driver 59.7 Hz (VBlank)', 'duty square', 'Period ',
     'Volume envelope', 'trigger ─', 'History · last'].each { |expected| assert_includes text, expected }
    refute_includes text, 'Level (est.)'
  end

  def test_wave_channel_shows_its_wave_ram
    2.times { @view.handle_key('down') }
    text = render(cols: 160, rows: 48).join("\n")

    assert_includes text, 'Wave RAM · 32 × 4-bit'
    assert_includes text, '32-step 4-bit wave'
  end

  def test_noise_channel_describes_its_lfsr
    3.times { @view.handle_key('down') }

    assert_match(/Noise · (7|15)-bit LFSR/, render(cols: 160, rows: 48).join("\n"))
  end

  def test_each_channel_is_its_own_libgme_voice
    bits = Array.new(4) do |index|
      @view.instance_variable_set(:@selected_index, index)
      @view.selected_mute_bits
    end

    assert_equal [1, 2, 4, 8], bits
    assert_equal 0b1111, @view.all_mute_bits
  end

  def test_history_has_notes_for_the_busy_channels
    lines = render(cols: 160, rows: 48)
    top = lines.index { |line| line.include?('History · last') }
    column = lines[top].index('History')
    lanes = lines[top + 1, 4].map { |line| line[column..] }

    assert_equal(%w[1 2 3 4], lanes.map { |lane| lane[0] })
    lanes.each { |lane| assert_operator lane[2..].strip.length, :>, 10, lane }
  end

  def test_waiting_message_names_the_source
    view = RubyPlayer::UI::VgmLiveView.new(source: 'GBS')
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 10, cols: 80)
    view.render(screen, x: 0, y: 0, width: 80, height: 10, theme: THEME)

    assert_includes screen.instance_variable_get(:@back).map { |row| row.map(&:ch).join }.join, 'Waiting for GBS state'
  end

  private

  def render(cols:, rows:)
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: rows, cols: cols)
    @view.render(screen, x: 0, y: 0, width: cols, height: rows, theme: THEME, track_title: 'Shantae',
                         now_sample: self.class.tracker.now_sample)
    screen.instance_variable_get(:@back).map { |row| row.map(&:ch).join }
  end
end
