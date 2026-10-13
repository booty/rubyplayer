# frozen_string_literal: true

module RubyPlayer
  module UI
    # The volume-envelope chart the Game Boy and NES panels draw: a volume
    # curve from the last trigger over a fixed span, a marker at the time
    # being heard, and a time axis. The envelope rules themselves (pace,
    # looping, length cut-off) stay in each chip's panel module, which
    # supplies the curve. Relies on ChipLiveView's line/title/graph helpers.
    module EnvelopeChart
      # Chart spans, in seconds: the shortest that shows the whole envelope
      # (or its length cut-off) is used.
      ENVELOPE_SPANS = [0.25, 0.5, 1.0, 2.0, 4.0].freeze
      ENVELOPE_GRAPH_ROWS = 8
      ENVELOPE_MAX_VOLUME = 15

      private

      # The shortest chart span covering `seconds` (the longest when none does).
      def envelope_span_seconds(seconds) = ENVELOPE_SPANS.find { |span| span >= seconds } || ENVELOPE_SPANS.last

      # Seconds since the channel's last trigger, at the sample being heard.
      def seconds_since_trigger(channel)
        trigger = channel.last_trigger_sample
        trigger && (@playback_sample - trigger).fdiv(Vgm::SAMPLE_RATE)
      end

      # Yields seconds since the trigger for each column; the block returns
      # the volume (0-15) then.
      def envelope_chart(summary:, span_seconds:, elapsed_seconds:, width:, rows:)
        columns = [width, 8].max
        values = Array.new(columns) { |column| yield span_seconds * column / columns }
        lines = [title('Volume envelope'), line(summary, color: :text_muted),
                 *graph(values, ENVELOPE_MAX_VOLUME, (rows - 4).clamp(1, ENVELOPE_GRAPH_ROWS))]
        now = elapsed_seconds && elapsed_seconds < span_seconds
        marker = now ? "#{' ' * (elapsed_seconds / span_seconds * columns).floor}▲ now" : ''
        lines << line(marker[0, width], color: :accent)
        label = format_span(span_seconds)
        lines << line("trigger #{'─' * [width - label.length - 9, 0].max} #{label}", color: :text_muted)
      end

      def format_span(seconds) = seconds < 1 ? "#{(seconds * 1000).round} ms" : "#{seconds.to_s.delete_suffix('.0')} s"
    end
  end
end
