# frozen_string_literal: true

require_relative 'vgm_channels'
require_relative 'spc_live_view'

module RubyPlayer
  module UI
    # Owns a snapshot only: App loads metadata and delivers background updates.
    class NowPlayingModal
      MAX_WIDTH = 88
      ART_MIN_WIDTH = 64
      FRAME_ROWS = 6
      COMPACT_FRAME_ROWS = 4
      private_constant :MAX_WIDTH, :ART_MIN_WIDTH, :FRAME_ROWS, :COMPACT_FRAME_ROWS

      SPC_LIVE_HINT = '[Tab] Info/Live [↑/↓] Voice [0-7] Mute [S] Solo [o/esc/enter] Close'
      private_constant :SPC_LIVE_HINT

      # live_kind is :vgm or :spc when a live page exists for this track.
      def initialize(track, extras:, page: :info, channels: nil, live_available: nil, live_kind: nil,
                     spc_view: nil)
        @track = track
        @metadata = {}
        @extras = extras
        @page = %i[info live].include?(page) ? page : :info
        @channels = channels || VgmChannels.new
        @spc_view = spc_view || SpcLiveView.new
        @live_kind = live_kind
        @spc_state = nil
        @position_ms = nil
        @live_available = if live_kind
                            true
                          elsif live_available.nil?
                            %w[vgm vgz].include?(track.format.to_s.downcase)
                          else
                            live_available ? true : false
                          end
      end

      attr_reader :page, :live_kind

      # The App hands over the engine's SPC state before each render.
      def update_spc(state:, position_ms:)
        @spc_state = state
        @position_ms = position_ms
      end

      def page=(page)
        @page = %i[info live].include?(page) ? page : :info
      end

      def handle_live_key(key) = @live_kind == :spc ? @spc_view.handle_key(key) : @channels.handle_key(key)

      def matches?(track)
        track && [track.id, track.physical_path, track.archive_entry, track.subtune_index] ==
          [@track.id, @track.physical_path, @track.archive_entry, @track.subtune_index]
      end

      def update(metadata)
        @metadata = metadata
        @extras = metadata[:extra] if metadata.key?(:extra)
      end

      def render(screen, theme:, frame:, min_art_rows:)
        return if screen.rows < 5 || screen.cols < 8
        return render_spc_live(screen, theme: theme, frame: frame) if @page == :live && @live_kind == :spc
        return render_live(screen, theme: theme, frame: frame) if @page == :live

        width = (screen.cols - 2).clamp(4, MAX_WIDTH)
        max_height = screen.rows - 2
        return render_tiny(theme: theme, frame: frame, screen: screen, width: width, height: max_height) if max_height < 8

        compact = max_height < 12
        frame_rows = compact ? COMPACT_FRAME_ROWS : FRAME_ROWS
        info, tech = fitted_sections(max_height, frame_rows: frame_rows)
        top_height = info.size + 1
        # One third of the modal width, at two terminal columns per art row.
        art_height = [width / 6, max_height - tech.size - frame_rows].min
        art_width = 0
        if width >= ART_MIN_WIDTH && art_height >= min_art_rows
          top_height = [top_height, art_height].max
          art_width = [top_height * 2, width / 3].min
        end
        height = top_height + tech.size + frame_rows
        art = nil
        frame.call(title: 'Now Playing', w: width, h: height, hint: info_hint) do |x, y|
          text_x = x + 2 + (art_width.positive? ? art_width + 2 : 0)
          text_width = width - 4 - (text_x - x - 2)
          draw_section(screen, info, column: text_x, line: y + 1, width: text_width, title: 'Track', theme: theme)
          draw_section(screen, tech, column: x + 2, line: y + top_height + (compact ? 1 : 2),
                                     width: width - 4, title: 'Technical', theme: theme)
          art = { x: x + 2, y: y + 1, w: art_width, h: top_height } if art_width.positive?
        end
        art
      end

      private

      def render_live(screen, theme:, frame:)
        width = (screen.cols - 2).clamp(4, MAX_WIDTH)
        height = screen.rows - 2
        hint = '[Tab] Info/Live [↑/↓] Select [PgUp/PgDn] Scroll [←/→] Detail [o/esc/enter] Close'
        if height < 6
          frame.call(title: 'Now Playing', w: width, h: height, hint: hint, styled_hint: true)
          return nil
        end

        frame.call(title: 'Now Playing', w: width, h: height, hint: hint, styled_hint: true) do |x, y|
          track_title = [value(:title), value(:artist)].compact.reject(&:empty?).join(' — ')
          summary = ['VGM', @extras['sound_chips'], 'Info / Live'].compact.join(' · ')
          screen.put(y + 1, x + 2, track_title[0, width - 4], fg: theme[:primary], bold: true)
          screen.put(y + 2, x + 2, summary[0, width - 4], fg: theme[:text_muted])
          @channels.render(screen, x: x + 2, y: y + 3, width: width - 4,
                                   height: [height - 6, 1].max, theme: theme)
        end
        nil
      end

      # Unlike the VGM page, the SPC page fills the screen: it shows every
      # voice, panel, and the sample directory at once.
      def render_spc_live(screen, theme:, frame:)
        width = [screen.cols - 2, 4].max
        height = screen.rows - 2
        frame.call(title: 'Now Playing', w: width, h: height, hint: SPC_LIVE_HINT, styled_hint: true) do |x, y|
          track_title = [value(:title), value(:artist)].compact.reject(&:empty?).join(' — ')
          @spc_view.render(screen, x: x + 2, y: y + 1, width: width - 4, height: [height - 3, 0].max,
                                   theme: theme, state: @spc_state, track_title: track_title,
                                   position_ms: @position_ms)
        end
        nil
      end

      def info_hint
        @live_available ? '[Tab] Info / Live · [o/esc/enter] Close' : '[o/esc/enter] Close'
      end

      def value(field)
        @metadata.key?(field) ? @metadata[field] : @track.public_send(field)
      end

      def artist_rows
        rows = [['Title', value(:title)], ['Artist', value(:artist)], ['Album artist', value(:album_artist)],
                ['Album', value(:album)], ['Track', track_number], ['Composer', value(:composer)],
                ['Year', value(:year)], ['Genre', @extras['genre']],
                ['Copyright', @extras['copyright']], ['Dumper', @extras['dumper']], ['Comment', @extras['comment']]]
        present_rows(rows)
      end

      def technical_rows
        rate = positive_number(@extras['bit_rate'])
        bitrate = format('%g kbps', rate / 1000.0) if rate
        bitrate = "#{bitrate} (average)" if bitrate && @extras['bit_rate_mode'] == 'average'
        sample_rate = positive_number(@extras['sample_rate'])
        bits = positive_number(@extras['bits_per_sample'])
        rows = [['File type', value(:format).to_s.upcase],
                ['Chips', @extras['sound_chips']], ['Voices', @extras['voice_layout']], ['System', @extras['system']],
                ['VGM version', @extras['vgm_version']], ['Chip clocks', @extras['chip_clocks']],
                ['Intro', timing('intro_length_ms')], ['Loop', timing('loop_length_ms')], ['Bit rate', bitrate],
                ['Codec', @extras['codec']&.upcase],
                ['Sample rate', sample_rate && format('%g kHz', sample_rate / 1000.0)],
                ['Channels', channels], ['Bit depth', bits && "#{bits} bit"]]
        present_rows(rows)
      end

      def timing(key)
        ms = positive_number(@extras[key])
        DurationFormatter.format(ms) if ms
      end

      def positive_number(value)
        text = value.to_s.strip
        text.to_i if text.match?(/\A\d+\z/) && text.to_i.positive?
      end

      def track_number
        number = positive_number(value(:track_number))
        return unless number

        total = positive_number(@extras['track_total'])
        total && total >= number ? "#{number} of #{total}" : number.to_s
      end

      def channels
        count = positive_number(@extras['channels'])
        return unless count

        { 1 => 'Mono', 2 => 'Stereo' }.fetch(count) { "#{count} channels" }
      end

      def present_rows(rows)
        rows.filter_map do |label, value|
          text = value.to_s.gsub(/[[:cntrl:]]/, ' ').strip
          [label, text] unless text.empty?
        end
      end

      def fitted_sections(max_height, frame_rows:)
        info = artist_rows
        tech = technical_rows
        # Artwork and optional fields yield before either section's core facts.
        while info.size + tech.size + frame_rows + 1 > max_height
          if tech.size > 2
            tech.pop
          elsif info.size > 1
            info.pop
          else
            break
          end
        end
        [info, tech]
      end

      def draw_section(screen, rows, column:, line:, width:, title:, theme:)
        screen.put(line, column, title[0, width], fg: theme[:accent], bold: true)
        draw_fields(screen, rows, column: column, line: line + 1, width: width, theme: theme)
      end

      def draw_fields(screen, rows, column:, line:, width:, theme:)
        rows.each_with_index do |(label, text), index|
          prefix = "#{label}: "
          screen.put(line + index, column, prefix[0, width], fg: theme[:text_muted])
          next if prefix.size >= width

          screen.put(line + index, column + prefix.size, text[0, width - prefix.size],
                     fg: theme[:text], bold: label == 'Title')
        end
      end

      def render_tiny(theme:, frame:, screen:, width:, height:)
        rows = [['Track', value(:title).to_s]] + technical_rows
        frame.call(title: 'Now Playing', w: width, h: height, hint: info_hint) do |x, y|
          draw_fields(screen, rows.first([height - 3, 0].max), column: x + 2, line: y + 1,
                                                               width: width - 4, theme: theme)
        end
        nil
      end
    end
  end
end
