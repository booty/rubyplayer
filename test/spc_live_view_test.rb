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

  # Regression: the derived-data cache keyed only on the directory table, so
  # sample bytes rewritten in place (or another track with the same table)
  # kept showing the old waveform and sample info.
  def test_changed_sample_data_is_redrawn
    ram = synthetic_ram
    first = render_synthetic(ram, srcn: 0)
    ram[0x3000, 9] = [0xc1, *Array.new(8, 0x77)].pack('C*')

    refute_equal first, render_synthetic(ram, srcn: 0)
  end

  # Regression: with DIR near the top of RAM the directory wraps to $0000,
  # but the cache key only covered the bytes up to $FFFF.
  def test_changed_wrapped_directory_entry_is_redrawn
    ram = synthetic_ram(dir: 0xfe)
    write_entry(ram, 0xfe, 200, 0x3000)
    first = render_synthetic(ram, srcn: 200, dir: 0xfe)
    write_entry(ram, 0xfe, 200, 0x4000)
    second = render_synthetic(ram, srcn: 200, dir: 0xfe)

    assert_includes first, 'start $3000'
    assert_includes second, 'start $4000'
  end

  # Each panel keeps one cached result; changing inputs replaces it rather
  # than accumulating every combination ever rendered.
  def test_panel_caches_stay_bounded
    regs = SpcFixture.regs('earthbound-megaton-walk').dup
    ram = SpcFixture.ram('earthbound-megaton-walk')
    40.times do |step|
      regs[0x0f] = step
      render_state(regs, ram)
    end

    assert_operator @view.instance_variable_get(:@caches).size, :<=, 6
  end

  private

  # Two one-block samples ($3000, $4000) and a directory at DIR * $100 whose
  # entry 0 points at $3000; echo buffer parked at $8000.
  def synthetic_ram(dir: 0x20)
    ram = ("\0" * 0x10000).b
    ram[0x3000, 9] = [0x41, *Array.new(8, 0x11)].pack('C*')
    ram[0x4000, 9] = [0x41, *Array.new(8, 0x22)].pack('C*')
    write_entry(ram, dir, 0, 0x3000)
    ram
  end

  def write_entry(ram, dir, srcn, start)
    address = (dir * 0x100) + (srcn * 4)
    [start & 0xff, start >> 8, start & 0xff, start >> 8].each_with_index do |byte, index|
      ram.setbyte((address + index) % 0x10000, byte)
    end
  end

  def render_synthetic(ram, srcn:, dir: 0x20)
    regs = Array.new(128, 0)
    regs[0x5d] = dir
    regs[0x6d] = 0x80
    regs[0x7d] = 1
    regs[4] = srcn
    render_state(regs, ram.dup)
  end

  def render_state(regs, ram)
    snapshot = RubyPlayer::Spc::Snapshot.new(frame: 0, regs: regs, env: Array.new(8, 0x400),
                                             env_mode: Array.new(8, 3), brr_addr: Array.new(8, 0), attack_edges: 0)
    state = RubyPlayer::Spc::LiveState.new(snapshot: snapshot, ram: ram, paused: false, mute_mask: 0)
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 50, cols: 160)
    @view.render(screen, x: 0, y: 0, width: 160, height: 50, theme: THEME, state: state, track_title: 'x')
    text_of(screen).join("\n")
  end

  # A snapshot built from the file's dumped registers, with every voice
  # sustaining at half level.
  def state_for(name)
    snapshot = RubyPlayer::Spc::Snapshot.new(frame: 0, regs: SpcFixture.regs(name), env: Array.new(8, 0x400),
                                             env_mode: Array.new(8, 3), brr_addr: Array.new(8, 0), attack_edges: 0)
    RubyPlayer::Spc::LiveState.new(snapshot: snapshot, ram: SpcFixture.ram(name), paused: false, mute_mask: 0)
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
