# frozen_string_literal: true

require 'test_helper'
require 'stringio'
require 'rubyplayer/ui/screen'
require 'rubyplayer/ui/chip_live_view'

# ChipLiveView draws native chips (GBS, NSF, ...) through one panel module
# per family, found by channel kind and chip id. A stub family proves the
# dispatch is the table's, not a hard-coded branch per family.
class ChipLiveViewFamiliesTest < Minitest::Test
  Vgm = RubyPlayer::Vgm
  UI = RubyPlayer::UI
  THEME = RubyPlayer::Theme::DEFAULT

  module StubPanels
    def stub_summary(chip) = "Stub chip #{chip.name}"
    def stub_instrument_texts(_channel) = ['stub instrument']
    def stub_attenuation(_channel) = 0
    def stub_voice_lines(row, _width) = [title("Stub voice #{row.channel.label}")]
    def stub_detail?(_channel) = true
    def stub_detail_panel(_row, _width, _rows) = [title('Stub detail'), line('stub detail body')]
  end

  class StubView < UI::ChipLiveView
    include StubPanels

    STUB_FAMILY = NativePanelFamily.new(prefix: :stub, kinds: %i[stub_tone].freeze, chip_ids: %w[stub].freeze,
                                        exact_levels: true)

    def native_panel_families = [*super, STUB_FAMILY]
  end

  def test_a_registered_family_draws_every_panel
    view = StubView.new(source: 'STUB')
    view.update(snapshot)
    text = render(view).join("\n")

    assert_includes text, 'Stub chip Stubby'
    assert_includes text, 'stub instrument'
    assert_includes text, 'Stub voice Tone 1'
    assert_includes text, 'Stub detail'
    # Exact levels: the heading drops "(est.)".
    assert_match(/Level(?! \(est\.\))/, text)
  end

  def test_families_cover_the_native_chips
    families = UI::ChipLiveView::NATIVE_PANEL_FAMILIES.to_h { |family| [family.prefix, family] }

    assert_equal %i[gb nes hes], families.keys
    assert_includes families[:gb].chip_ids, 'gb_dmg'
    assert_includes families[:nes].kinds, :n163_wave
  end

  private

  def snapshot
    channel = Vgm::ChannelSnapshot.new(id: 'stub:0:0', label: 'Tone 1', kind: :stub_tone, state: :enabled,
                                       last_trigger_sample: 0, pitch_hz: 440.0, note: nil, pan: :lr, patch: nil,
                                       details: { voice: 0 })
    chip = Vgm::ChipSnapshot.new(id: 'stub:0', name: 'Stubby', clock_hz: 1_000_000, channels: [channel],
                                 details: { events: Vgm::NoteLog.new.packed })
    Vgm::Snapshot.new(generation: 1, revision: 1, sample: 0, status: :ready, message: nil, loop_count: 0,
                      chips: [chip], warnings: [])
  end

  def render(view, cols: 160, rows: 48)
    screen = UI::Screen.new(out: StringIO.new, rows: rows, cols: cols)
    view.render(screen, x: 0, y: 0, width: cols, height: rows, theme: THEME, track_title: 'Song', now_sample: 0)
    screen.instance_variable_get(:@back).map { |row| row.map(&:ch).join }
  end
end
