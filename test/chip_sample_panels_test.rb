# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/ui/chip_sample_panels'
require 'rubyplayer/vgm/envelope'

# Wave and level drawing shared by the Game Boy, NES, and HES panels.
class ChipSamplePanelsTest < Minitest::Test
  class Host
    include RubyPlayer::UI::LiveGlyphs
    include RubyPlayer::UI::ChipSamplePanels

    public :sample_sparkline, :sample_graph, :amplitude_attenuation
  end

  def setup
    @host = Host.new
  end

  # 32 samples become 16 glyphs (pairs averaged); silence is the lowest bar.
  def test_sparkline_averages_to_sixteen_glyphs_from_the_floor
    ramp = (0...32).to_a

    assert_equal 16, @host.sample_sparkline(ramp, 31).length
    assert_equal '▁', @host.sample_sparkline([0] * 32, 31)[0]
    assert_equal '█', @host.sample_sparkline([31] * 32, 31)[0]
  end

  def test_graph_widens_each_sample_to_fill_the_width_and_caps_its_height
    lines = @host.sample_graph([0, 15], 15, 8, 20)

    assert_equal 8, lines.size
    assert_equal '    ████', lines.first[:text]
    assert_equal 1, @host.sample_graph([0, 15], 15, 8, 0).size
  end

  def test_amplitude_becomes_attenuation_steps
    assert_equal 0, @host.amplitude_attenuation(1.0)
    assert_equal RubyPlayer::Vgm::Envelope::MAX_ATTENUATION_STEPS, @host.amplitude_attenuation(0)
    assert_operator @host.amplitude_attenuation(0.5), :>, 0
  end
end
