# frozen_string_literal: true

require 'test_helper'
require 'stringio'
require_relative 'support/spc_fixture'
require 'rubyplayer/ui/screen'
require 'rubyplayer/ui/spc_live_view'

class SpcLiveViewTest < Minitest::Test
  THEME = RubyPlayer::Theme::DEFAULT

  def setup
    @view = RubyPlayer::UI::SpcLiveView.new
  end

  def test_every_size_shows_all_eight_voices
    [[160, 50], [120, 40], [90, 30], [70, 20]].each do |cols, rows|
      lines = render('earthbound-megaton-walk', cols: cols, rows: rows)

      (0..7).each do |voice|
        assert(lines.any? { |line| line.start_with?("#{voice}  ") }, "voice #{voice} missing at #{cols}x#{rows}")
      end
    end
  end

  def test_wide_layout_shows_echo_sample_and_ram_panels
    text = render('earthbound-megaton-walk', cols: 160, rows: 50).join("\n")

    ['48 ms', 'high-pass', '$95B0', 'DIR $6C00', 'S-DSP LIVE'].each do |expected|
      assert_includes text, expected
    end
  end

  def test_noise_and_pitch_modulation_flags
    lines = render('last-battle', cols: 160, rows: 50)

    assert_match(/·N·/, voice_row(lines, 0))
    [1, 3, 5].each { |voice| assert_match(/··P|E·P/, voice_row(lines, voice)) }
  end

  def test_samples_strip_lists_samples_in_use_first
    lines = render('delightful-spekkio', cols: 160, rows: 50)
    strip = lines.drop_while { |line| !line.start_with?('Samples') }.drop(1).join(' ')
    in_use = SpcFixture.in_use(SpcFixture.regs('delightful-spekkio'))

    assert_operator in_use.size, :>=, 6
    in_use.each { |srcn| assert_match(/(?:^|\s)#{srcn} \$/, strip, "sample #{srcn} not listed") }
  end

  def test_nothing_is_drawn_outside_the_rectangle
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 50, cols: 160)
    @view.render(screen, x: 5, y: 3, width: 140, height: 40, theme: THEME, state: state_for('earthbound-megaton-walk'),
                         track_title: 'Megaton Walk')
    back = screen.instance_variable_get(:@back)

    back.each_with_index do |row, row_index|
      row.each_with_index do |cell, column|
        inside = row_index.between?(3, 42) && column.between?(5, 144)
        assert_equal ' ', cell.ch, "drew at #{row_index},#{column}" unless inside
      end
    end
  end

  def test_waiting_state_before_the_first_snapshot
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 10, cols: 80)
    @view.render(screen, x: 0, y: 0, width: 80, height: 10, theme: THEME, state: nil, track_title: 'Song')

    assert_includes text_of(screen).join("\n"), 'Waiting for SPC state'
  end

  def test_up_and_down_select_a_voice_and_its_sample
    @view.handle_key('down')
    @view.handle_key('down')

    assert_equal 2, @view.selected_voice
    refute @view.handle_key('x')
    text = render('last-battle', cols: 160, rows: 50).join("\n")

    assert_includes text, 'voice 2'
  end

  private

  # A snapshot built from the file's dumped registers, with every voice
  # sustaining at half level.
  def state_for(name)
    snapshot = RubyPlayer::Spc::Snapshot.new(frame: 0, regs: SpcFixture.regs(name), env: Array.new(8, 0x400),
                                             env_mode: Array.new(8, 3), brr_addr: Array.new(8, 0), attack_edges: 0)
    RubyPlayer::Spc::LiveState.new(snapshot: snapshot, ram: SpcFixture.ram(name), paused: false)
  end

  def render(name, cols:, rows:)
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: rows, cols: cols)
    @view.render(screen, x: 0, y: 0, width: cols, height: rows, theme: THEME, state: state_for(name),
                         track_title: name, position_ms: 61_000)
    text_of(screen)
  end

  def text_of(screen)
    screen.instance_variable_get(:@back).map { |row| row.map(&:ch).join }
  end

  def voice_row(lines, voice) = lines.find { |line| line.start_with?("#{voice}  ") }
end
