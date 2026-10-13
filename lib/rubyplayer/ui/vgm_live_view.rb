# frozen_string_literal: true

require_relative '../duration_formatter'
require_relative '../vgm/snapshot'
require_relative '../vgm/envelope'
require_relative '../vgm/note_log'
require_relative '../vgm/pitch'
require_relative 'live_glyphs'
require_relative 'envelope_chart'
require_relative 'gb_live_panels'
require_relative 'live_panel_renderer'
require_relative 'nes_live_panels'

module RubyPlayer
  module UI
    # Renders live chip state inside a caller-owned rectangle, using all of
    # it: header, one line per chip, every channel with its level, then a
    # keyboard and voice, envelope, and note-history panels as space allows.
    # Like SpcLiveView, the layout is chosen from the rectangle.
    #
    # VGM snapshots come from register replay at the telemetry rate (~15 Hz)
    # and lag the audio a little; GBS and NSF snapshots come from
    # Gbs::Tracker and Nsf::Tracker. Levels
    # and history are drawn against `now_sample`, the sample being heard, so
    # they move smoothly between snapshots.
    class VgmLiveView
      include LiveGlyphs
      include LivePanelRenderer
      include EnvelopeChart
      include GbLivePanels
      include NesLivePanels

      CHANNEL_KEYS = [*'1'..'9', *'a'..'z'].freeze
      # NSF chips follow libgme's voice order, 2A03 first.
      CHIP_ORDER = { 'ym2612' => 0, 'sn76489' => 1, 'ym2413' => 2, 'gb_dmg' => 3, '2a03' => 4, 'vrc6' => 5, 'n163' => 6,
                     's5b' => 7, 'fds' => 8, 'mmc5' => 9, 'vrc7' => 10 }.freeze
      THREE_COLUMN_WIDTH = 150
      TWO_COLUMN_WIDTH = 100
      WIDE_TABLE_WIDTH = 110
      MIN_PANEL_ROWS = 6
      KEYBOARD_ROWS = 3 # octave labels, black keys, white keys
      # Columns around the level bar, matching the channel_line formats.
      WIDE_FIXED_COLUMNS = 1 + 1 + 14 + 1 + 4 + 1 + 7 + 1 + 8 + 1 + 1 + 3 + 1 + 18 + 1 + 9
      NARROW_FIXED_COLUMNS = 1 + 1 + 14 + 1 + 7 + 1 + 1 + 9
      # Bars span 48 dB: quieter than that reads as silent at a glance.
      LEVEL_FLOOR_DB = 48.0
      # A trigger stays bold for about two telemetry refreshes.
      RECENT_TRIGGER_SAMPLES = 4_410
      # One history column per 100 ms of source time.
      HISTORY_COLUMN_SAMPLES = Vgm::SAMPLE_RATE / 10
      # MIDI range drawn when the keyboard fits: C1 to B7.
      KEYBOARD_LOW = 24
      KEYBOARD_KEYS = 84
      BLACK_KEYS = [1, 3, 6, 8, 10].freeze
      # Envelope sketches: a log time axis while held (1 ms - 2 s), then
      # after key-off (1 ms - 1 s), so fast attacks and slow decays both show.
      HOLD_AXIS = [0.001, 2.0].freeze
      RELEASE_AXIS = [0.001, 1.0].freeze
      PAN_LABELS = { lr: 'L R', l: 'L  ', r: '  R', none: '---' }.freeze
      STATE_LABELS = { key_on: 'key on', key_off: 'key off', enabled: 'on', muted: 'off', off: 'off', data: 'data',
                       idle: 'idle' }.freeze
      ACTIVE_STATES = %i[key_on enabled data].freeze
      # YM2612 algorithms. Operator 1 has feedback; ▶ is the output. All
      # are padded to the tallest so the panel below does not jump when a
      # channel changes algorithm.
      ALGORITHMS = [
        ['1→2→3→4→▶', '', '', ''],
        ['1──┐', '2──┴→3→4→▶', '', ''],
        ['1─────┐', '2→3───┴→4→▶', '', ''],
        ['1→2─┐', '3───┴→4→▶', '', ''],
        ['1→2─┐', '3→4─┴→▶', '', ''],
        ['  ┌→2─┐', '1─┼→3─┼→▶', '  └→4─┘', ''],
        ['1→2─┐', '  3─┼→▶', '  4─┘', ''],
        ['1─┐', '2─┤', '3─┼→▶', '4─┘']
      ].freeze
      # Spelled-out forms of the short FM terms, shown when there is room.
      # Topology in operator numbers; carriers are the operators heard.
      ALGORITHM_NAMES = ['serial chain, 1 carrier', '1+2 into 3→4, 1 carrier', '1 + 2→3 into 4, 1 carrier',
                         '1→2 + 3 into 4, 1 carrier', 'two 2-op pairs, 2 carriers', '1 into 2, 3, 4, 3 carriers',
                         '1→2 pair + 3, 4, 3 carriers', 'four parallel, 4 carriers'].freeze
      # OP1 self-modulation depth (Sega's YM2612 manual).
      FEEDBACK_NAMES = %w[off π/16 π/8 π/4 π/2 π 2π 4π].freeze
      # LFO tremolo depth (AMS) and vibrato depth (FMS) per sensitivity.
      AMS_NAMES = ['0 dB', '1.4 dB', '5.9 dB', '11.8 dB'].freeze
      FMS_NAMES = ['0¢', '±3.4¢', '±6.7¢', '±10¢', '±14¢', '±20¢', '±40¢', '±80¢'].freeze
      INSTRUMENT_WIDTH = 18
      # Longest instrument wording; wider would only push State away.
      MAX_INSTRUMENT_WIDTH = 64
      FM_OPERATOR_FIELDS = [%w[AR ar], %w[D1R d1r], %w[D1L d1l], %w[D2R d2r], %w[RR rr], %w[TL tl], %w[MUL mul],
                            %w[DT dt], %w[RS rs], %w[AM am], %w[SSG ssg_eg]].freeze
      OPLL_OPERATOR_FIELDS = [%w[AR ar], %w[DR dr], %w[SL sl], %w[RR rr], %w[TL total_level], %w[MUL mul],
                              %w[KSL key_scale_level], %w[WAV waveform], %w[AM am], %w[PM pm], %w[EG eg],
                              %w[KSR ksr]].freeze
      DRUM_ABBREVIATIONS = { bass_drum: 'BD', snare: 'SD', tom: 'TOM', cymbal: 'CYM', hi_hat: 'HH' }.freeze
      OPERATOR_LABEL_WIDTH = 3
      MIN_OPERATOR_LEVEL = 8
      private_constant :CHANNEL_KEYS, :CHIP_ORDER, :THREE_COLUMN_WIDTH, :TWO_COLUMN_WIDTH, :WIDE_TABLE_WIDTH,
                       :MIN_PANEL_ROWS, :KEYBOARD_ROWS, :WIDE_FIXED_COLUMNS, :NARROW_FIXED_COLUMNS,
                       :LEVEL_FLOOR_DB, :RECENT_TRIGGER_SAMPLES, :HISTORY_COLUMN_SAMPLES, :KEYBOARD_LOW,
                       :KEYBOARD_KEYS, :BLACK_KEYS, :HOLD_AXIS, :RELEASE_AXIS, :PAN_LABELS, :STATE_LABELS,
                       :ACTIVE_STATES, :ALGORITHMS, :ALGORITHM_NAMES, :FEEDBACK_NAMES, :AMS_NAMES, :FMS_NAMES,
                       :INSTRUMENT_WIDTH, :MAX_INSTRUMENT_WIDTH, :FM_OPERATOR_FIELDS, :OPLL_OPERATOR_FIELDS,
                       :DRUM_ABBREVIATIONS, :OPERATOR_LABEL_WIDTH, :MIN_OPERATOR_LEVEL

      # One channel table row; `voice` is its index within its chip.
      Row = Struct.new(:chip, :channel, :voice, :key)
      private_constant :Row

      attr_reader :selected_channel_id, :snapshot
      attr_accessor :paused

      # `source` names the format in the header ("VGM LIVE", "GBS LIVE").
      def initialize(source: 'VGM')
        @source = source
        @snapshot = nil
        @rows = []
        @selected_channel_id = nil
        @selected_index = 0
        @scroll = 0
        @paused = false
        @last_generation = nil
        @caches = {}
        reset_source_state
      end

      def update(snapshot)
        previous_id = @selected_channel_id
        if snapshot && snapshot.generation != @last_generation
          @selected_index = 0
          @scroll = 0
          previous_id = nil
          reset_source_state
        end
        @last_generation = snapshot.generation if snapshot
        @snapshot = snapshot
        @rows = build_rows(snapshot)
        return self unless snapshot

        decode_history(snapshot)
        track_dac_rates(snapshot)
        selected = @rows.index { |row| row.channel.id == previous_id }
        @selected_index = selected || 0
        @selected_channel_id = @rows[@selected_index]&.channel&.id
        self
      end

      # Key handling returns whether this widget consumed the command.
      # rubocop:disable Naming/PredicateMethod
      def handle_key(key)
        return false if @rows.empty?

        page = [@visible_rows || 1, 1].max
        case key.to_s.downcase
        when 'up' then select(@selected_index - 1)
        when 'down' then select(@selected_index + 1)
        when 'pageup' then select(@selected_index - page)
        when 'pagedown' then select(@selected_index + page)
        else return false
        end
        true
      end
      # rubocop:enable Naming/PredicateMethod

      # libgme voice bits behind the selected channel; 0 when it cannot be
      # muted. Some channels share a voice (the PSG beside an FM chip, OPLL
      # channels 6-9), so muting one mutes its group.
      def selected_mute_bits
        row = @rows[@selected_index]
        row ? mute_bits(row) : 0
      end

      # Every libgme voice bit this track has: muting all of them but one
      # solos it.
      def all_mute_bits
        bits = @rows.reduce(0) { |all, row| all | mute_bits(row) }
        # Voice 6 exists whether or not it has a row: PCM while the YM2612's
        # DAC is off, OPLL rhythm while the chip is melodic. Leaving it out
        # would let it play through a solo once the track turns it on.
        bits |= 1 << 6 if @rows.any? { |row| row.chip.id.start_with?('ym2612', 'ym2413') }
        bits
      end

      # Screen rectangle coordinates use the Screen API's short x/y names.
      # rubocop:disable Naming/MethodParameterName
      # `position_ms` is the track position for the header clock, when
      # now_sample counts something else (GBS: output frames since launch).
      def render(screen, x:, y:, width:, height:, theme:, track_title: '', now_sample: nil, mute_mask: 0,
                 position_ms: nil)
        return if width <= 0 || height <= 0

        @screen = screen
        @left = x
        @top = y
        @width = width
        @height = height
        @theme = theme
        @mute_mask = mute_mask || 0
        # Two timelines: history and envelope markers follow the sample being
        # heard (for GBS and NSF, output frames since launch); the header
        # shows the track position.
        @playback_sample = [now_sample || 0, @snapshot&.sample || 0].max
        @display_position_sample = if position_ms
                                     position_ms * Vgm::SAMPLE_RATE / 1000
                                   else
                                     @playback_sample
                                   end
        put(0, header(sanitize(track_title)), fg: theme[:accent], bold: true)
        return put(1, status_message(:loading), fg: theme[:text_muted]) unless @snapshot
        return render_empty if @rows.empty?

        render_state
      end
      # rubocop:enable Naming/MethodParameterName

      private

      def reset_source_state
        @history = {}
        @history_packed = {}
        @history_version = 0
        @dac_rates = {}
        @dac_previous = {}
        @caches.clear
      end

      def build_rows(snapshot)
        chips = Array(snapshot&.chips).sort_by { |chip| [CHIP_ORDER.fetch(chip.id.split(':').first, 3), chip.id] }
        rows = chips.flat_map do |chip|
          chip.channels.map { |channel| Row.new(chip, channel, channel.id.split(':').last.to_i) }
        end
        rows.each_with_index { |row, index| row.key = CHANNEL_KEYS[index] || ' ' }
      end

      def select(index)
        @selected_index = index.clamp(0, @rows.size - 1)
        @selected_channel_id = @rows[@selected_index].channel.id
      end

      # -- layout -------------------------------------------------------------

      def render_state
        info = chip_lines
        fixed = 1 + info.size + 1 + @rows.size
        if @height < fixed + MIN_PANEL_ROWS
          # Short: the channel table scrolls under the header; panels are dropped.
          put(1, table_heading, fg: @theme[:text_muted], bold: true)
          render_channel_rows(2, @height - 2)
          return
        end

        render_block(1, 0, @width, info.size, info)
        put(1 + info.size, table_heading, fg: @theme[:text_muted], bold: true)
        render_channel_rows(2 + info.size, @rows.size)
        render_panels(fixed, @height - fixed)
      end

      def render_panels(top, rows)
        if rows >= KEYBOARD_ROWS + MIN_PANEL_ROWS + 1
          render_keyboard(top + 1)
          top += KEYBOARD_ROWS + 2
          rows -= KEYBOARD_ROWS + 2
        end
        return unless rows.positive?

        if @width >= THREE_COLUMN_WIDTH && envelope?
          width = column_width(3)
          render_columns(top, rows, [voice_panel(width, rows), envelope_panel(width, rows),
                                     history_panel(width, rows)])
        elsif @width >= TWO_COLUMN_WIDTH
          width = column_width(2)
          left = voice_panel(width, rows)
          envelope = envelope_panel(width, rows - left.size - 1)
          left = [*left, line(''), *envelope] if left.size + 1 + envelope.size <= rows
          render_columns(top, rows, [left, history_panel(width, rows)])
        else
          # Narrow: the voice panel yields rows so recent history stays visible.
          history_rows = [rows / 2, @rows.size + 1].min
          voice = voice_panel(@width, rows).first([rows - history_rows - 1, 1].max)
          history = history_panel(@width, rows - voice.size - 1)
          render_block(top, 0, @width, rows, [*voice, *(history.empty? ? [] : [line(''), *history])])
        end
      end

      # -- header and chip lines ------------------------------------------------

      def header(track_title)
        chips = Array(@snapshot&.chips).map(&:name).uniq.join(' + ')
        parts = [track_title, "#{@source} LIVE", chips, format_sample_time(@display_position_sample)]
        parts << "Loop #{@snapshot.loop_count}" if @snapshot&.loop_count.to_i.positive?
        parts << (@paused ? 'PAUSED' : 'PLAYING')
        parts << @snapshot.message if @snapshot&.message
        parts.reject { |part| part.to_s.empty? }.join(' · ')
      end

      def chip_lines
        lines = Array(@snapshot.chips).sort_by { |chip| CHIP_ORDER.fetch(chip.id.split(':').first, 99) }.map do |chip|
          case chip.id.split(':').first
          when 'ym2612' then line(ym2612_summary(chip))
          when 'sn76489' then line(sn76489_summary(chip))
          when 'ym2413' then line(ym2413_summary(chip))
          when 'gb_dmg' then line(gb_summary(chip))
          when 'vrc7' then line(vrc7_summary(chip))
          when '2a03', 'vrc6', 'n163', 's5b', 'fds', 'mmc5' then line(nes_summary(chip))
          else line("#{chip.name} · #{format_clock(chip.clock_hz)} · live detail unavailable", color: :text_muted)
          end
        end
        warnings = @snapshot.warnings.map { |warning| sanitize(warning) }
        lines << line("⚠ #{warnings.join(' · ')}", color: :warning) unless warnings.empty?
        lines
      end

      def ym2612_summary(chip)
        details = chip.details
        lfo = details[:lfo_hz] ? "LFO #{details[:lfo_hz]} Hz" : 'LFO off'
        ch3 = details[:channel_3_special_mode] ? 'CH3 special' : 'CH3 normal'
        dac = if details[:dac_enabled]
                rate = @dac_rates[chip.id]
                "DAC on #{format('$%02X', details[:dac_value].to_i)}#{" ~#{format_hz(rate)}" if rate&.positive?}"
              else
                'DAC off'
              end
        running = Array(details[:timers_running])
        timers = [['A', details[:timer_a_hz], running[0]], ['B', details[:timer_b_hz], running[1]]].map do |name, hz, on|
          "Timer #{name} #{hz ? format_hz(hz) : '--'}#{' ▶' if on && hz}"
        end
        parts = [chip.name, format_clock(chip.clock_hz), lfo, ch3, dac, *timers]
        parts << 'CSM' if details[:csm_enabled]
        parts.join(' · ')
      end

      def sn76489_summary(chip)
        details = chip.details
        noise = chip.channels.find { |channel| channel.kind == :noise }&.details || {}
        rate = noise[:tone_3_coupled] ? 'tone 3' : "÷#{noise[:noise_rate].to_s.delete_prefix('clock_')}"
        parts = [chip.name, format_clock(chip.clock_hz), "noise #{noise[:noise_type] || '--'} #{rate}"]
        if details[:shift_width] || details[:noise_feedback]
          parts << "LFSR #{details[:shift_width] || '--'}-bit fb #{format('$%04X', details[:noise_feedback].to_i)}"
        end
        parts << "stereo #{format('$%02X', details[:stereo_register])}" if details[:stereo_register]
        parts.join(' · ')
      end

      def ym2413_summary(chip)
        details = chip.details
        parts = [chip.name, format_clock(chip.clock_hz)]
        if details[:rhythm_mode]
          keys = details[:rhythm_register].to_i
          drums = { 4 => :bass_drum, 3 => :snare, 2 => :tom, 1 => :cymbal, 0 => :hi_hat }.map do |bit, role|
            keys.anybits?(1 << bit) ? DRUM_ABBREVIATIONS.fetch(role) : DRUM_ABBREVIATIONS.fetch(role).downcase
          end
          parts << "rhythm #{drums.join(' ')}"
        else
          parts << 'melodic (9 channels)'
        end
        parts.join(' · ')
      end

      # -- channel table --------------------------------------------------------

      def wide_table? = @width >= WIDE_TABLE_WIDTH

      def bar_width
        (@width - (wide_table? ? WIDE_FIXED_COLUMNS : NARROW_FIXED_COLUMNS)).clamp(4, 32)
      end

      # The bar stops growing at 32 cells; the instrument column takes the
      # rest so wide screens can spell its terms out.
      def instrument_width
        (INSTRUMENT_WIDTH + @width - WIDE_FIXED_COLUMNS - bar_width).clamp(INSTRUMENT_WIDTH, MAX_INSTRUMENT_WIDTH)
      end

      def table_heading
        if wide_table?
          format('%-1s %-14s %-4s %-7s %8s %-*s %-3s %-*s %s', 'K', 'Channel', 'Keys', 'Note', 'Hz', bar_width,
                 level_heading, 'Pan', instrument_width, 'Instrument', 'State')
        else
          format('%-1s %-14s %-7s %-*s %s', 'K', 'Channel', 'Note', bar_width, 'Level', 'State')
        end
      end

      # Register replay estimates FM and PSG levels (and VRC7's); Game Boy and
      # NES levels are read from the emulator.
      def level_heading
        @rows.all? { |row| gb_kind?(row.channel) || nes_kind?(row.channel) } ? 'Level' : 'Level (est.)'
      end

      def render_channel_rows(first_row, rows)
        @visible_rows = [rows, 0].max
        adjust_scroll
        @rows[@scroll, @visible_rows].to_a.each_with_index do |row, offset|
          index = @scroll + offset
          selected = index == @selected_index
          muted = muted?(row)
          level = level_fraction(row)
          put(first_row + offset, channel_line(row, muted, level),
              fg: selected ? @theme[:selection_text] : row_color(muted, level),
              bg: selected ? @theme[:selection_bg] : nil,
              bold: selected || recent?(row.channel), dim: muted)
        end
      end

      def adjust_scroll
        return @scroll = 0 if @visible_rows >= @rows.size

        @scroll = @selected_index if @selected_index < @scroll
        @scroll = @selected_index - @visible_rows + 1 if @selected_index >= @scroll + @visible_rows
        @scroll = @scroll.clamp(0, @rows.size - @visible_rows)
      end

      def channel_line(row, muted, level)
        channel = row.channel
        bar = level_bar(level, 1_000, bar_width)
        state = "#{STATE_LABELS.fetch(channel.state, channel.state.to_s)}#{' M' if muted}"
        unless wide_table?
          return format('%-1s %-14s %-7s %s %s', row.key, channel.label[0, 14], note_text(channel), bar, state)
        end

        width = instrument_width
        format('%-1s %-14s %-4s %-7s %8s %s %-3s %-*s %s', row.key, channel.label[0, 14], key_dots(channel),
               note_text(channel), channel.pitch_hz ? format('%.1f', channel.pitch_hz) : '--', bar,
               PAN_LABELS.fetch(channel.pan, '--'), width, instrument_text(row, width)[0, width], state)
      end

      # Note and cents, or '--' for unpitched channels and frequencies below
      # the MIDI range (registers left at small values after a note).
      def note_text(channel)
        return 'special' if channel.note == :special

        midi = channel.pitch_hz && Vgm::Pitch.midi(channel.pitch_hz)
        return channel.kind == :pcm ? 'PCM' : '--' unless midi

        cents = channel.details[:pitch_cents].to_i
        cents.zero? ? Vgm::Pitch.note_name(midi) : format('%s %+d', Vgm::Pitch.note_name(midi), cents)
      end

      # One dot per YM2612 operator key; a single dot elsewhere.
      def key_dots(channel)
        mask = channel.details[:key_mask]
        return Array.new(4) { |bit| mask[bit] == 1 ? '●' : '·' }.join if mask && channel.kind == :fm

        ACTIVE_STATES.include?(channel.state) ? '●' : '·'
      end

      # The longest wording that fits `width`.
      def instrument_text(row, width)
        fit(width, *instrument_texts(row))
      end

      # Instrument wordings, longest first.
      def instrument_texts(row)
        channel = row.channel
        details = channel.details
        return gb_instrument_texts(channel) if gb_kind?(channel)
        return nes_instrument_texts(channel) if nes_kind?(channel)

        case channel.kind
        when :fm then fm_instrument_texts(channel.patch)
        when :pcm
          value = format('$%02X', details[:dac_value].to_i)
          ["PCM sample #{value}", "PCM #{value}"]
        when :noise
          ["#{details[:noise_type]} noise · att #{details[:attenuation]} (#{psg_db(details[:attenuation])})",
           "#{details[:noise_type]} att #{details[:attenuation]}"]
        when :percussion then ['rhythm (OPLL drums)', 'rhythm']
        else
          if details.key?(:period)
            ["square · att #{details[:attenuation] || '--'} (#{psg_db(details[:attenuation])})",
             "square att #{details[:attenuation] || '--'}"]
          elsif details[:program_name]
            ["#{details[:program_name]} · vol #{details[:volume]} (#{opll_volume_db(details[:volume])})",
             "#{details[:program_name]} v#{details[:volume]}"]
          else
            ['--']
          end
        end
      end

      def fm_instrument_texts(patch)
        algorithm = patch&.algorithm
        feedback = patch&.feedback
        digest = patch&.short_digest.to_s[0, 6]
        short = "ALG #{algorithm || '-'} FB #{feedback || '-'} #{digest}"
        return [short] unless algorithm && feedback

        alg = "ALG #{algorithm} (#{ALGORITHM_NAMES.fetch(algorithm)})"
        fb = "FB #{feedback} (#{FEEDBACK_NAMES.fetch(feedback)})"
        ["#{alg} · #{fb} · patch #{digest}", "#{alg} · #{fb}", "#{alg} FB #{feedback} #{digest}", short]
      end

      # SN76489 attenuation is 2 dB per step; 15 is silent.
      def psg_db(attenuation)
        return '--' unless attenuation

        attenuation.to_i >= 15 ? 'silent' : "-#{attenuation.to_i * 2} dB"
      end

      # YM2413 volume is 3 dB per step.
      def opll_volume_db(volume) = volume.to_i.zero? ? '0 dB' : "-#{volume.to_i * 3} dB"

      def fit(width, *candidates) = candidates.find { |text| text.length <= width } || candidates.last

      def row_color(muted, level)
        return @theme[:text_muted] if muted || level.zero?

        @theme[:text]
      end

      def recent?(channel)
        trigger = channel.last_trigger_sample
        trigger && @playback_sample >= trigger && @playback_sample - trigger <= RECENT_TRIGGER_SAMPLES
      end

      # -- levels -----------------------------------------------------------------

      # 0..1000 of the bar, from the estimated attenuation.
      def level_fraction(row)
        db = Vgm::Envelope.to_db(attenuation(row))
        ((1 - (-db / LEVEL_FLOOR_DB)).clamp(0.0, 1.0) * 1_000).round
      end

      def attenuation(row)
        channel = row.channel
        case channel.kind
        when :fm then fm_attenuation(row)
        when :pcm then pcm_attenuation(channel)
        when :tone, :noise then tone_attenuation(row, *key_timing(channel))
        when *GB_KINDS then gb_attenuation(channel)
        when *NES_KINDS then nes_attenuation(channel)
        when :percussion
          held, released = key_timing(channel)
          held ? Vgm::Envelope.opll_rom(volume: 0, released: released) : Vgm::Envelope::MAX_ATTENUATION
        else Vgm::Envelope::MAX_ATTENUATION
        end
      end

      # Seconds since key-on, and since key-off when released; nil before
      # the first key-on.
      def key_timing(channel)
        timing(channel.last_trigger_sample, channel.details[:release_sample], ACTIVE_STATES.include?(channel.state))
      end

      # key_timing for one YM2612 operator (index 1..4), which keys on and
      # off independently of the others.
      def operator_timing(channel, index)
        details = channel.details
        timing(details[:operator_triggers]&.at(index - 1), details[:operator_releases]&.at(index - 1),
               details[:key_mask].to_i[index - 1] == 1)
      end

      def timing(on, off, keyed)
        return [nil, nil] unless on && @playback_sample >= on

        return [(@playback_sample - on).fdiv(Vgm::SAMPLE_RATE), nil] if keyed || off.nil? || off < on

        [(off - on).fdiv(Vgm::SAMPLE_RATE), [@playback_sample - off, 0].max.fdiv(Vgm::SAMPLE_RATE)]
      end

      def fm_attenuation(row)
        channel = row.channel
        Vgm::Envelope.opn_channel(channel.patch, keycode: fm_keycode(channel), clock_hz: row.chip.clock_hz.to_f,
                                                 timings: Array.new(4) { |index| operator_timing(channel, index + 1) })
      end

      def fm_keycode(channel)
        frequency = channel.details[:frequency]
        frequency ? Vgm::Envelope.opn_keycode(fnum: frequency[:fnum], block: frequency[:block]) : 0
      end

      def pcm_attenuation(channel)
        details = channel.details
        return Vgm::Envelope::MAX_ATTENUATION unless channel.state == :data && details[:dac_value]

        amplitude = (details[:dac_value] - 0x80).abs / 128.0
        return Vgm::Envelope::MAX_ATTENUATION if amplitude.zero?

        (-20 * Math.log10(amplitude) / Vgm::Envelope::DB_PER_STEP).round
      end

      def tone_attenuation(row, held, released)
        channel = row.channel
        details = channel.details
        return Vgm::Envelope.psg(channel.state == :enabled ? details[:attenuation] : 15) if details.key?(:attenuation)
        return Vgm::Envelope::MAX_ATTENUATION unless held

        carrier = channel.patch&.operators&.find { |operator| operator.index == 2 }
        if carrier
          Vgm::Envelope.opll_custom(carrier.parameters, block: details[:block].to_i, clock_hz: row.chip.clock_hz.to_f,
                                                        volume: details[:volume], held: held, released: released,
                                                        sustain_flag: details[:sustain] || false)
        else
          Vgm::Envelope.opll_rom(volume: details[:volume], released: released)
        end
      end

      # -- keyboard ---------------------------------------------------------------

      def render_keyboard(top)
        key_width = (@width / KEYBOARD_KEYS).clamp(1, 2)
        keys = [@width / key_width, KEYBOARD_KEYS].min
        low = keyboard_low(keys)
        sounding = sounding_notes
        signature = sounding.transform_values { |rows| rows.map(&:key) }
        labels, *key_rows = cached(:keyboard, [low, keys, key_width, signature, @mute_mask]) do
          [keyboard_labels(low, keys, key_width),
           *[true, false].map do |black_row|
             cell_runs(Array.new(keys) { |offset| key_cell(low + offset, black_row, sounding) }
                         .flat_map { |cell| Array.new(key_width, cell) })
           end]
        end
        put(top, labels, fg: @theme[:text_muted])
        key_rows.each_with_index { |runs, index| put_runs(top + 1 + index, runs) }
      end

      def keyboard_labels(low, keys, key_width)
        labels = Array.new(keys * key_width, ' ')
        (0...keys).each do |offset|
          midi = low + offset
          next unless (midi % 12).zero?

          Vgm::Pitch.note_name(midi).each_char.with_index { |char, index| labels[(offset * key_width) + index] = char }
        end
        labels.join[0, @width]
      end

      # Lowest MIDI note shown: the full range when it fits, else whole
      # octaves centred on what is sounding.
      def keyboard_low(keys)
        return KEYBOARD_LOW if keys >= KEYBOARD_KEYS

        notes = sounding_notes.keys
        center = notes.empty? ? 60 : (notes.min + notes.max) / 2
        low = ((center - (keys / 2)) / 12) * 12
        low.clamp(0, [127 - keys + 1, 0].max)
      end

      def key_cell(midi, black_row, sounding)
        black = BLACK_KEYS.include?(midi % 12)
        rows = sounding[midi]
        if rows && black == black_row
          glyph = rows.size > 1 ? '+' : rows.first.key
          return [glyph, rows.all? { |row| muted?(row) } ? :text_muted : :accent, true]
        end
        return [black ? '▆' : ' ', :text_muted, false] if black_row
        return [' ', :text, false] if black

        ['▀', :text, false]
      end

      # MIDI note => rows sounding it.
      def sounding_notes
        @rows.each_with_object({}) do |row, notes|
          channel = row.channel
          next unless ACTIVE_STATES.include?(channel.state) && channel.pitch_hz

          midi = Vgm::Pitch.midi(channel.pitch_hz)
          (notes[midi] ||= []) << row if midi
        end
      end

      # Cells are [char, color, bold]; runs of one style become one put.
      def cell_runs(cells)
        cells.chunk_while { |left, right| left[1, 2] == right[1, 2] }.map do |run|
          [run.map(&:first).join, run.first[1], run.first[2]]
        end
      end

      def put_runs(row, runs)
        column = 0
        runs.each do |text, color, bold|
          put(row, text, column: column, fg: @theme[color], bold: bold)
          column += text.length
        end
      end

      # -- voice panel ------------------------------------------------------------

      def voice_panel(width, _rows)
        row = @rows[@selected_index]
        return [] unless row

        channel = row.channel
        lines = case channel.kind
                when *GB_KINDS then gb_voice_lines(row, width)
                when *NES_KINDS then nes_voice_lines(row, width)
                when :fm then fm_voice_lines(row, width)
                when :pcm then pcm_voice_lines(row)
                when :noise then noise_voice_lines(row, width)
                when :percussion then percussion_voice_lines(row)
                else channel.details.key?(:period) ? square_voice_lines(row, width) : opll_voice_lines(row, width)
                end
        lines << line('Muted', color: :warning) if muted?(row)
        lines
      end

      def fm_voice_lines(row, width)
        channel = row.channel
        details = channel.details
        patch = channel.patch
        # LFO depths go on the pitch line when they fit, else on the title.
        pitch = pitch_line(channel)
        lfo = lfo_texts(details)
        pitch_text = fit(width, *lfo.map { |text| "#{pitch} · #{text}" }, pitch)
        suffix = pitch_text == pitch ? " · #{lfo.last}" : ''
        lines = [title(fit(width, *fm_voice_titles(channel.label, patch).map { |text| text + suffix }))]
        lines.concat(ALGORITHMS.fetch(patch.algorithm).map { |text| line(text, color: :primary) }) if patch&.algorithm
        lines << line(pitch_text)
        Array(details[:special_frequencies]).each do |slot|
          lines << line(format('OP%d %s', slot[:operator], slot[:pitch_hz] ? format_hz(slot[:pitch_hz]) : '--'),
                        color: :text_muted)
        end
        lines.concat(operator_table(row, patch, FM_OPERATOR_FIELDS, width)) if patch
      end

      def fm_voice_titles(label, patch)
        algorithm = patch&.algorithm
        feedback = patch&.feedback
        short = "#{label} · ALG #{algorithm || '-'} · FB #{feedback || '-'}"
        return [short] unless algorithm && feedback

        ["#{label} · ALG #{algorithm} (#{ALGORITHM_NAMES.fetch(algorithm)}) · FB #{feedback} " \
         "(#{FEEDBACK_NAMES.fetch(feedback)})", short]
      end

      # LFO sensitivities: tremolo (AMS) and vibrato (FMS) depth.
      def lfo_texts(details)
        ams = details[:ams]
        fms = details[:fms]
        short = "AMS #{ams || '-'} FMS #{fms || '-'}"
        return [short] unless ams && fms

        ["AMS #{ams} (#{AMS_NAMES.fetch(ams)}) · FMS #{fms} (#{FMS_NAMES.fetch(fms)})", short]
      end

      def pitch_line(channel)
        frequency = channel.details[:frequency]
        fields = []
        fields << "FNUM #{frequency[:fnum]} block #{frequency[:block]}" if frequency
        fields << format_hz(channel.pitch_hz) if channel.pitch_hz
        fields << note_text(channel)
        fields << "pan #{PAN_LABELS.fetch(channel.pan, '--').strip}"
        fields.join(' · ')
      end

      # Operator parameters plus each operator's estimated level; carriers
      # (the operators heard directly) are marked with *.
      # Trailing (less used) fields give way so the level column fits.
      def operator_table(row, patch, fields, width)
        carriers = carriers_for(row, patch)
        fields = fields.first(((width - OPERATOR_LABEL_WIDTH - MIN_OPERATOR_LEVEL - 1) / 4).clamp(5, fields.size))
        heading = "OP #{fields.map { |label, _key| label.rjust(4) }.join}"
        level_width = (width - heading.length - 1).clamp(0, 16)
        lines = [line("#{heading} #{'Level' if level_width >= 5}", color: :text_muted)]
        patch.operators.each do |operator|
          values = fields.map { |_label, key| format_value(operator.parameters[key.to_sym]).rjust(4) }
          carrier = carriers.include?(operator.index)
          text = format('%-3s', "#{operator.index}#{'*' if carrier}") + values.join
          text = "#{text} #{level_bar(operator_level(row, operator), 1_000, level_width)}" if level_width.positive?
          lines << line(text, color: carrier ? :text : :text_muted, bold: carrier)
        end
        lines
      end

      def carriers_for(row, patch)
        return [2] if opll_chip?(row.chip)

        patch.algorithm ? Vgm::Envelope::CARRIERS.fetch(patch.algorithm) : []
      end

      def operator_level(row, operator)
        opll = opll_chip?(row.chip)
        held, released = opll ? key_timing(row.channel) : operator_timing(row.channel, operator.index)
        return 0 unless held

        attenuation = if opll
                        details = row.channel.details
                        Vgm::Envelope.opll_custom(operator.parameters, block: details[:block].to_i,
                                                                       clock_hz: row.chip.clock_hz.to_f, volume: 0,
                                                                       held: held, released: released)
                      else
                        Vgm::Envelope.opn_operator(operator.parameters, keycode: fm_keycode(row.channel),
                                                                        clock_hz: row.chip.clock_hz.to_f,
                                                                        held: held, released: released)
                      end
        db = Vgm::Envelope.to_db(attenuation)
        ((1 - (-db / LEVEL_FLOOR_DB)).clamp(0.0, 1.0) * 1_000).round
      end

      def pcm_voice_lines(row)
        channel = row.channel
        details = channel.details
        rate = @dac_rates[row.chip.id]
        value = details[:dac_value]
        [title("#{channel.label} · PCM (DAC)"),
         line("Last byte #{value ? format('$%02X (%+d)', value, value - 0x80) : '--'} · " \
              "#{rate&.positive? ? "stream ~#{format_hz(rate)}" : 'no stream'}"),
         line("#{details[:dac_writes].to_i} writes · last at #{format_sample_time(details[:dac_sample])}"),
         line("Pan #{PAN_LABELS.fetch(channel.pan, '--').strip} · FM 6 is replaced while the DAC is on",
              color: :text_muted)]
      end

      def square_voice_lines(row, width)
        channel = row.channel
        details = channel.details
        period = details[:period]
        [title("#{channel.label} · square wave"),
         line("Period #{period || '--'} · #{channel.pitch_hz ? format_hz(channel.pitch_hz) : '--'} · " \
              "#{note_text(channel)}"),
         line("Attenuation #{details[:attenuation]} (#{-2 * details[:attenuation].to_i} dB) · " \
              "route #{PAN_LABELS.fetch(channel.pan, '--').strip}"),
         line(square_wave(period, width), color: :primary)]
      end

      # A sketch, not to scale: longer periods draw wider cycles.
      def square_wave(period, width)
        half = ((period || 0) / 64).clamp(1, [width / 8, 1].max)
        (('▔' * half) + ('▁' * half)).*((width / (2 * half)) + 1)[0, width]
      end

      def noise_voice_lines(row, width)
        channel = row.channel
        details = channel.details
        rate = details[:tone_3_coupled] ? 'tone 3 period' : "clock ÷#{details[:noise_rate].to_s.delete_prefix('clock_')}"
        [title("#{channel.label} · #{details[:noise_type]} noise"),
         line("Rate #{rate} · attenuation #{details[:attenuation]} (#{-2 * details[:attenuation].to_i} dB)"),
         line("Route #{PAN_LABELS.fetch(channel.pan, '--').strip}"),
         line(noise_wave(details[:noise_type], width), color: :primary)]
      end

      def noise_wave(type, width)
        return "▔#{'▁' * 7}".*((width / 8) + 1)[0, width] if type == :periodic

        # A fixed pseudo-random pattern (15-bit LFSR, taps 0 and 1).
        state = 0x4001
        Array.new(width) do
          bit = (state ^ (state >> 1)) & 1
          state = (state >> 1) | (bit << 14)
          bit.zero? ? '▁' : '▔'
        end.join
      end

      def opll_voice_lines(row, width)
        channel = row.channel
        details = channel.details
        name = details[:program_name] || 'program --'
        program = details[:program_number] == :custom ? 'custom patch' : "ROM #{details[:program_number]}"
        lines = [title("#{channel.label} · #{name} (#{program})"),
                 line("Volume #{details[:volume] || '--'} (#{-3 * details[:volume].to_i} dB) · " \
                      "sustain #{details[:sustain] ? 'on' : 'off'} · key #{details[:key_on] ? 'on' : 'off'}"),
                 line("FNUM #{details[:fnum] || '--'} block #{details[:block] || '--'} · " \
                      "#{channel.pitch_hz ? format_hz(channel.pitch_hz) : '--'} · #{note_text(channel)}")]
        patch = channel.patch
        if patch && !patch.operators.empty?
          lines << line('1→2→▶  (modulator → carrier)', color: :primary)
          lines.concat(operator_table(row, patch, OPLL_OPERATOR_FIELDS, width))
        end
        lines
      end

      def percussion_voice_lines(row)
        channel = row.channel
        roles = Array(channel.details[:roles]).map { |role| role.to_s.tr('_', ' ') }
        [title("#{channel.label} · rhythm"),
         line("Keyed: #{roles.empty? ? 'none' : roles.join(', ')}"),
         line(format('Rhythm register $%02X', 0x20 | channel.details[:percussion_keys].to_i), color: :text_muted)]
      end

      # -- envelope panel ---------------------------------------------------------

      # Whether the selected channel has envelopes (or, for the Game Boy wave
      # channel, a waveform) to draw. Without them a wide layout gives the
      # envelope column to the history.
      def envelope?
        row = @rows[@selected_index]
        return true if row && gb_kind?(row.channel)
        return nes_detail?(row.channel) if row && nes_kind?(row.channel)

        patch = row&.channel&.patch
        !!(patch && !patch.operators.empty? && %i[fm tone].include?(row.channel.kind))
      end

      def envelope_panel(width, rows)
        row = @rows[@selected_index]
        return [] unless row && rows >= 4
        return gb_envelope_panel(row, width, rows) if gb_kind?(row.channel)
        return nes_detail_panel(row, width, rows) if nes_kind?(row.channel)

        patch = row.channel.patch
        heading = title('Envelopes (estimated)')
        return [heading, line(no_envelope_reason(row), color: :text_muted)] unless envelope?

        operators = patch.operators
        graph_rows = (((rows - 2) / operators.size) - 1).clamp(1, 4)
        # Keyed on the patch, not the channel: switching between channels
        # that share an instrument reuses the graphs.
        body = cached(:envelope, [row.chip.id, patch.digest, envelope_keycode(row), width, graph_rows]) do
          operators.flat_map do |operator|
            [line(envelope_label(operator), color: :text_muted), *envelope_graph(row, operator, width, graph_rows)]
          end
        end
        lines = [heading, *body]
        hold = (width * 3) / 4
        lines << line("key on #{'─' * [hold - 15, 0].max} 2 s│off #{'─' * [width - hold - 10, 0].max} 1 s",
                      color: :text_muted)
      end

      def no_envelope_reason(row)
        return 'ROM instrument: envelope rates are not readable' if row.channel.details[:program_name]

        case row.channel.kind
        when :pcm then 'PCM stream: no envelope generator'
        when :tone, :noise then 'No envelope generator: the level is the attenuation register'
        when :percussion then 'Rhythm instruments use fixed ROM envelopes'
        else 'ROM instrument: envelope rates are not readable'
        end
      end

      def envelope_label(operator)
        parameters = operator.parameters
        fields = parameters.key?(:d1r) ? %i[ar d1r d1l d2r rr] : %i[ar dr sl rr]
        "OP#{operator.index} " + fields.map { |key| "#{key.to_s.upcase} #{format_value(parameters[key])}" }.join(' ')
      end

      def envelope_keycode(row)
        frequency = row.channel.details[:frequency]
        return Vgm::Envelope.opn_keycode(**frequency.slice(:fnum, :block)) if frequency

        row.channel.details[:block].to_i
      end

      # The operator's EG shape (without its total level) over the log time
      # axes, as a graph `rows` tall.
      def envelope_graph(row, operator, width, rows)
        hold_columns = [(width * 3) / 4, 2].max
        release_columns = [width - hold_columns, 2].max
        held = log_axis(*HOLD_AXIS, hold_columns)
        released = log_axis(*RELEASE_AXIS, release_columns)
        values = held.map { |time| envelope_value(row, operator, time, nil) } +
                 released.map { |time| envelope_value(row, operator, HOLD_AXIS.last, time) }
        graph(values, 1_000, rows)
      end

      def envelope_value(row, operator, held, released)
        parameters = operator.parameters.merge(tl: 0, total_level: 0)
        clock = row.chip.clock_hz.to_f
        attenuation = if parameters.key?(:d1r)
                        Vgm::Envelope.opn_operator(parameters, keycode: envelope_keycode(row), clock_hz: clock,
                                                               held: held, released: released)
                      else
                        Vgm::Envelope.opll_custom(parameters, block: envelope_keycode(row), clock_hz: clock, volume: 0,
                                                              held: held, released: released)
                      end
        ((1 - (attenuation / Vgm::Envelope::MAX_ATTENUATION.to_f)) * 1_000).round
      end

      def log_axis(first, last, count)
        ratio = last / first
        Array.new(count) { |index| first * (ratio**index.fdiv(count - 1)) }
      end

      # -- history panel ------------------------------------------------------------

      # Most snapshots carry the same events as the last one; decoding and
      # redrawing lanes only when they change keeps the page cheap.
      def decode_history(snapshot)
        snapshot.chips.each do |chip|
          packed = chip.details[:events]
          next if packed.nil? || packed == @history_packed[chip.id]

          @history_packed[chip.id] = packed
          @history[chip.id] = Vgm::NoteLog.decode(packed).group_by(&:channel)
          @history_version += 1
        end
      end

      def history_panel(width, rows)
        return [] if rows < 2

        lane_width = [width - 2, 1].max
        seconds = (lane_width * HISTORY_COLUMN_SAMPLES).fdiv(Vgm::SAMPLE_RATE)
        lanes = [rows - 1, @rows.size].min
        first = (@selected_index - (lanes / 2)).clamp(0, [@rows.size - lanes, 0].max)
        bucket = @playback_sample / HISTORY_COLUMN_SAMPLES
        # Channel states feed open DAC bursts, so they are part of the key.
        states = @rows[first, lanes].map { |row| row.channel.state }
        body = cached(:history, [bucket, @history_version, states, lane_width, first, lanes, @mute_mask]) do
          @rows[first, lanes].map { |row| { segments: [["#{row.key} ", :text_muted, false], *lane(row, lane_width, bucket)] } }
        end
        [title(format('History · last %.0f s', seconds)), *body]
      end

      # Segments for one channel's lane: note starts, held notes drawn at
      # their height within the lane's pitch range, gaps blank.
      def lane(row, width, bucket)
        events = @history.dig(row.chip.id, row.voice) || []
        first_bucket = bucket - width + 1
        cells = lane_cells(events, row, first_bucket, width)
        pitched = cells.filter_map { |cell| cell&.last }
        low, high = pitched.minmax
        muted = muted?(row)
        styled = cells.map do |cell|
          next [' ', :text, false] unless cell

          started, midi = cell
          glyph = if midi.nil?
                    started ? '┃' : '━'
                  else
                    LEVEL_GLYPHS[high == low ? 4 : 1 + ((midi - low) * 7 / (high - low))]
                  end
          color = if muted then :text_muted
                  elsif started then :accent
                  else :primary
                  end
          [glyph, color, started]
        end
        cell_runs(styled)
      end

      # Per column: nil (silent) or [started_in_column, midi].
      def lane_cells(events, row, first_bucket, width)
        events = close_open_dac_burst(events, row)
        on = false
        midi = nil
        index = 0
        Array.new(width) do |column|
          bucket_end = (first_bucket + column + 1) * HISTORY_COLUMN_SAMPLES
          started = false
          sounded = on
          while index < events.size && events[index].sample < bucket_end
            event = events[index]
            index += 1
            case event.kind
            when :on
              on = true
              started = true if event.sample >= bucket_end - HISTORY_COLUMN_SAMPLES
              midi = event.midi
            when :note then midi = event.midi
            when :off then on = false
            end
            sounded ||= on
          end
          sounded || started ? [started, midi] : nil
        end
      end

      # A DAC burst's end is logged when the next burst starts; until then,
      # the stream ends at its last write once the channel has gone idle.
      def close_open_dac_burst(events, row)
        channel = row.channel
        return events unless channel.kind == :pcm && channel.state != :data && events.last&.kind == :on

        events + [Vgm::NoteLog::Event.new(channel: row.voice, kind: :off, midi: nil,
                                          sample: channel.details[:dac_sample].to_i + 1)]
      end

      def track_dac_rates(snapshot)
        snapshot.chips.each do |chip|
          writes = chip.details[:dac_writes]
          next unless writes

          previous_writes, previous_sample = @dac_previous[chip.id]
          @dac_previous[chip.id] = [writes, snapshot.sample]
          next unless previous_sample && snapshot.sample > previous_sample && writes >= previous_writes

          rate = (writes - previous_writes) * Vgm::SAMPLE_RATE.to_f / (snapshot.sample - previous_sample)
          smoothed = @dac_rates[chip.id]
          @dac_rates[chip.id] = smoothed ? (smoothed * 0.6) + (rate * 0.4) : rate
        end
      end

      # -- muting ---------------------------------------------------------------------

      # libgme's VGM voices: FM 1-6 and PCM (the DAC); then the PSG as one voice when
      # an FM chip is present, else one per PSG channel. OPLL channels 6-9
      # share a voice, and so do its rhythm instruments. GBS: one per channel.
      # NSF: one per channel, numbered across chips.
      def mute_bits(row)
        # NSF channels carry their libgme voice.
        nsf_voice = row.channel.details[:voice]
        return 1 << nsf_voice if nsf_voice

        voice = row.voice
        case row.chip.id.split(':').first
        # The DAC row covers FM 6 too: the DAC replaces it while enabled.
        when 'ym2612' then row.channel.kind == :pcm ? (1 << 6) | (1 << 5) : 1 << voice
        when 'sn76489' then 1 << (fm_chip? ? 7 : voice)
        when 'ym2413'
          return 1 << 6 if row.channel.kind == :percussion

          1 << [voice, 5].min
        when 'gb_dmg' then 1 << voice
        else 0
        end
      end

      def fm_chip? = @rows.any? { |row| row.chip.id.start_with?('ym2612', 'ym2413') }

      # The YM2413 and its VRC7 variant share the OPLL model.
      def opll_chip?(chip) = chip.id.start_with?('ym2413', 'vrc7')

      def muted?(row)
        bits = mute_bits(row)
        bits.positive? && @mute_mask.allbits?(bits)
      end

      # -- helpers -----------------------------------------------------------------------

      def render_empty
        messages = [@snapshot.message, *@snapshot.warnings,
                    *@snapshot.chips.filter_map { |chip| chip.details[:message] }].compact.map { |text| sanitize(text) }
        messages = [status_message(@snapshot.status)] if messages.empty?
        messages.uniq.first([@height - 1, 0].max).each_with_index do |message, index|
          put(1 + index, message,
              fg: %i[error unsupported].include?(@snapshot.status) ? @theme[:warning] : @theme[:text_muted])
        end
      end

      def status_message(status)
        {
          loading: @source == 'VGM' ? 'Waiting for VGM telemetry' : "Waiting for #{@source} state",
          ready: 'No channel state available',
          partial: 'Partial register information', unsupported: 'Live detail unsupported',
          error: 'Unable to read VGM telemetry', ended: 'VGM playback ended'
        }.fetch(status, 'No live channel data')
      end

      def format_value(value) = value.nil? ? '--' : value.to_s
      def pan_label(channel) = PAN_LABELS.fetch(channel.pan, '--').strip
      def format_clock(frequency) = frequency ? format('%.2f MHz', frequency / 1_000_000.0) : '-- MHz'

      def format_hz(frequency)
        frequency >= 1000 ? format('%.1f kHz', frequency / 1000.0) : format('%.1f Hz', frequency)
      end

      # A position in 44.1 kHz samples, as m:ss.
      def format_sample_time(sample) = DurationFormatter.format(sample.to_i * 1000 / Vgm::SAMPLE_RATE)

      def title(text) = { text: text, color: :accent, bold: true }
      def line(text, color: :text, bold: false) = { text: text, color: color, bold: bold }
    end
  end
end
