# frozen_string_literal: true

require 'test_helper'
require 'stringio'
require 'rubyplayer/vgm/snapshot'
require 'rubyplayer/vgm/patch'
require 'rubyplayer/ui/vgm_channels'

class VgmChannelsTest < Minitest::Test
  def setup
    @widget = RubyPlayer::UI::VgmChannels.new
    @widget.update(snapshot)
  end

  def test_large_view_shows_all_genesis_rows_dac_role_patch_and_operator_values
    text = render_text(width: 100, height: 28)

    ['FM 1', 'FM 2', 'FM 3', 'FM 4', 'FM 5', 'FM 6 / DAC',
     'PSG 1', 'PSG 2', 'PSG 3', 'Noise'].each do |label|
      assert_includes text, label
    end
    assert_includes text, 'ALG 4'
    assert_includes text, 'AR 31'
    assert_includes text, 'DATA'
    assert_includes text, 'L/R'
  end

  def test_narrow_pages_make_every_operator_parameter_reachable
    text = browse_pages(width: 30, height: 8, count: 16)

    %w[DT MUL TL RS AR AM D1R D2R D1L RR SSG].each do |field|
      assert_includes text, field
    end
  end

  def test_opll_custom_operator_fields_are_reachable_at_narrow_width
    custom = RubyPlayer::Vgm::Patch.from_bytes(
      chip: :ym2413, bytes: Array.new(8, 0),
      operators: [
        RubyPlayer::Vgm::Operator.new(index: 1, parameters: {
                                        am: 1, pm: 1, eg: 1, ksr: 0, mul: 7, key_scale_level: 2,
                                        total_level: 31, feedback: 4, waveform: 1, ar: 15, dr: 8, sl: 7, rr: 3
                                      }),
        RubyPlayer::Vgm::Operator.new(index: 2, parameters: { am: 0, pm: 1, mul: 2, rr: 4 })
      ],
      details: { program: :custom }
    )
    channel = RubyPlayer::Vgm::ChannelSnapshot.new(
      id: 'ym2413:0:0', label: 'FM 1', kind: :tone, state: :key_on,
      last_trigger_sample: 0, pitch_hz: 440.0, note: 'A4', pan: :lr,
      patch: custom, details: { program_number: :custom, volume: 3 }
    )
    chip = RubyPlayer::Vgm::ChipSnapshot.new(id: 'ym2413:0', name: 'YM2413',
                                             clock_hz: 3_579_545, channels: [channel],
                                             details: { rhythm_mode: false })
    @widget.update(snapshot(chips: [chip]))

    text = browse_pages(width: 30, height: 8, count: 8)

    %w[KSL TL FB WAV AR DR SL RR].each { |field| assert_includes text, field }
  end

  def test_normal_width_keeps_recent_marker_loop_count_and_pause_state_visible
    @widget.paused = true
    text = render_text(width: 100, height: 28)

    assert_match(/>\*/, text)
    assert_includes text, 'Loop 2'
    assert_includes text, 'PAUSED'
  end

  def test_partial_warning_does_not_displace_patch_fields_at_short_height
    @widget.update(snapshot(status: :partial, warnings: ['YM2413 unavailable']))

    text = render_text(width: 47, height: 8)

    assert_includes text, 'OP 1'
    assert_includes text, 'AR 31'
  end

  def test_channel_three_special_mode_renders_uninitialized_operator_pitch
    channel = RubyPlayer::Vgm::ChannelSnapshot.new(
      id: 'ym2612:0:2', label: 'FM 3', kind: :fm, state: :key_off,
      last_trigger_sample: nil, pitch_hz: nil, note: :special, pan: :lr,
      patch: nil,
      details: { special_mode: true, special_frequencies: [
        { operator: 1, fnum: nil, block: nil, pitch_hz: nil }
      ] }
    )
    chip = RubyPlayer::Vgm::ChipSnapshot.new(id: 'ym2612:0', name: 'YM2612',
                                             clock_hz: 7_670_454, channels: [channel],
                                             details: {})
    @widget.update(snapshot(chips: [chip]))
    @widget.handle_key('right')

    text = render_text(width: 72, height: 16)

    assert_includes text, 'Special OP 1'
    assert_includes text, '--'
  end

  def test_channel_and_chip_pages_expose_decoded_register_fields_and_legend
    2.times { @widget.handle_key('down') }
    ym_text = browse_pages(width: 48, height: 8, count: 16)

    ['FNUM', 'AMS', 'FMS', 'Special OP', 'Timer A', 'Timer B', 'DAC byte',
     'Register activity', 'audio', 'levels'].each do |detail|
      assert_includes ym_text, detail
    end

    4.times { @widget.handle_key('down') }
    psg_text = browse_pages(width: 48, height: 8, count: 12)

    assert_includes psg_text, 'noise feedback'
    assert_includes psg_text, 'shift width'
  end

  def test_selection_tracks_channel_identity_and_scrolls_to_every_row_at_narrow_sizes
    screen_text = nil
    10.times do |index|
      screen_text = render_text(width: 30, height: 8)
      expected_id = index < 6 ? "ym2612:0:#{index}" : "sn76489:0:#{index - 6}"

      assert_equal expected_id, @widget.selected_channel_id
      @widget.handle_key('down')
    end

    assert_includes screen_text, 'Noise'

    replacement = snapshot(sample: 200)
    @widget.update(replacement)

    assert_equal 'sn76489:0:3', @widget.selected_channel_id
    @widget.update(snapshot(sample: 0, generation: 2))

    assert_equal 'ym2612:0:0', @widget.selected_channel_id
  end

  def test_selection_survives_a_snapshot_clear_during_same_source_seek
    2.times { @widget.handle_key('down') }
    @widget.update(nil)
    @widget.update(snapshot(generation: 1, revision: 1))

    assert_equal 'ym2612:0:2', @widget.selected_channel_id
  end

  def test_patch_detail_pages_reach_operator_fields_when_height_is_short
    render_text(width: 47, height: 8)
    first_page = render_text(width: 47, height: 8)
    @widget.handle_key('right')
    second_page = render_text(width: 47, height: 8)

    assert_includes first_page, 'OP 1'
    assert_includes second_page, 'OP 2'
    @widget.handle_key('right')
    third_page = render_text(width: 47, height: 8)
    @widget.handle_key('right')
    fourth_page = render_text(width: 47, height: 8)

    assert_includes third_page, 'OP 3'
    assert_includes fourth_page, 'OP 4'
    @widget.handle_key('right')
    channel_page = render_text(width: 47, height: 8)

    assert_includes channel_page, 'Trigger sample'
    @widget.handle_key('right')
    more_channel_details = render_text(width: 47, height: 8)

    assert_includes more_channel_details, 'AMS'
  end

  def test_render_stays_inside_its_rectangle_for_all_planned_sizes
    [30, 47, 48, 71, 72, 100].product([1, 3, 8, 16, 28]).each do |width, height|
      rows = 36
      cols = 112
      screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: rows, cols: cols)
      rows.times { |row| screen.put(row, 0, '#' * cols) }
      widget = RubyPlayer::UI::VgmChannels.new
      widget.update(snapshot)
      x = 5
      y = 3
      widget.render(screen, x: x, y: y, width: width, height: height,
                            theme: RubyPlayer::Theme::DEFAULT)
      buffer = screen.instance_variable_get(:@back)

      outside = rows.times.flat_map do |row|
        cols.times.filter_map do |col|
          buffer[row][col].ch unless row.between?(y, y + height - 1) && col.between?(x, x + width - 1)
        end
      end

      assert_equal ['#'], outside.uniq, "widget escaped #{width}x#{height} rectangle"
    end
  end

  def test_one_row_view_draws_only_header_and_ignores_detail_navigation
    text = render_text(width: 72, height: 1)

    refute @widget.handle_key('right')
    refute_includes text, 'FM 1'
  end

  def test_middle_width_drops_pan_and_shortens_patch_signature
    text = render_text(width: 60, height: 8)

    refute_includes text, 'Pan'
    refute_includes text, '0123456789ab'
    assert_includes text, '012345'
  end

  def test_opll_rhythm_and_terminal_statuses_are_textual
    rhythm = RubyPlayer::Vgm::ChipSnapshot.new(
      id: 'ym2413:0', name: 'YM2413', clock_hz: 3_579_545,
      channels: [RubyPlayer::Vgm::ChannelSnapshot.new(
        id: 'ym2413:0:bd', label: 'Bass Drum', kind: :percussion, state: :key_on,
        last_trigger_sample: 100, pitch_hz: nil, note: nil, pan: nil, patch: nil,
        details: { rhythm_mode: true }
      )], details: { rhythm_mode: true }
    )
    @widget.update(snapshot(chips: [rhythm], status: :partial, warnings: ['CSM key activity is unmodeled']))
    text = browse_pages(width: 72, height: 16, count: 8)

    assert_includes text, 'Bass Drum'
    assert_includes text, 'CSM key activity is unmodeled'

    %i[loading ready partial unsupported error ended].each do |status|
      @widget.update(snapshot(status: status, message: status == :error ? 'bad data' : nil,
                              chips: status == :ready ? genesis_chips : []))

      assert_includes render_text(width: 48, height: 8), status.to_s.upcase
    end
  end

  private

  def render_text(width:, height:)
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: height + 2, cols: width + 2)
    @widget.render(screen, x: 1, y: 1, width: width, height: height,
                           theme: RubyPlayer::Theme::DEFAULT)
    screen.instance_variable_get(:@back).map { |row| row.map(&:ch).join }.join("\n")
  end

  def browse_pages(width:, height:, count:)
    Array.new(count) do
      text = render_text(width: width, height: height)
      @widget.handle_key('right')
      text
    end.join("\n")
  end

  def snapshot(sample: 100, chips: genesis_chips, status: :ready, message: nil, warnings: [],
               generation: 1, revision: 0)
    RubyPlayer::Vgm::Snapshot.new(generation: generation, revision: revision, sample: sample,
                                  status: status, message: message, loop_count: 2,
                                  chips: chips, warnings: warnings)
  end

  def genesis_chips
    [genesis_ym_chip, genesis_psg_chip]
  end

  def genesis_patch
    RubyPlayer::Vgm::Patch.new(
      digest: '0123456789abcdef', algorithm: 4, feedback: 2,
      operators: Array.new(4) do |index|
        RubyPlayer::Vgm::Operator.new(index: index + 1,
                                      parameters: { dt: 0, mul: 1, tl: 24, rs: 0, ar: 31,
                                                    am: 0, d1r: 12, d2r: 3, d1l: 5, rr: 8,
                                                    ssg_eg: 0 })
      end,
      details: { chip: :ym2612 }
    )
  end

  def genesis_ym_chip
    patch = genesis_patch
    channels = Array.new(6) { |index| genesis_fm_channel(index, patch) }
    RubyPlayer::Vgm::ChipSnapshot.new(id: 'ym2612:0', name: 'YM2612',
                                      clock_hz: 7_670_454, channels: channels,
                                      details: { variant: :ym2612, csm_enabled: true,
                                                 timer_a: 1023, timer_b: 200, lfo: 8,
                                                 lfo_enabled: true, dac_enabled: true,
                                                 dac_value: 128, dac_sample: 100,
                                                 timer_generated_key_activity: :unmodeled })
  end

  def genesis_fm_channel(index, patch)
    pcm = index == 5
    RubyPlayer::Vgm::ChannelSnapshot.new(
      id: "ym2612:0:#{index}", label: pcm ? 'FM 6 / DAC' : "FM #{index + 1}",
      kind: pcm ? :pcm : :fm, state: pcm ? :data : :key_on,
      last_trigger_sample: 100, pitch_hz: 440.0, note: 'A4 +03c', pan: :lr,
      patch: pcm ? nil : patch,
      details: if pcm
                 { dac_enabled: true, dac_value: 128, dac_sample: 100,
                   fm_patch: patch }
               else
                 { algorithm: 4, feedback: 2, key_mask: 15,
                   ams: 2, fms: 3, frequency: { fnum: 608, block: 3 },
                   special_mode: index == 2,
                   special_frequencies: if index == 2
                                          [
                                            { operator: 1, fnum: 304, block: 3, pitch_hz: 494.2 },
                                            { operator: 2, fnum: 200, block: 2, pitch_hz: 245.0 }
                                          ]
                                        end }
               end
    )
  end

  def genesis_psg_chip
    channels = Array.new(4) { |index| genesis_psg_channel(index) }
    RubyPlayer::Vgm::ChipSnapshot.new(id: 'sn76489:0', name: 'SN76489',
                                      clock_hz: 3_579_545, channels: channels,
                                      details: { noise_feedback: 9, shift_width: 15, flags: 0 })
  end

  def genesis_psg_channel(index)
    noise = index == 3
    RubyPlayer::Vgm::ChannelSnapshot.new(
      id: "sn76489:0:#{index}", label: noise ? 'Noise' : "PSG #{index + 1}",
      kind: noise ? :noise : :tone, state: index == 1 ? :muted : :enabled,
      last_trigger_sample: nil, pitch_hz: noise ? nil : 660.0,
      note: noise ? 'white / tone 3' : 'E5 -02c', pan: :lr, patch: nil,
      details: noise ? { noise_type: :white, tone_3_coupled: true } : { attenuation: 0 }
    )
  end
end
