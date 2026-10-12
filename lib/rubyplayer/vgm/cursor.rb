# frozen_string_literal: true

require_relative 'reader'
require_relative 'chips'

module RubyPlayer
  module Vgm
    # Replays register writes against source samples and bounded state checkpoints.
    class Cursor
      CHECKPOINT_INTERVAL = SAMPLE_RATE # one second of source time
      MAX_COMMANDS_PER_SLICE = 4_096
      # Roughly 0.15 s of Ruby replay. Catching up minutes into a DAC-heavy
      # track takes millions of commands, so each request does a bounded slice
      # and the next request resumes from the same cursor.
      DEFAULT_COMMANDS_PER_CALL = 100_000
      # Guards against streams that never advance time (beyond the zero-time
      # loop check), which a per-call budget alone would not catch.
      MAX_COMMANDS_WITHOUT_PROGRESS = 5_000_000
      DEFAULT_CHECKPOINT_LIMIT = 128
      # VGM opcodes are exact specification identifiers.
      DEFAULT_WAIT_62 = 735
      DEFAULT_WAIT_63 = 882
      # rubocop:disable Naming/VariableNumber
      private_constant :CHECKPOINT_INTERVAL, :MAX_COMMANDS_PER_SLICE,
                       :DEFAULT_COMMANDS_PER_CALL, :MAX_COMMANDS_WITHOUT_PROGRESS,
                       :DEFAULT_WAIT_62, :DEFAULT_WAIT_63
      # rubocop:enable Naming/VariableNumber
      DAC_UNAVAILABLE_WARNING = 'YM2612 DAC data unavailable: PCM bank is missing or compressed'

      class ReplayError < StandardError; end
      class Cancelled < StandardError; end

      attr_reader :commands_processed

      def initialize(reader:, checkpoint_limit: DEFAULT_CHECKPOINT_LIMIT,
                     decoder_capabilities: nil, commands_per_call: DEFAULT_COMMANDS_PER_CALL)
        raise ArgumentError, 'checkpoint_limit must be an Integer of at least 2' unless checkpoint_limit.is_a?(Integer) && checkpoint_limit >= 2
        raise ArgumentError, 'commands_per_call must be a positive Integer' unless commands_per_call.is_a?(Integer) && commands_per_call.positive?

        @commands_per_call = commands_per_call

        @reader = reader
        @chips = ChipRegistry.new(header: reader.header,
                                  decoder_capabilities: decoder_capabilities)
        @checkpoint_limit = checkpoint_limit
        @sample = 0
        @offset = reader.header.data_offset
        @pending_wait = 0
        @loop_count = 0
        @last_loop_end_sample = nil
        @ended = false
        @wait_overrides = { 0x62 => DEFAULT_WAIT_62, 0x63 => DEFAULT_WAIT_63 }
        @pcm_banks = Hash.new { |hash, key| hash[key] = [] }
        @seen_blocks = Set.new
        @pcm_pointer = 0
        @warnings = Set.new
        @next_checkpoint_sample = CHECKPOINT_INTERVAL
        @checkpoint_due = false
        @checkpoints = []
        @commands_processed = 0
        save_checkpoint
      end

      # Returns a snapshot at the target, or earlier when the per-call budget
      # runs out; callers repeat the request to keep catching up.
      def advance_to(sample:, cancel: -> { false })
        raise ArgumentError, 'sample must be a nonnegative Integer' unless sample.is_a?(Integer) && sample >= 0

        restore_nearest_checkpoint(sample) if sample < @sample
        processed_for_call = 0
        processed_in_slice = 0
        processed_without_progress = 0

        until @ended
          raise Cancelled, 'VGM replay was cancelled' if cancel.call

          if @pending_wait.positive?
            # Stop only between timestamps, so a partial snapshot never shows
            # half of the writes that share one sample.
            break if processed_for_call >= @commands_per_call
            break unless advance_wait(sample)

            processed_without_progress = 0
            next
          end
          break if @sample > sample

          command = @reader.command_at(@offset)
          @commands_processed += 1
          processed_for_call += 1
          processed_in_slice += 1
          processed_without_progress += 1
          if processed_without_progress > MAX_COMMANDS_WITHOUT_PROGRESS
            raise ReplayError,
                  "VGM replay exceeded #{MAX_COMMANDS_WITHOUT_PROGRESS} commands without advancing time"
          end

          @offset = command.next_offset
          apply(command)
          if processed_in_slice >= MAX_COMMANDS_PER_SLICE
            Thread.pass
            processed_in_slice = 0
          end
        end

        snapshot_content
      end

      def checkpoint_count = @checkpoints.size
      def checkpoint_samples = @checkpoints.map { |checkpoint| checkpoint.fetch(:sample) }.freeze

      def close
        @checkpoints.clear
        @pcm_banks.clear
        @seen_blocks.clear
        @reader = nil
        @chips = nil
        self
      end

      private

      def apply(command)
        case command.kind
        when :wait
          opcode = command.arguments.fetch(:opcode)
          samples = @wait_overrides.fetch(opcode, command.arguments.fetch(:samples))
          @pending_wait += samples
          save_due_checkpoint if @pending_wait.positive?
        when :wait_override
          opcode = command.arguments.fetch(:command)
          if [0x62, 0x63].include?(opcode)
            @wait_overrides[opcode] = command.arguments.fetch(:samples)
          else
            add_warning(format('Ignored invalid VGM wait override for 0x%02x', opcode))
          end
        when :register_write, :psg_write, :stereo_write, :skip
          @chips.write(command: command, sample: @sample)
        when :data_block
          remember_data_block(command)
        when :pcm_seek
          @pcm_pointer = command.arguments.fetch(:address)
          add_warning(DAC_UNAVAILABLE_WARNING) if @pcm_pointer > pcm_bank_size
        when :dac_write
          apply_dac_write(command)
        when :pcm_ram_write
          add_warning('PCM RAM writes are skipped; register state may be partial')
        when :stream_command
          add_warning('Modern VGM DAC stream control is not replayed')
        when :end
          finish_or_loop
        end
      end

      # Advancing a wait reports whether source time moved toward the target.
      # rubocop:disable Naming/PredicateMethod
      def advance_wait(target)
        return false if target <= @sample

        event_sample = @sample + @pending_wait
        next_sample = [target, event_sample, @next_checkpoint_sample].min
        delta = next_sample - @sample
        @sample = next_sample
        @pending_wait -= delta

        if @sample == @next_checkpoint_sample
          if @pending_wait.positive?
            save_checkpoint
          else
            @checkpoint_due = true
          end
        end
        delta.positive?
      end
      # rubocop:enable Naming/PredicateMethod

      # Bank 0 may be absent or compressed (type 0x40); only the DAC row is
      # unknowable then, so keep FM/PSG replay and the command's timing.
      def apply_dac_write(command)
        value = pcm_byte_at(@pcm_pointer)
        if value.nil?
          add_warning(DAC_UNAVAILABLE_WARNING)
        else
          @chips.write_dac(instance: 0, value: value, sample: @sample)
        end
        @pcm_pointer += 1
        @pending_wait += command.arguments.fetch(:wait_samples)
        save_due_checkpoint if @pending_wait.positive?
      end

      def finish_or_loop
        loop_offset = @reader.header.loop_offset
        unless loop_offset
          @ended = true
          save_due_checkpoint
          return
        end

        raise ReplayError, "zero-time loop at byte 0x#{loop_offset.to_s(16)}" if @last_loop_end_sample == @sample

        @last_loop_end_sample = @sample
        @loop_count += 1
        @offset = loop_offset
      end

      def remember_data_block(command)
        args = command.arguments
        return if @seen_blocks.include?(command.offset)

        @seen_blocks << command.offset
        return unless args.fetch(:type).zero?

        @pcm_banks[0] << [args.fetch(:data_offset), args.fetch(:size)].freeze
      end

      def pcm_bank_size
        @pcm_banks.fetch(0, []).sum(&:last)
      end

      def pcm_byte_at(pointer)
        return if pointer.negative?

        remaining = pointer
        @pcm_banks.fetch(0, []).each do |offset, size|
          return @reader.bytes.getbyte(offset + remaining) if remaining < size

          remaining -= size
        end
        nil
      end

      def save_due_checkpoint
        return unless @checkpoint_due

        save_checkpoint
        @checkpoint_due = false
      end

      def save_checkpoint
        return unless @reader && @chips

        checkpoint = Immutable.deep_freeze({
                                             sample: @sample,
                                             offset: @offset,
                                             pending_wait: @pending_wait,
                                             loop_count: @loop_count,
                                             last_loop_end_sample: @last_loop_end_sample,
                                             ended: @ended,
                                             wait_overrides: @wait_overrides,
                                             pcm_banks: @pcm_banks.to_h,
                                             seen_blocks: @seen_blocks.to_a,
                                             pcm_pointer: @pcm_pointer,
                                             warnings: @warnings.to_a,
                                             chips: @chips.dump_state
                                           })
        # Kept sorted by sample: backward seeks replay forward and save
        # checkpoints earlier than ones already stored.
        index = @checkpoints.bsearch_index { |item| item[:sample] >= @sample } || @checkpoints.size
        if @checkpoints[index]&.fetch(:sample) == @sample
          @checkpoints[index] = checkpoint
        else
          @checkpoints.insert(index, checkpoint)
        end
        evict_farthest_checkpoint while @checkpoints.size > @checkpoint_limit
        @next_checkpoint_sample = ((@sample / CHECKPOINT_INTERVAL) + 1) * CHECKPOINT_INTERVAL
      end

      # The initial checkpoint is never evicted, so the first entry is a safe
      # fallback for any target.
      def evict_farthest_checkpoint
        farthest = (1...@checkpoints.size).max_by { |index| (@checkpoints[index][:sample] - @sample).abs }
        @checkpoints.delete_at(farthest)
      end

      # Greatest checkpoint at or before the target; the sorted list always
      # starts with the initial state.
      def nearest_checkpoint(target)
        after = @checkpoints.bsearch_index { |item| item[:sample] > target } || @checkpoints.size
        @checkpoints[[after - 1, 0].max]
      end

      def restore_nearest_checkpoint(target)
        checkpoint = nearest_checkpoint(target)
        @sample = checkpoint.fetch(:sample)
        @offset = checkpoint.fetch(:offset)
        @pending_wait = checkpoint.fetch(:pending_wait)
        @loop_count = checkpoint.fetch(:loop_count)
        @last_loop_end_sample = checkpoint.fetch(:last_loop_end_sample)
        @ended = checkpoint.fetch(:ended)
        @wait_overrides = checkpoint.fetch(:wait_overrides).dup
        @pcm_banks = Hash.new { |hash, key| hash[key] = [] }
        checkpoint.fetch(:pcm_banks).each { |type, spans| @pcm_banks[type] = spans.dup }
        @seen_blocks = Set.new(checkpoint.fetch(:seen_blocks))
        @pcm_pointer = checkpoint.fetch(:pcm_pointer)
        @warnings = Set.new(checkpoint.fetch(:warnings))
        @chips.restore_state(checkpoint.fetch(:chips))
        @next_checkpoint_sample = ((@sample / CHECKPOINT_INTERVAL) + 1) * CHECKPOINT_INTERVAL
        @checkpoint_due = false
      end

      def add_warning(message)
        @warnings.add(message)
      end

      def snapshot_content
        chip_result = @chips.snapshot(sample: @sample)
        warnings = (chip_result.fetch(:warnings) + @warnings.to_a).uniq.freeze
        status = if @ended
                   :ended
                 elsif warnings.empty?
                   chip_result.fetch(:status)
                 elsif chip_result.fetch(:status) == :unsupported
                   :unsupported
                 else
                   :partial
                 end
        Snapshot.new(generation: 0, revision: 0, sample: @sample,
                     status: status, message: nil, loop_count: @loop_count,
                     chips: chip_result.fetch(:chips), warnings: warnings)
      end
    end
  end
end
