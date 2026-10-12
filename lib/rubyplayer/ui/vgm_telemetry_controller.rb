# frozen_string_literal: true

module RubyPlayer
  module UI
    # Gates telemetry work on visibility and sample identity, then accepts useful results.
    class VgmTelemetryController
      CATCH_UP_THRESHOLD_SAMPLES = 6_615
      TERMINAL_STATUSES = %i[error unsupported ended].freeze
      private_constant :CATCH_UP_THRESHOLD_SAMPLES, :TERMINAL_STATUSES

      def initialize(engine:, telemetry:, refresh_hz:, clock:)
        unless refresh_hz.is_a?(Integer) && refresh_hz.between?(1, 30)
          raise ArgumentError, 'refresh_hz must be an Integer from 1 to 30'
        end

        @engine = engine
        @telemetry = telemetry
        @interval = 1.0 / refresh_hz
        @clock = clock
        @visible = false
        @suspended = true
        @identity = nil
        @target_sample = nil
        @last_accepted_sample = nil
        @snapshot = nil
        @terminal = false
        @next_request_at = nil
      end

      def visible=(visible)
        visible = visible == true
        return if @visible == visible

        @visible = visible
        if visible
          @identity = nil
          @target_sample = nil
          @last_accepted_sample = nil
          @snapshot = nil
          @terminal = false
          @next_request_at = nil
          @suspended = true
        else
          suspend
        end
      end

      def configure(refresh_hz:)
        unless refresh_hz.is_a?(Integer) && refresh_hz.between?(1, 30)
          raise ArgumentError, 'refresh_hz must be an Integer from 1 to 30'
        end

        @interval = 1.0 / refresh_hz
        @telemetry.suspend if @visible && !@suspended
        @suspended = true
        @identity = nil
        @target_sample = nil
        @last_accepted_sample = nil
        @snapshot = nil
        @terminal = false
        @next_request_at = nil
      end

      # Tick and accept are side-effecting actions that report whether they progressed.
      # rubocop:disable Naming/PredicateMethod
      def tick
        return false unless @visible

        request = @engine.vgm_telemetry_request
        unless request
          suspend unless @suspended
          return false
        end

        identity = [request.source.generation, request.revision].freeze
        changed = identity != @identity
        reset_for(identity) if changed
        @target_sample = request.sample
        return false if @terminal

        now = @clock.call
        immediate = changed || @suspended || @next_request_at.nil?
        return false unless immediate || (!request.paused && now >= @next_request_at)

        @telemetry.request(request)
        @suspended = false
        @next_request_at = now + @interval
        true
      end

      def accept(snapshot)
        return false unless @visible && @identity && snapshot
        return false unless [snapshot.generation, snapshot.revision] == @identity
        return false if snapshot.sample > @target_sample
        return false if @last_accepted_sample && snapshot.sample < @last_accepted_sample

        @snapshot = snapshot
        @last_accepted_sample = snapshot.sample
        @terminal = TERMINAL_STATUSES.include?(snapshot.status)
        true
      end
      # rubocop:enable Naming/PredicateMethod

      def snapshot
        return unless @snapshot
        return @snapshot unless @target_sample &&
                                @target_sample - @snapshot.sample > CATCH_UP_THRESHOLD_SAMPLES

        @snapshot.with(message: 'Catching up')
      end

      def shutdown
        @visible = false
        @telemetry.shutdown
      end

      private

      def reset_for(identity)
        @identity = identity
        @snapshot = nil
        @last_accepted_sample = nil
        @terminal = false
        @next_request_at = nil
      end

      def suspend
        return if @suspended

        @telemetry.suspend
        @suspended = true
        @identity = nil
        @target_sample = nil
        @last_accepted_sample = nil
        @snapshot = nil
        @terminal = false
        @next_request_at = nil
      end
    end
  end
end
