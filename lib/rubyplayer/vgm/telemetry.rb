# frozen_string_literal: true

require_relative 'snapshot'
require_relative 'reader'
require_relative 'cursor'

module RubyPlayer
  module Vgm
    # Owns the lazy replay worker and publishes coalesced immutable snapshots.
    class Telemetry
      ERROR_MESSAGE_LIMIT = 240
      private_constant :ERROR_MESSAGE_LIMIT

      def initialize(event_bus:, max_bytes:, reader_factory: nil, cursor_factory: nil,
                     stat_factory: nil, logger: nil)
        raise ArgumentError, 'max_bytes must be a positive Integer' unless max_bytes.is_a?(Integer) && max_bytes.positive?

        @event_bus = event_bus
        @max_bytes = max_bytes
        @reader_factory = reader_factory || lambda do |path, max_bytes:, cancel:|
          Reader.open(path, max_bytes: max_bytes, cancel: cancel)
        end
        @cursor_factory = cursor_factory || lambda do |reader, source:|
          Cursor.new(reader: reader, decoder_capabilities: source.decoder_capabilities)
        end
        @stat_factory = stat_factory || ->(path) { File.stat(path) }
        @logger = logger
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @thread = nil
        @pending_request = nil
        @active_request = nil
        @active_epoch = nil
        @epoch = 0
        @suspended = true
        @close_cursor_requested = false
        @shutdown = false
        @notification_pending = false
        @snapshot = nil
        @cursor = nil
        @cursor_source = nil
        @source_signature = nil
        @cached_error_key = nil
        @cached_error_message = nil
        @logged_errors = Set.new
      end

      # This action reports whether the worker accepted the request.
      # rubocop:disable Naming/PredicateMethod
      def request(request)
        validate_request!(request)
        @mutex.synchronize do
          return false if @shutdown

          @suspended = false
          @pending_request = request
          @thread ||= Thread.new { worker_loop }.tap { |thread| thread.name = 'vgm-telemetry' }
          @condition.signal
        end
        true
      end
      # rubocop:enable Naming/PredicateMethod

      def take_snapshot
        @mutex.synchronize do
          snapshot = @snapshot
          @snapshot = nil
          @notification_pending = false
          snapshot
        end
      end

      def suspend
        @mutex.synchronize do
          return if @shutdown

          @suspended = true
          @epoch += 1
          @close_cursor_requested = true
          @pending_request = nil
          @snapshot = nil
          @cached_error_key = nil
          @cached_error_message = nil
          @condition.broadcast
        end
        nil
      end

      # This action reports whether the byte limit changed.
      # rubocop:disable Naming/PredicateMethod
      def reconfigure(max_bytes:)
        raise ArgumentError, 'max_bytes must be a positive Integer' unless max_bytes.is_a?(Integer) && max_bytes.positive?

        @mutex.synchronize do
          return false if @max_bytes == max_bytes || @shutdown

          @max_bytes = max_bytes
          @epoch += 1
          @suspended = true
          @pending_request = nil
          @snapshot = nil
          @close_cursor_requested = true
          @cached_error_key = nil
          @cached_error_message = nil
          @condition.broadcast
        end
        true
      end
      # rubocop:enable Naming/PredicateMethod

      def shutdown
        thread = @mutex.synchronize do
          @shutdown = true
          @suspended = true
          @pending_request = nil
          @condition.broadcast
          @thread
        end
        thread&.join
        @mutex.synchronize { @thread = nil }
        nil
      end

      private

      def validate_request!(request)
        unless request.is_a?(Request) && request.source.is_a?(Source) &&
               request.revision.is_a?(Integer) && request.revision >= 0 &&
               request.sample.is_a?(Integer) && request.sample >= 0
          raise ArgumentError, 'request must contain a VGM source, nonnegative revision, and sample'
        end
      end

      def worker_loop
        loop do
          work = @mutex.synchronize do
            @condition.wait(@mutex) until @shutdown || @close_cursor_requested || @pending_request
            if @shutdown
              :shutdown
            elsif @close_cursor_requested
              @close_cursor_requested = false
              :close
            else
              @active_request = @pending_request
              @active_epoch = @epoch
              @pending_request = nil
              @active_request
            end
          end
          break if work == :shutdown

          if work == :close
            close_cursor
            next
          end

          process(work, @active_epoch)
        end
      ensure
        close_cursor
      end

      def process(request, epoch)
        error_key = [request.source, request.revision]
        if (message = cached_error(error_key))
          publish(result_for(request, status: :error, message: message), epoch)
          return
        end

        cancel = -> { cancelled?(request, epoch) }
        ensure_cursor(request.source, cancel: cancel)
        content = @cursor.advance_to(sample: request.sample,
                                     cancel: cancel)
        return if cancelled?(request, epoch)

        publish(result_for(request, content: content), epoch)
      rescue Cursor::Cancelled, Reader::Cancelled
        nil
      rescue StandardError => e
        message = sanitize(e.message)
        cache_error(error_key, message)
        log_error_once(error_key, e)
        publish(result_for(request, status: :error, message: message), epoch) unless cancelled?(request, epoch)
      ensure
        @mutex.synchronize do
          if @active_request.equal?(request)
            @active_request = nil
            @active_epoch = nil
          end
        end
      end

      def ensure_cursor(source, cancel:)
        if @cursor && @cursor_source == source
          signature = stat_signature(source.path)
          unless signature == @source_signature
            close_cursor
            raise Reader::ReadError, 'VGM source changed while playback was active'
          end
          return
        end

        close_cursor
        before = stat_signature(source.path)
        reader = @reader_factory.call(source.path, max_bytes: @max_bytes, cancel: cancel)
        raise Reader::Cancelled if cancel.call

        after = stat_signature(source.path)
        raise Reader::ReadError, 'VGM source changed while it was being read' unless before == after

        @cursor = @cursor_factory.call(reader, source: source)
        @cursor_source = source
        @source_signature = after
        @cached_error_key = nil
        @cached_error_message = nil
      end

      def stat_signature(path)
        stat = @stat_factory.call(path)
        [stat.dev, stat.ino, stat.size, stat.mtime.to_r].freeze
      end

      def cancelled?(request, epoch)
        @mutex.synchronize do
          @shutdown || @suspended || @epoch != epoch ||
            ((latest = @pending_request) &&
              (latest.source != request.source || latest.revision != request.revision))
        end
      end

      def result_for(request, content: nil, status: nil, message: nil)
        Snapshot.new(generation: request.source.generation, revision: request.revision,
                     sample: content ? content.sample : request.sample,
                     status: status || content.status, message: message || content&.message,
                     loop_count: content&.loop_count || 0, chips: content&.chips || [],
                     warnings: content&.warnings || [])
      end

      def publish(snapshot, epoch)
        @mutex.synchronize do
          return if @shutdown || @suspended

          active = @active_request
          return unless active && active.source.generation == snapshot.generation &&
                        active.revision == snapshot.revision && @active_epoch == epoch && @epoch == epoch

          pending = @pending_request
          return if pending && (pending.source != active.source || pending.revision != active.revision)

          @snapshot = snapshot
          return if @notification_pending

          @notification_pending = true
          begin
            @event_bus.publish(:vgm_telemetry_ready, telemetry: self)
          rescue StandardError
            @notification_pending = false
          end
        end
      end

      def cached_error(key)
        @mutex.synchronize { @cached_error_message if @cached_error_key == key }
      end

      def cache_error(key, message)
        @mutex.synchronize do
          @cached_error_key = key
          @cached_error_message = message
        end
      end

      def log_error_once(key, error)
        @mutex.synchronize do
          error_key = [key, error.class.name, error.message]
          return if @logged_errors.include?(error_key)

          @logged_errors << error_key
          @logged_errors.delete(@logged_errors.first) while @logged_errors.size > 128
        end
        (@logger || RubyPlayer.logger).error("VGM telemetry #{key.first.path}: #{error.class}: #{error.message}")
      rescue StandardError
        nil
      end

      def sanitize(message)
        message.to_s.gsub(/[[:cntrl:]]/, ' ').strip[0, ERROR_MESSAGE_LIMIT]
      end

      def close_cursor
        @cursor&.close
        @cursor = nil
        @cursor_source = nil
        @source_signature = nil
      rescue StandardError => e
        log_error_once([@cursor_source, 0], e)
        @cursor = nil
        @cursor_source = nil
        @source_signature = nil
      end
    end
  end
end
