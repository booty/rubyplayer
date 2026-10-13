# frozen_string_literal: true

require_relative '../duration_formatter'
require_relative '../spc/snapshot'
require_relative '../spc/dsp'
require_relative '../spc/brr'
require_relative '../spc/fir'
require_relative '../spc/ram_map'
require_relative 'live_glyphs'

module RubyPlayer
  module UI
    # Renders live S-DSP state for an SPC track inside a caller-owned
    # rectangle, using all of it: header, global row, all 8 voices, then echo,
    # sample, RAM, and sample-directory panels as space allows.
    class SpcLiveView
      include LiveGlyphs

      VOICES = Spc::VOICES
      TABLE_ROWS = VOICES + 1 # heading + one row per voice
      COMPACT_MIN_HEIGHT = 12 # below this: header + voice rows only
      THREE_COLUMN_WIDTH = 140
      TWO_COLUMN_WIDTH = 100
      WIDE_TABLE_WIDTH = 100
      STRIP_MIN_ROWS = 3   # "Samples" title + two rows of entries
      MIN_PANEL_ROWS = 8   # echo/FIR and sample panels need this many to be useful
      MAX_PANEL_ROWS = 18  # beyond this, extra height goes to the samples strip
      MIN_GRAPH_ROWS = 1
      STACKED_GRAPH_ROWS = 3
      ECHO_FIXED_ROWS = 6  # title, four info lines, filter kind
      SAMPLE_FIXED_ROWS = 4 # title, info, loop marker, users
      RAM_FIXED_ROWS = 3 # title, legend, addresses
      RAM_LABEL = '$0000 '
      RAM_SLICE_ALIGN = 0x400
      # Columns around the ENVX bar: widths plus single-space separators,
      # matching the voice_line formats.
      WIDE_FIXED_COLUMNS = 2 + 4 + 6 + 8 + 7 + 17 + 3 + 5 + 7 + 9
      NARROW_FIXED_COLUMNS = 2 + 4 + 7 + 6 + 3 + 5 + 7 + 7
      COLUMN_GAP = 2
      # A note-start edge stays bold for about two snapshots (~100 ms at 48 kHz).
      EDGE_HOLD_FRAMES = 4_800
      WAVEFORM_SAMPLES = 4_096
      ENV_MAX = 0x7ff
      RAM_GLYPHS = { samples: '▓', echo: '▒', directory: '█', other: '░' }.freeze
      GAIN_LABELS = { direct: 'dir', linear_decrease: 'lin-', exp_decrease: 'exp-',
                      linear_increase: 'lin+', bent_increase: 'bent+' }.freeze
      private_constant :VOICES, :TABLE_ROWS, :COMPACT_MIN_HEIGHT,
                       :THREE_COLUMN_WIDTH, :TWO_COLUMN_WIDTH, :WIDE_TABLE_WIDTH, :STRIP_MIN_ROWS,
                       :MIN_PANEL_ROWS, :MAX_PANEL_ROWS, :MIN_GRAPH_ROWS, :STACKED_GRAPH_ROWS,
                       :ECHO_FIXED_ROWS, :SAMPLE_FIXED_ROWS, :RAM_FIXED_ROWS, :RAM_LABEL, :RAM_SLICE_ALIGN,
                       :WIDE_FIXED_COLUMNS,
                       :NARROW_FIXED_COLUMNS, :COLUMN_GAP, :EDGE_HOLD_FRAMES,
                       :WAVEFORM_SAMPLES, :ENV_MAX, :RAM_GLYPHS,
                       :GAIN_LABELS

      attr_reader :selected_voice

      def initialize
        @selected_voice = 0
        @edge_frames = Array.new(VOICES)
        @cache_key = nil
        @derived = nil
        @caches = {}
        @derived_generation = 0
        @fingerprint_ram = nil
        @fingerprint = nil
      end

      # Key handling returns whether this widget consumed the command.
      # rubocop:disable Naming/PredicateMethod
      def handle_key(key)
        case key.to_s.downcase
        when 'up' then @selected_voice = (@selected_voice - 1).clamp(0, VOICES - 1)
        when 'down' then @selected_voice = (@selected_voice + 1).clamp(0, VOICES - 1)
        else return false
        end
        true
      end
      # rubocop:enable Naming/PredicateMethod

      # Screen rectangle coordinates use the Screen API's short x/y names.
      # rubocop:disable Naming/MethodParameterName
      def render(screen, x:, y:, width:, height:, theme:, state:, track_title:, position_ms: nil)
        return if width <= 0 || height <= 0

        @screen = screen
        @left = x
        @top = y
        @width = width
        @height = height
        @theme = theme
        @mute_mask = state&.mute_mask || 0
        put(0, header(sanitize(track_title), state, position_ms), fg: theme[:accent], bold: true)
        snapshot = state&.snapshot
        return put(1, 'Waiting for SPC state', fg: theme[:text_muted]) unless snapshot

        render_state(state, snapshot, height)
      end
      # rubocop:enable Naming/MethodParameterName

      private

      def render_state(state, snapshot, height)
        remember_edges(snapshot)
        regs = snapshot.regs
        voices = Array.new(VOICES) { |index| Spc::Dsp.voice(regs, index) }
        global = Spc::Dsp.global(regs)
        if height < COMPACT_MIN_HEIGHT
          render_voice_rows(1, snapshot, voices, height - 1)
          return
        end

        put(1, global_line(global), fg: @theme[:text])
        put(2, table_heading, fg: @theme[:text_muted], bold: true)
        render_voice_rows(3, snapshot, voices, VOICES)
        render_panels(2 + TABLE_ROWS, height - 2 - TABLE_ROWS, state, voices, global)
      end

      # -- header, global row, voice table ----------------------------------

      def header(track_title, state, position_ms)
        parts = [track_title.to_s, 'S-DSP LIVE']
        parts << format_time(position_ms) if position_ms
        parts << (state&.paused ? 'PAUSED' : 'PLAYING')
        parts.reject(&:empty?).join(' · ')
      end

      def global_line(global)
        flg = global[:flg]
        flags = ["echo-write #{flg[:echo_write] ? 'on' : 'OFF'}", "noise #{format_hz(flg[:noise_hz])}"]
        flags << 'MUTE' if flg[:mute]
        flags << 'RESET' if flg[:reset]
        ["MVOL #{volume_pair(global[:mvol], global[:mvol_inverted])}",
         "EVOL #{volume_pair(global[:evol], global[:evol_inverted])}",
         "FLG #{flags.join(', ')}",
         "KON #{mask_dots(global[:kon])}", "KOFF #{mask_dots(global[:koff])}",
         "ENDX #{mask_dots(global[:endx])}"].join('   ')
      end

      def table_heading
        unless wide_table?
          return format('%-2s %-4s %-7s %-6s %-*s %-3s %-5s %s', '#', 'Smp', 'Rate', 'Env', bar_width, 'ENVX', 'Out', 'ENPM',
                        'State')
        end

        format('%-2s %-4s %-6s %-8s %-7s %-17s %-*s %-3s %-5s %s', '#', 'Smp', 'Pitch', 'Rate', 'Pan', 'Envelope',
               bar_width, 'ENVX', 'Out', 'ENPM', 'State')
      end

      def render_voice_rows(first_row, snapshot, voices, rows)
        voices.first([rows, 0].max).each_with_index do |voice, index|
          selected = index == @selected_voice
          muted = muted?(index)
          put(first_row + index, voice_line(index, voice, snapshot, muted),
              fg: selected ? @theme[:selection_text] : voice_color(snapshot, index, muted),
              bg: selected ? @theme[:selection_bg] : nil,
              bold: selected || recent_edge?(index, snapshot.frame), dim: muted)
        end
      end

      def voice_line(index, voice, snapshot, muted)
        env = snapshot.env[index]
        state = voice_state(snapshot, index)
        bar = level_bar(env, ENV_MAX, bar_width)
        out = level_glyph(voice[:outx].abs, 128)
        unless wide_table?
          return format('%-2d %-4d %-7s %-6s %s %-3s %-5s %s', index, voice[:srcn], format_khz(voice[:rate_hz]),
                        envelope_short(voice), bar, out, flag_text(voice, muted), state)
        end

        format('%-2d %-4d %-6s %-8s %-7s %-17s %s %-3s %-5s %s', index, voice[:srcn], format('$%04X', voice[:pitch]),
               format_khz(voice[:rate_hz]), pan_text(voice), envelope_text(voice), bar, out,
               flag_text(voice, muted), state)
      end

      def voice_state(snapshot, index)
        mode = Spc::Snapshot::ENV_MODES.fetch(snapshot.env_mode[index], :release)
        return '·' if mode == :release && snapshot.env[index].zero?

        mode.to_s
      end

      def voice_color(snapshot, index, muted)
        muted || snapshot.env[index].zero? ? @theme[:text_muted] : @theme[:text]
      end

      def muted?(index) = @mute_mask[index] == 1

      def remember_edges(snapshot)
        VOICES.times do |index|
          @edge_frames[index] = snapshot.frame if snapshot.attack_edges[index] == 1
        end
      end

      def recent_edge?(index, frame)
        edge = @edge_frames[index]
        edge && frame >= edge && frame - edge <= EDGE_HOLD_FRAMES
      end

      # -- panels -------------------------------------------------------------

      def render_panels(top, rows, state, voices, global)
        return put(top, 'Waiting for SPC RAM', fg: @theme[:text_muted]) unless state.ram

        return unless rows.positive?

        derived = derive(state.ram, voices, global)
        if @width < TWO_COLUMN_WIDTH || rows < MIN_PANEL_ROWS + STRIP_MIN_ROWS
          return render_stacked(top, rows, derived, voices, global)
        end

        # Panels grow (taller graphs) up to a cap; the samples strip takes the rest.
        panel_rows = (rows - STRIP_MIN_ROWS).clamp(0, MAX_PANEL_ROWS)
        if @width >= THREE_COLUMN_WIDTH
          width = column_width(3)
          render_columns(top, panel_rows, [echo_panel(global, width, panel_rows),
                                           sample_panel(derived, voices, width, panel_rows),
                                           ram_panel(derived, global, width, panel_rows)])
        else
          render_two_columns(top, panel_rows, derived, voices, global)
        end
        render_strip(top + panel_rows, rows - panel_rows, derived, voices)
      end

      # Echo/FIR and sample side by side; the RAM map spans the full width below.
      def render_two_columns(top, rows, derived, voices, global)
        ram_rows = rows >= MIN_PANEL_ROWS + RAM_FIXED_ROWS + MIN_GRAPH_ROWS ? RAM_FIXED_ROWS + 2 : 0
        upper = rows - ram_rows
        width = column_width(2)
        render_columns(top, upper, [echo_panel(global, width, upper), sample_panel(derived, voices, width, upper)])
        render_block(top + upper, 0, @width, ram_rows, ram_panel(derived, global, @width, ram_rows))
      end

      # Narrow or short areas stack panels. To fit, graphs shrink first, then
      # the RAM map goes, then the FIR graph.
      def render_stacked(top, rows, derived, voices, global)
        blocks = nil
        STACKED_GRAPH_ROWS.downto(MIN_GRAPH_ROWS) do |graph|
          blocks = stacked_blocks(derived, voices, global, graph)
          break if blocks.sum(&:size) <= rows
        end
        blocks.pop while blocks.size > 1 && blocks.sum(&:size) > rows
        blocks[0] = blocks[0].reject { |line| line[:graph] } if blocks.sum(&:size) > rows
        render_block(top, 0, @width, rows, blocks.flatten)
      end

      def stacked_blocks(derived, voices, global, graph)
        [echo_panel(global, @width, ECHO_FIXED_ROWS + graph),
         sample_panel(derived, voices, @width, SAMPLE_FIXED_ROWS + graph),
         ram_panel(derived, global, @width, RAM_FIXED_ROWS + 1)]
      end

      def render_columns(top, rows, panels)
        width = column_width(panels.size)
        panels.each_with_index do |panel, index|
          render_block(top, index * (width + COLUMN_GAP), width, rows, panel)
        end
      end

      def column_width(count) = (@width - (COLUMN_GAP * (count - 1))) / count

      def render_block(top, column, width, rows, lines)
        lines.first([rows, 0].max).each_with_index do |line, index|
          put(top + index, line[:text][0, width], column: column, fg: @theme[line[:color] || :text],
                                                  bold: line[:bold] || false)
        end
      end

      def graph_rows(rows, fixed) = [rows - fixed, MIN_GRAPH_ROWS].max

      def echo_panel(global, width, rows)
        voices = (0...VOICES).select { |index| global[:eon][index] == 1 }
        writes = global[:flg][:echo_write] ? 'writes on' : 'writes OFF'
        graph_height = graph_rows(rows, ECHO_FIXED_ROWS)
        fir_graph = cached(:fir_graph, [global[:fir], width, graph_height]) do
          curve = Spc::Fir.response(global[:fir], points: width).map { |db| db - Spc::Fir::MIN_DB }
          graph(curve, Spc::Fir::MAX_DB - Spc::Fir::MIN_DB, graph_height)
        end
        kind = cached(:fir_kind, global[:fir]) { Spc::Fir.kind(global[:fir]) }
        [title('Echo / FIR'),
         line("Delay #{global[:delay_ms]} ms · FB #{signed(global[:efb])} · Vol #{volume_pair(global[:evol],
                                                                                              global[:evol_inverted])}"),
         line(format('Buffer $%04X · %.1f KB · %s', global[:esa] * 0x100, global[:echo_bytes] / 1024.0, writes)),
         line("Echo on: #{voices.empty? ? 'none' : voices.join(' ')}"),
         line("FIR #{global[:fir].join(' ')}"),
         *fir_graph,
         line("#{kind} · 50 Hz – 16 kHz", color: :text_muted)]
      end

      def sample_panel(derived, voices, width, rows)
        srcn = voices.fetch(@selected_voice)[:srcn]
        entry = derived[:directory].find { |item| item[:srcn] == srcn }
        heading = title("Sample #{srcn} · voice #{@selected_voice}")
        return [heading, line('Not a valid sample', color: :warning)] unless entry&.[](:info)

        info = entry[:info]
        users = voices.each_index.select { |index| voices[index][:srcn] == srcn }
        [heading,
         line(format('start $%04X · loop $%04X · %s · %s', entry[:start], entry[:loop],
                     format_samples(info[:samples]), info[:looped] ? 'looped' : 'one-shot')),
         *cached(:waveform, [@derived_generation, srcn, width, rows]) do
           waveform_lines(derived, entry, width, graph_rows(rows, SAMPLE_FIXED_ROWS))
         end,
         line("Used by voices #{users.join(' ')}", color: :text_muted)]
      end

      # One row per equal slice of RAM, each prefixed with its start address.
      def ram_panel(derived, global, width, rows)
        legend = RAM_GLYPHS.map { |kind, glyph| "#{glyph} #{kind}" }.join('  ')
        bar_width = [width - RAM_LABEL.length, 1].max
        # Round slices up to $400 so row labels read as tidy addresses.
        slice = ((Spc::RamMap::RAM_BYTES / graph_rows(rows, RAM_FIXED_ROWS).to_f) / RAM_SLICE_ALIGN).ceil * RAM_SLICE_ALIGN
        bars = cached(:ram_bars, [@derived_generation, width, slice]) do
          Array.new(Spc::RamMap::RAM_BYTES.fdiv(slice).ceil) do |row|
            from = row * slice
            to = [from + slice, Spc::RamMap::RAM_BYTES].min
            { text: format('$%04X ', from) + ram_bar(derived[:regions], from, to, bar_width), color: :primary }
          end
        end
        [title('ARAM 64 KB'), *bars, line(legend, color: :text_muted),
         line(format('DIR $%04X · ESA $%04X', global[:dir] * 0x100, global[:esa] * 0x100))]
      end

      def render_strip(top, rows, derived, voices)
        return unless rows.positive?

        in_use = voices.map { |voice| voice[:srcn] }
        cells = cached(:strip, [@derived_generation, in_use]) do
          derived[:directory].select { |entry| entry[:info] }
                             .sort_by { |entry| [in_use.include?(entry[:srcn]) ? 0 : 1, entry[:srcn]] }
                             .map { |entry| strip_cell(entry, voices) }
        end

        put(top, 'Samples', fg: @theme[:accent], bold: true)
        cell_width = (cells.map(&:length).max || 0) + 3
        per_row = [(@width / [cell_width, 1].max), 1].max
        cells.each_slice(per_row).first(rows - 1).each_with_index do |slice, index|
          put(top + 1 + index, slice.map { |cell| cell.ljust(cell_width) }.join, fg: @theme[:text])
        end
      end

      def strip_cell(entry, voices)
        users = voices.each_index.select { |index| voices[index][:srcn] == entry[:srcn] }
        info = entry[:info]
        format('%3d $%04X %s%s%s', entry[:srcn], entry[:start], format_samples(info[:samples]),
               info[:looped] ? ' loop' : '', users.empty? ? '' : " V#{users.join(',')}")
      end

      # -- derived data (cached per RAM copy) ------------------------------

      # Directory, sample, and RAM-map data depend on every RAM byte except the
      # echo buffer, which the DSP rewrites constantly. Keying on a fingerprint
      # of exactly that catches rewritten samples, wrapped directories, and
      # track changes, while the engine's fresh RAM copy every decode chunk
      # still hits the cache when nothing relevant changed.
      def derive(ram, voices, global)
        in_use = voices.map { |voice| voice[:srcn] }.uniq.sort
        key = [ram_fingerprint(ram, global), in_use, global[:dir], global[:esa], global[:edl]]
        return @derived if key == @cache_key

        directory = Spc::Brr.directory(ram, global[:dir], in_use: in_use)
        @cache_key = key
        # Panel caches key on this counter, not the hash itself, which would
        # deep-compare 64 KB of RAM on every frame.
        @derived_generation += 1
        @derived = { ram: ram, directory: directory, waveforms: {},
                     regions: Spc::RamMap.regions(global: global, directory: directory) }
      end

      # Hashed once per RAM copy (~3 a second), not per frame.
      def ram_fingerprint(ram, global)
        return @fingerprint if ram.equal?(@fingerprint_ram)

        echo_start = global[:esa] * 0x100
        echo_end = echo_start + global[:echo_bytes]
        outside = if echo_end <= Spc::RamMap::RAM_BYTES
                    [ram.byteslice(0, echo_start), ram.byteslice(echo_end..)]
                  else # the echo buffer wraps past $FFFF
                    [ram.byteslice((echo_end - Spc::RamMap::RAM_BYTES)...echo_start)]
                  end
        @fingerprint_ram = ram
        @fingerprint = outside.map(&:hash)
      end

      # One entry per panel: a result is reused only while that panel's own
      # inputs are unchanged, so memory stays bounded and unrelated changes
      # (an instrument switch) don't discard it. Building graph lines per
      # frame dominated render time (~3 ms at 158 columns).
      def cached(name, key)
        stored_key, value = @caches[name]
        return value if @caches.key?(name) && stored_key == key

        value = yield
        @caches[name] = [key, value]
        value
      end

      def waveform_lines(derived, entry, width, rows)
        samples = derived[:waveforms][entry[:srcn]] ||=
          Spc::Brr.decode(derived[:ram], entry[:start], max_samples: WAVEFORM_SAMPLES)
        return [] if samples.empty?

        peaks = Array.new(width) do |cell|
          from = cell * samples.size / width
          to = [((cell + 1) * samples.size / width), from + 1].max
          samples[from...to].map(&:abs).max || 0
        end
        lines = graph(peaks, 32_768, rows)
        marker = loop_marker(entry, samples.size, width)
        lines << line(marker, color: :text_muted) if marker
        lines
      end

      def loop_marker(entry, decoded, width)
        return unless entry[:info][:looped]

        offset = (entry[:loop] - entry[:start]) / Spc::Brr::BLOCK_BYTES * Spc::Brr::SAMPLES_PER_BLOCK
        return unless offset < decoded

        "#{' ' * (offset * width / decoded)}▲ loop"
      end

      # Dominant region kind for each cell of the byte range from...to.
      def ram_bar(regions, from, to, width)
        Array.new(width) do |cell|
          low = from + (cell * (to - from) / width)
          high = from + ((cell + 1) * (to - from) / width)
          dominant = regions.max_by { |region| [[region[:to], high].min - [region[:from], low].max, 0].max }
          RAM_GLYPHS.fetch(dominant[:kind])
        end.join
      end

      # -- formatting -------------------------------------------------------

      def wide_table? = @width >= WIDE_TABLE_WIDTH

      # The ENVX bar takes whatever the fixed columns leave, within reason.
      def bar_width
        (@width - (wide_table? ? WIDE_FIXED_COLUMNS : NARROW_FIXED_COLUMNS)).clamp(4, 32)
      end

      def envelope_text(voice)
        adsr = voice[:adsr]
        return format('ADSR A%d D%d S%d R%d', adsr[:ar], adsr[:dr], adsr[:sl], adsr[:sr]) if adsr[:enabled]

        gain = voice[:gain]
        "GAIN #{GAIN_LABELS.fetch(gain[:mode])} #{gain[:value]}"
      end

      def envelope_short(voice) = voice[:adsr][:enabled] ? 'ADSR' : 'GAIN'

      def pan_text(voice)
        return 'SURR' if voice[:pan] == :surround

        position = ((voice[:balance] + 1) * 2).round.clamp(0, 4)
        dots = Array.new(5, '·')
        dots[position] = '●'
        "L#{dots.join}R"
      end

      def flag_text(voice, muted)
        [voice[:echo] ? 'E' : '·', voice[:noise] ? 'N' : '·', voice[:pmod] ? 'P' : '·', muted ? 'M' : ''].join
      end

      def mask_dots(mask) = Array.new(VOICES) { |index| mask[index] == 1 ? '●' : '·' }.join

      def volume_pair(pair, inverted)
        "#{pair.join('/')}#{' (inv)' if inverted}"
      end

      def signed(value) = value.positive? ? "+#{value}" : value.to_s
      def format_khz(frequency) = format('%.1fk', frequency / 1000.0)
      def format_hz(frequency) = frequency >= 1000 ? format('%.1f kHz', frequency / 1000.0) : "#{frequency} Hz"
      def format_samples(count) = count >= 1000 ? format('%.1fk smp', count / 1000.0) : "#{count} smp"

      def format_time(milliseconds) = DurationFormatter.format(milliseconds.to_i)

      def title(text) = { text: text, color: :accent, bold: true }
      def line(text, color: :text) = { text: text, color: color }

      # Only the track title comes from outside (file tags); the rest is ours.
      def sanitize(text) = text.to_s.gsub(/[[:cntrl:]]/, ' ')

      # Clips to the widget's rectangle so nothing paints outside it.
      def put(row, text, column: 0, **style)
        available = @width - column
        return unless available.positive? && row.between?(0, @height - 1)

        @screen.put(@top + row, @left + column, text[0, available], **style)
      end
    end
  end
end
