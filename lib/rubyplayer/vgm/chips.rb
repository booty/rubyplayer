# frozen_string_literal: true

require_relative 'snapshot'
require_relative 'chips/ym2612'
require_relative 'chips/sn76489'
require_relative 'chips/ym2413'

module RubyPlayer
  module Vgm
    # Routes decoded writes to supported chip adapters and records coverage gaps.
    class ChipRegistry
      # Public chip symbols follow the hardware names used by the VGM specification.
      # rubocop:disable Naming/VariableNumber
      CHIP_NAMES = {
        sn76489: 'SN76489', ym2413: 'YM2413', ym2612: 'YM2612',
        ym2151: 'YM2151', sega_pcm: 'Sega PCM', rf5c68: 'RF5C68',
        ym2203: 'YM2203', ym2608: 'YM2608', ym2610: 'YM2610',
        ym3812: 'YM3812', ym3526: 'YM3526', y8950: 'Y8950', ymf262: 'YMF262',
        ymf278b: 'YMF278B', ymf271: 'YMF271', ymz280b: 'YMZ280B',
        rf5c164: 'RF5C164', pwm: 'PWM', ay8910: 'AY8910', gameboy: 'Game Boy APU',
        nes_apu: 'NES APU', multipcm: 'MultiPCM', upd7759: 'uPD7759',
        okim6258: 'OKIM6258', okim6295: 'OKIM6295', k051649: 'K051649',
        k054539: 'K054539', huc6280: 'HuC6280', c140: 'C140', k053260: 'K053260',
        pokey: 'POKEY', qsound: 'QSound', scsp: 'SCSP', wonderswan: 'WonderSwan',
        vsu: 'VSU', saa1099: 'SAA1099', es5503: 'ES5503', es5506: 'ES5506',
        x1_010: 'X1-010', c352: 'C352', ga20: 'GA20'
      }.freeze
      # rubocop:enable Naming/VariableNumber

      def initialize(header:, decoder_capabilities: nil)
        @header = header
        @adapters = {}
        @unsupported = []
        @unsupported_keys = Set.new
        @warnings = []
        @warned = Set.new
        declarations = header.chip_clocks
        @decoder_capabilities = decoder_capabilities || {
          sn76489: true,
          ym2612: true,
          ym2413: !declarations.key?(:ym2612)
        }
        build_adapters(declarations)
      end

      def write(command:, sample:)
        chip_id = command.chip_id
        return warn_for_unmapped(command) if chip_id.nil?

        instance = command.arguments.fetch(:instance, 0)
        adapter = @adapters[[chip_id, instance]]
        unless adapter
          # Declared-but-unsupported chips already carry their own warning.
          warn_once(undeclared_message(chip_id, instance)) unless @unsupported_keys.include?([chip_id, instance])
          return
        end

        write_to_adapter(chip_id, adapter, command, sample)
      end

      def write_to_adapter(chip_id, adapter, command, sample)
        case chip_id
        when :sn76489
          register = command.kind == :stereo_write ? :stereo : :data
          adapter.write(port: command.arguments.fetch(:port, 0), register: register,
                        value: command.arguments.fetch(:value), sample: sample)
        when :ym2612
          if command.kind == :dac_write
            unavailable_dac_warning
          elsif command.kind == :register_write
            adapter.write(port: command.arguments.fetch(:port),
                          register: command.arguments.fetch(:register),
                          value: command.arguments.fetch(:value), sample: sample)
          end
        when :ym2413
          adapter.write(port: 0, register: command.arguments.fetch(:register),
                        value: command.arguments.fetch(:value), sample: sample)
        else
          warn_once("Live detail unavailable: #{CHIP_NAMES.fetch(chip_id, chip_id.to_s)}")
        end
      end
      private :write_to_adapter

      def write_dac(instance:, value:, sample:)
        adapter = @adapters[[:ym2612, instance]]
        return warn_once(undeclared_message(:ym2612, instance)) unless adapter

        adapter.write(port: 0, register: 0x2a, value: value, sample: sample)
      end

      def snapshot(sample:)
        chips = @adapters.sort_by { |(chip, instance), _adapter| [chip.to_s, instance] }
                         .map { |_key, adapter| adapter.snapshot(sample: sample) }
        chips.concat(unsupported_snapshots)
        warnings = @warnings.dup
        status = if chips.empty?
                   :unsupported
                 elsif warnings.empty?
                   :ready
                 else
                   :partial
                 end
        { status: status, chips: chips.freeze, warnings: warnings.freeze }
      end

      def dump_state
        Immutable.deep_freeze({ adapters: @adapters.transform_values(&:dump_state),
                                warnings: @warnings.to_a, warned: @warned.to_a })
      end

      def restore_state(state)
        state.fetch(:adapters).each do |key, checkpoint|
          @adapters.fetch(key).restore_state(checkpoint)
        end
        @warnings = state.fetch(:warnings).dup
        @warned = Set.new(state.fetch(:warned))
        self
      end

      private

      def warn_for_unmapped(command)
        return unless command.kind == :skip

        warn_once("Skipped VGM command 0x#{command.arguments[:opcode].to_s(16)}")
      end

      def build_adapters(declarations)
        declarations.each do |chip, clock|
          instances = clock.fetch(:dual, false) ? 2 : 1
          name = CHIP_NAMES.fetch(chip, chip.to_s)
          if chip == :sn76489 && clock.fetch(:variant_flag, false)
            # The spec marks T6W28 with the variant *and* dual bits, and that
            # pair is one chip. The variant bit alone is unrecognised, so it
            # is neither labelled T6W28 nor modeled as a plain SN76489.
            if clock.fetch(:dual, false)
              unsupported(chip, name: 'T6W28', clock_hz: clock[:clock_hz], instances: 1,
                                message: 'Live detail unavailable: T6W28')
              # Its second half arrives as instance-1 (0x30) writes.
              @unsupported_keys << [chip, 1]
            else
              unsupported(chip, name: name, clock_hz: clock[:clock_hz], instances: 1,
                                message: 'Live detail unavailable: SN76489 with unrecognized variant flag')
            end
            next
          end

          if chip == :ym2413 && declarations.key?(:ym2612)
            unsupported(chip, name: name, clock_hz: clock[:clock_hz], instances: instances,
                              message: 'Live detail unavailable: YM2413 when YM2612 is declared; libgme prioritizes YM2612')
            next
          end

          unless @decoder_capabilities.fetch(chip, false) && %i[sn76489 ym2612 ym2413].include?(chip)
            unsupported(chip, name: name, clock_hz: clock[:clock_hz], instances: instances,
                              message: "Live detail unavailable: #{name}")
            next
          end

          instances.times do |instance|
            @adapters[[chip, instance]] = adapter_for(chip, clock, instance)
          end
        end
        if @header.legacy_fm_clock
          unsupported(:legacy_fm, name: 'Legacy FM',
                                  clock_hz: @header.legacy_fm_clock[:clock_hz], instances: 1,
                                  message: 'Live detail unavailable: ambiguous legacy FM clock')
          # The pre-1.10 clock field covers whichever of these the stream writes.
          %i[ym2413 ym2612 ym2151].each { |chip| @unsupported_keys << [chip, 0] }
        end
        warn_once('VGM header declares no supported chip clocks') if @adapters.empty? && @unsupported.empty?
      end

      def adapter_for(chip, clock, instance)
        case chip
        when :sn76489
          Chips::Sn76489.new(clock_hz: clock[:clock_hz], instance: instance,
                             feedback: @header.sn_feedback,
                             shift_width: @header.sn_shift_width,
                             flags: @header.sn_flags)
        when :ym2612
          Chips::Ym2612.new(clock_hz: clock[:clock_hz], instance: instance,
                            variant: @header.ym2612_variant || :ym2612)
        when :ym2413
          Chips::Ym2413.new(clock_hz: clock[:clock_hz], instance: instance)
        end
      end

      def unsupported(chip, name:, clock_hz:, instances:, message:)
        instances.times do |instance|
          @unsupported << [chip, instance, name, clock_hz, message]
          @unsupported_keys << [chip, instance]
        end
        warn_once(message)
      end

      def unsupported_snapshots
        @unsupported.map do |chip, instance, name, clock_hz, message|
          ChipSnapshot.new(
            id: "#{chip}:#{instance}", name: name, clock_hz: clock_hz,
            channels: [], details: { status: :unsupported, message: message }
          )
        end
      end

      def unavailable_dac_warning
        warn_once('YM2612 DAC sample-bank replay is unavailable for this stream')
      end

      def undeclared_message(chip, instance)
        "Ignored #{CHIP_NAMES.fetch(chip, chip.to_s)} instance #{instance + 1} writes because it is undeclared or not rendered by libgme"
      end

      def warn_once(message)
        @warnings << message if @warned.add?(message)
      end
    end
  end
end
