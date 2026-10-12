# frozen_string_literal: true

require 'test_helper'
require 'stringio'
require 'rubyplayer/ui/screen'
require 'rubyplayer/ui/vgm_live_view'
require 'rubyplayer/vgm/reader'
require 'rubyplayer/vgm/cursor'
require 'rubyplayer/vgm/chips/ym2612'
require 'rubyplayer/vgm/chips/sn76489'
require 'rubyplayer/vgm/chips/ym2413'

class VgmLiveViewTest < Minitest::Test
  THEME = RubyPlayer::Theme::DEFAULT
  Vgm = RubyPlayer::Vgm
  SIZES = [[200, 60], [160, 48], [120, 40], [90, 30], [70, 20], [50, 12]].freeze
  ALWAYS_LISTED = ['1 FM 1', '6 FM 6', '7 PSG 1', 'a Noise'].freeze

  # Replaying 12 s of a DAC-heavy track takes about a second; share it.
  def self.fixture_snapshot
    @fixture_snapshot ||= begin
      reader = Vgm::Reader.open(File.join(FIXTURES, 'scrap-brean-zone.vgm'), max_bytes: 64 << 20)
      cursor = Vgm::Cursor.new(reader: reader)
      snapshot = nil
      loop do
        snapshot = cursor.advance_to(sample: 44_100 * 12)
        break if snapshot.sample >= 44_100 * 12
      end
      snapshot.with(generation: 1)
    end
  end

  def setup
    @view = RubyPlayer::UI::VgmLiveView.new
  end

  def test_every_size_shows_every_channel
    @view.update(fixture_snapshot)
    SIZES.each do |cols, rows|
      lines = render(cols: cols, rows: rows)

      ALWAYS_LISTED.each do |label|
        assert(lines.any? { |line| line.start_with?(label) }, "#{label} missing at #{cols}x#{rows}")
      end
    end
  end

  def test_nothing_is_drawn_outside_the_rectangle
    @view.update(fixture_snapshot)
    SIZES.each do |cols, rows|
      screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: rows + 4, cols: cols + 6)
      @view.render(screen, x: 3, y: 2, width: cols, height: rows, theme: THEME, track_title: 'Song',
                           now_sample: 44_100 * 20)
      screen.instance_variable_get(:@back).each_with_index do |row, row_index|
        row.each_with_index do |cell, column|
          inside = row_index.between?(2, rows + 1) && column.between?(3, cols + 2)

          assert_equal ' ', cell.ch, "drew at #{row_index},#{column} for #{cols}x#{rows}" unless inside
        end
      end
    end
  end

  def test_wide_layout_shows_chips_keyboard_voice_envelopes_and_history
    @view.update(fixture_snapshot)
    text = render(cols: 160, rows: 48).join("\n")

    ['VGM LIVE', 'YM2612 · 7.67 MHz', 'SN76489 · 3.58 MHz', 'C4', 'FM 1 · ALG', 'OP   AR D1R',
     'Envelopes (estimated)', 'History · last', '→▶'].each do |expected|
      assert_includes text, expected
    end
  end

  def test_short_view_scrolls_the_table_to_the_selection
    @view.update(fixture_snapshot)
    9.times { @view.handle_key('down') }
    lines = render(cols: 80, rows: 6)

    assert(lines.any? { |line| line.start_with?('a Noise') })
    refute(lines.any? { |line| line.start_with?('1 FM 1') })
  end

  def test_selection_survives_updates_and_resets_for_a_new_source
    snapshot = fixture_snapshot
    @view.update(snapshot)
    3.times { @view.handle_key('down') }
    @view.update(snapshot.with(sample: snapshot.sample + 100))

    assert_equal 'ym2612:0:3', @view.selected_channel_id
    @view.update(snapshot.with(generation: 2))

    assert_equal 'ym2612:0:0', @view.selected_channel_id
  end

  def test_level_follows_the_envelope_after_key_off
    chip = Vgm::Chips::Ym2612.new(clock_hz: 7_670_453)
    fast_patch(chip)
    write(chip, 0x28, 0xf0, 0)
    write(chip, 0x28, 0x00, 44_100)
    @view.update(snapshot_for([chip], 44_100))

    assert_operator level_cells(render(cols: 90, rows: 30, now: 44_100)), :>, 10
    assert_equal 0, level_cells(render(cols: 90, rows: 30, now: 44_100 * 3))
  end

  # Algorithm 0's only carrier is OP4; keying OP1 alone makes no sound.
  def test_level_follows_each_operators_own_key
    chip = Vgm::Chips::Ym2612.new(clock_hz: 7_670_453)
    fast_patch(chip)
    write(chip, 0xb0, 0x00, 0)
    write(chip, 0x28, 0x10, 0)
    @view.update(snapshot_for([chip], 100))

    assert_equal 0, level_cells(render(cols: 90, rows: 30))
    write(chip, 0x28, 0x90, 200)
    @view.update(snapshot_for([chip], 300))

    assert_operator level_cells(render(cols: 90, rows: 30)), :>, 10
  end

  def test_wide_screens_spell_out_fm_terms
    chip = Vgm::Chips::Ym2612.new(clock_hz: 7_670_453)
    fast_patch(chip)
    write(chip, 0xb0, 0x3c, 0)
    write(chip, 0xb4, 0xd3, 0)
    @view.update(snapshot_for([chip], 0))
    narrow = render(cols: 110, rows: 40).find { |line| line.start_with?('1 FM 1') }
    wide = render(cols: 200, rows: 60)
    row = wide.find { |line| line.start_with?('1 FM 1') }

    assert_match(/ALG 4 FB 7 \h{6}/, narrow)
    assert_includes row, 'ALG 4 (two 2-op pairs, 2 carriers) · FB 7 (4π) · patch'
    text = wide.join("\n")

    assert_includes text, 'FM 1 · ALG 4 (two 2-op pairs, 2 carriers) · FB 7 (4π)'
    assert_includes text, 'AMS 1 (1.4 dB) · FMS 3 (±10¢)'
  end

  # Algorithm diagrams differ in height; the operator table must not move.
  def test_operator_table_stays_put_across_algorithms
    rows = [0x00, 0x07].map do |algorithm|
      chip = Vgm::Chips::Ym2612.new(clock_hz: 7_670_453)
      fast_patch(chip)
      write(chip, 0xb0, algorithm, 0)
      @view.update(snapshot_for([chip], 0))
      render(cols: 160, rows: 48).index { |line| line.start_with?('OP   AR') }
    end

    assert_equal rows.first, rows.last
  end

  def test_history_draws_notes_where_they_were_played
    chip = Vgm::Chips::Ym2612.new(clock_hz: 7_670_453)
    fast_patch(chip)
    write(chip, 0xa4, 0x22, 0)
    write(chip, 0xa0, 0x69, 0)
    write(chip, 0x28, 0xf0, 44_100)
    write(chip, 0x28, 0x00, 44_100 + 22_050)
    now = 44_100 * 2
    @view.update(snapshot_for([chip], now))
    lane = render(cols: 90, rows: 30, now: now).find { |line| line.start_with?('1 ') && !line.include?('FM 1') }
    cells = lane[2..]

    # 100 ms per column, newest (2.0 s) at the right: the note sounds from
    # 1.0 s to 1.5 s.
    assert_equal ' ' * 5, cells[-5..]
    refute_equal ' ', cells[-6]
    refute_equal ' ', cells[-11]
    assert_equal ' ', cells[-12]
  end

  def test_mute_bits_follow_libgmes_voice_layout
    @view.update(fixture_snapshot)
    bits = Array.new(10) do |index|
      @view.instance_variable_set(:@selected_index, index)
      @view.selected_mute_bits
    end

    # FM 6 is the DAC here; its row covers both voices.
    assert_equal [1, 2, 4, 8, 16, 96, 128, 128, 128, 128], bits
    assert_equal 0xff, @view.all_mute_bits
  end

  def test_psg_only_tracks_mute_each_psg_channel
    @view.update(snapshot_for([Vgm::Chips::Sn76489.new(clock_hz: 3_579_545)], 0))
    bits = Array.new(4) do |index|
      @view.instance_variable_set(:@selected_index, index)
      @view.selected_mute_bits
    end

    assert_equal [1, 2, 4, 8], bits
  end

  def test_opll_groups_upper_channels_and_rhythm
    chip = Vgm::Chips::Ym2413.new(clock_hz: 3_579_545)
    chip.write(register: 0x0e, value: 0x20, sample: 0)
    @view.update(snapshot_for([chip], 0))
    bits = Array.new(9) do |index|
      @view.instance_variable_set(:@selected_index, index)
      @view.selected_mute_bits
    end

    assert_equal [1, 2, 4, 8, 16, 32, 64, 64, 64], bits
  end

  # libgme's rhythm voice exists while the chip is melodic; a solo must
  # cover it so drums enabled later stay silent.
  def test_opll_solo_covers_rhythm_before_rhythm_mode
    @view.update(snapshot_for([Vgm::Chips::Ym2413.new(clock_hz: 3_579_545)], 0))

    assert_equal 0x7f, @view.all_mute_bits
  end

  def test_muted_rows_are_flagged
    @view.update(fixture_snapshot)
    lines = render(cols: 160, rows: 48, mute: 0b10)

    assert_match(/^2 FM 2 .* M$/, lines.find { |line| line.start_with?('2 FM 2') }.rstrip)
    refute_match(/ M$/, lines.find { |line| line.start_with?('1 FM 1') }.rstrip)
  end

  def test_opll_shows_rom_instrument_and_custom_operators
    chip = Vgm::Chips::Ym2413.new(clock_hz: 3_579_545)
    chip.write(register: 0x30, value: 0x33, sample: 0)
    chip.write(register: 0x31, value: 0x05, sample: 0)
    chip.write(register: 0x10, value: 0xac, sample: 0)
    chip.write(register: 0x20, value: 0x18, sample: 0)
    @view.update(snapshot_for([chip], 100))
    text = render(cols: 160, rows: 48).join("\n")

    assert_includes text, 'Piano · vol 3 (-9 dB)'
    assert_includes text, 'FM 1 · Piano (ROM 3)'
    @view.handle_key('down')
    text = render(cols: 160, rows: 48).join("\n")

    assert_includes text, 'FM 2 · Custom (custom patch)'
    assert_includes text, 'OP   AR  DR  SL  RR'
  end

  def test_sub_audible_leftover_frequencies_have_no_note
    chip = Vgm::Chips::Ym2612.new(clock_hz: 7_670_453)
    write(chip, 0xa4, 0x00, 0)
    write(chip, 0xa0, 0x01, 0)
    @view.update(snapshot_for([chip], 0))

    assert_match(/^1 FM 1\s+--/, render(cols: 90, rows: 30).find { |line| line.start_with?('1 FM 1') })
  end

  def test_waiting_and_empty_states
    assert_includes render(cols: 80, rows: 10).join, 'Waiting for VGM telemetry'

    @view.update(Vgm::Snapshot.new(generation: 1, revision: 0, sample: 0, status: :unsupported,
                                   message: nil, loop_count: 0, chips: [], warnings: ["Bad\e[2Jchip"]))

    assert_includes render(cols: 80, rows: 10).join, 'Bad [2Jchip'
  end

  private

  def render(cols:, rows:, now: nil, mute: 0)
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: rows, cols: cols)
    @view.render(screen, x: 0, y: 0, width: cols, height: rows, theme: THEME, track_title: 'Song — Artist',
                         now_sample: now || @view.snapshot&.sample, mute_mask: mute)
    screen.instance_variable_get(:@back).map { |row| row.map(&:ch).join }
  end

  def fixture_snapshot = self.class.fixture_snapshot

  def snapshot_for(chips, sample)
    Vgm::Snapshot.new(generation: 1, revision: 0, sample: sample, status: :ready, message: nil, loop_count: 0,
                      chips: chips.map { |chip| chip.snapshot(sample: sample) }, warnings: [])
  end

  # Algorithm 7 (all carriers), instant attack, no decay, fastest release.
  def fast_patch(chip)
    write(chip, 0xb0, 0x07, 0)
    write(chip, 0xb4, 0xc0, 0)
    [0x30, 0x34, 0x38, 0x3c].each do |register|
      write(chip, register + 0x20, 0x1f, 0)
      write(chip, register + 0x50, 0x0f, 0)
    end
  end

  def write(chip, register, value, sample)
    chip.write(port: 0, register: register, value: value, sample: sample)
  end

  def level_cells(lines)
    row = lines.find { |line| line.start_with?('1 FM 1') }
    row.count('█▉▊▋▌▍▎▏')
  end
end
