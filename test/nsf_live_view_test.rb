# frozen_string_literal: true

require 'test_helper'
require 'stringio'
require 'tmpdir'
require 'rubyplayer/backends/nsf_native'
require 'rubyplayer/chip_timeline'
require 'rubyplayer/nsf/tracker'
require 'rubyplayer/ui/screen'
require 'rubyplayer/ui/chip_live_view'
require_relative 'support/rip_fixtures'
require_relative 'support/nsf_builder'

# The VGM live page drawing 2A03 and expansion chip state from real NSF rips.
class NsfLiveViewTest < Minitest::Test
  THEME = RubyPlayer::Theme::DEFAULT
  SIZES = [[200, 60], [160, 48], [120, 40], [90, 30], [70, 20], [50, 12]].freeze
  RATE = 48_000
  CHUNK = 16_384
  Rips = TestSupport::RipFixtures
  # One rip per chip, with a channel worth selecting and what its panels say.
  CHIP_RIPS = {
    mega_man_2: ['Pulse 1', ['duty square', 'Volume envelope']],
    castlevania_3_japan: ['VRC6 Saw', ['7-step sawtooth', 'Sawtooth (fixed shape)']],
    lagrange_point: ['VRC7 FM 6', ['modulator → carrier']],
    metroid_fds: ['FDS Wave', ['64-step 6-bit wave', 'Wave · 64 steps']],
    just_breed: ['MMC5 Pulse 1', ['duty square']],
    erika_to_satoru: ['N163 Wave 1', ['4-bit wave', 'Wave RAM']],
    gimmick: ['5B Square A', ['AY-style square']]
  }.freeze

  # Plays 10 s of track 1 of `name` (or an NSF file) through the native
  # player, timeline, and tracker, as the app does.
  def self.tracker(name)
    @trackers ||= {}
    @trackers[name] ||= begin
      path = name.is_a?(Symbol) ? Rips.path(name) : name
      handle = RubyPlayer::Backends::NsfNative.new.open(path, 0, sample_rate: RATE)
      timeline = RubyPlayer::ChipTimeline.new
      tracker = RubyPlayer::Nsf::Tracker.new
      30.times do |chunk|
        handle.read(CHUNK)
        timeline.push(*handle.take_snapshots, origin_frame: chunk * CHUNK, snapshot_type: RubyPlayer::Nsf::Snapshot)
        frame = chunk * CHUNK
        tracker.update(RubyPlayer::ChipLiveState.new(snapshots: timeline.take_through(frame, limit: 4_096),
                                                     latest: nil, generation: 1, track_generation: 1, frame: frame,
                                                     sample_rate: RATE, paused: false, mute_mask: 0))
      end
      handle.close
      tracker
    end
  end

  def test_every_size_lists_every_channel_inside_the_rectangle
    CHIP_RIPS.each_key do |name|
      view = view_for(name)
      labels = view.snapshot.chips.flat_map { |chip| chip.channels.map(&:label) }
      SIZES.each do |cols, rows|
        lines = render(view, cols: cols, rows: rows)
        next if labels.size > rows - 6 # the table scrolls on short screens

        labels.each do |label|
          assert(lines.any? { |line| line.include?(" #{label[0, 14]}") }, "#{name}: #{label} at #{cols}x#{rows}")
        end
      end
    end
  end

  def test_nothing_is_drawn_outside_the_rectangle
    view = view_for(:castlevania_3_japan)
    SIZES.each do |cols, rows|
      screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: rows + 4, cols: cols + 6)
      view.render(screen, x: 3, y: 2, width: cols, height: rows, theme: THEME, track_title: 'Song',
                          now_sample: self.class.tracker(:castlevania_3_japan).now_sample)
      screen.instance_variable_get(:@back).each_with_index do |row, row_index|
        row.each_with_index do |cell, column|
          inside = row_index.between?(2, rows + 1) && column.between?(3, cols + 2)
          assert_equal ' ', cell.ch, "drew at #{row_index},#{column} for #{cols}x#{rows}" unless inside
        end
      end
    end
  end

  def test_each_chip_has_its_line_and_panels
    CHIP_RIPS.each do |name, (label, expected)|
      view = view_for(name)
      select(view, label)
      text = render(view, cols: 200, rows: 60).join("\n")

      assert_includes text, 'NSF LIVE', name
      expected.each { |phrase| assert_includes text, phrase, "#{name}: #{label}" }
    end
  end

  def test_chip_lines_describe_each_chip
    text = render(view_for(:mega_man_2), cols: 160, rows: 48).join("\n")

    assert_includes text, 'Ricoh 2A03 · 1.79 MHz · NTSC'
    assert_includes text, 'driver 60.1 Hz'
    assert_includes render(view_for(:gimmick_europe), cols: 160, rows: 48).join("\n"), 'Ricoh 2A07 · 1.66 MHz · PAL'
    assert_includes render(view_for(:erika_to_satoru), cols: 160, rows: 48).join("\n"), '8 of 8 channels enabled'
    assert_includes render(view_for(:lagrange_point), cols: 160, rows: 48).join("\n"), 'Konami VRC7'
  end

  # Levels are read from the emulator, except VRC7's (OPLL estimates).
  def test_levels_are_exact_unless_a_vrc7_is_present
    assert_includes render(view_for(:castlevania_3_japan), cols: 160, rows: 48)[3], 'Level '
    refute_includes render(view_for(:castlevania_3_japan), cols: 160, rows: 48)[3], '(est.)'
    assert_includes render(view_for(:lagrange_point), cols: 160, rows: 48)[3], 'Level (est.)'
  end

  # Every channel is its own libgme voice, numbered across chips.
  def test_mute_bits_follow_libgme_voices
    view = view_for(:castlevania_3_japan)
    bits = Array.new(8) do |index|
      view.instance_variable_set(:@selected_index, index)
      view.selected_mute_bits
    end

    assert_equal [1, 2, 4, 8, 16, 64, 128, 32], bits
    assert_equal 0xff, view.all_mute_bits
  end

  def test_history_has_notes_for_the_busy_channels
    lines = render(view_for(:castlevania_3_japan), cols: 200, rows: 60)
    top = lines.index { |line| line.include?('History · last') }
    column = lines[top].index('History')
    lanes = lines[top + 1, 8].map { |line| line[column..] }

    assert_equal(%w[1 2 3 4 5 6 7 8], lanes.map { |lane| lane[0] })
    [0, 1, 5, 6, 7].each { |index| assert_operator lanes[index][2..].strip.length, :>, 10, lanes[index] }
  end

  # Header bits for every known chip plus two no chip defines: libgme plays
  # the known ones, and the page shows them all without tripping on the rest.
  def test_unknown_and_every_known_expansion_flag_render
    Dir.mktmpdir do |dir|
      nsf = TestSupport::NsfBuilder.short_note_nsf.b
      nsf.setbyte(0x7b, 0xff)
      path = File.join(dir, 'every-chip.nsf')
      File.binwrite(path, nsf)
      view = RubyPlayer::UI::ChipLiveView.new(source: 'NSF')
      view.update(self.class.tracker(path).snapshot)
      chips = view.snapshot.chips.map { |chip| chip.id.split(':').first }

      assert_equal %w[2a03 vrc6 n163 s5b fds mmc5 vrc7], chips
      assert_equal (1 << 29) - 1, view.all_mute_bits
      SIZES.each { |cols, rows| refute_empty render(view, cols: cols, rows: rows).join.strip }
      29.times do |index|
        view.instance_variable_set(:@selected_index, index)

        refute_empty render(view, cols: 200, rows: 70).join.strip
      end
    end
  end

  private

  def view_for(name)
    view = RubyPlayer::UI::ChipLiveView.new(source: 'NSF')
    view.update(self.class.tracker(name).snapshot)
    view
  end

  def select(view, label)
    index = view.snapshot.chips.sort_by { |chip| chip.id == '2a03:0' ? 0 : 1 }
                               .flat_map(&:channels).index { |channel| channel.label == label }
    view.instance_variable_set(:@selected_index, index)
  end

  def render(view, cols:, rows:)
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: rows, cols: cols)
    view.render(screen, x: 0, y: 0, width: cols, height: rows, theme: THEME, track_title: 'Track',
                        now_sample: view.snapshot.sample)
    screen.instance_variable_get(:@back).map { |row| row.map(&:ch).join }
  end
end
