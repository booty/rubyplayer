# frozen_string_literal: true

require_relative 'live_glyphs'
require_relative '../vgm/envelope'

module RubyPlayer
  module UI
    # Wave and level drawing the native chip panel modules (Game Boy, NES,
    # HES) share. Expects LiveGlyphs#graph from the including view.
    module ChipSamplePanels
      MAX_SAMPLE_GRAPH_ROWS = 8

      private

      # Samples as one bar glyph each (pairs averaged past 16), so the shape
      # reads as one line; silence is the lowest bar, not a gap.
      def sample_sparkline(samples, max)
        group = [samples.size / 16, 1].max
        samples.each_slice(group).map { |slice| LiveGlyphs::LEVEL_GLYPHS[1 + (slice.sum * 7 / (max * slice.size))] }.join
      end

      # A bar graph of `samples`, each widened to fill `width`, `rows` tall
      # (at least one, at most MAX_SAMPLE_GRAPH_ROWS).
      def sample_graph(samples, max, width, rows)
        columns = [width / samples.size, 1].max
        graph(samples.flat_map { |sample| Array.new(columns, sample) }, max, rows.clamp(1, MAX_SAMPLE_GRAPH_ROWS))
      end

      # An output amplitude (0..1) as an attenuation like the register-model
      # chips', so every level bar shares one scale.
      def amplitude_attenuation(amplitude)
        return Vgm::Envelope::MAX_ATTENUATION_STEPS unless amplitude.positive?

        (-20 * Math.log10(amplitude) / Vgm::Envelope::DB_PER_STEP).round
      end
    end
  end
end
