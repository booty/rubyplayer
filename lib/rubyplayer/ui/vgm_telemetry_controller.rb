# frozen_string_literal: true

module RubyPlayer
  module UI
    # Gates telemetry work on visibility and sample identity, then accepts useful results.
    class VgmTelemetryController
      CATCH_UP_THRESHOLD_SAMPLES = 6_615
      TERMINAL_STATUSES = %i[error unsupported ended].freeze
      REFRESH_HZ_RANGE = (1..30)
      private_constant :CATCH_UP_THRESHOLD_SAMPLES, :TERMINAL_STATUSES, :REFRESH_HZ_RANGE

      def initialize(engine:, telemetry:, refresh_hz:, clock:)
        @engine = engine
        @telemetry = telemetry
        @interval = interval_for(refresh_hz)
        @clock = clock
        @visible = false
        @suspended = true
        clear_session
      end

      def visible=(visible)
        visible = visible == true
        return if @visible == visible

        @visible = visible
        if visible
          # The worker was already suspended when the view was hidden.
          @suspended = true
          clear_session
        else
          suspend
        end
      end

      def configure(refresh_hz:)
        @interval = interval_for(refresh_hz)
        @telemetry.suspend if @visible && !@suspended
        @suspended = true
        clear_session
      end

      # Tick and accept are side-effecting actions that report whether they progressed.
      # rubocop:disable Naming/PredicateMethod
      def tick
        return false unless @visible

        request = @engine.vgm_telemetry_request
        unless request
          suspend
          return false
        end

        identity = [request.source.generation, request.revision].freeze
        changed = identity != @identity
        reset_for(identity) if changed
        @target_sample = request.sample
        return false if @terminal

        now = @clock.call
        immediate = changed || @suspended || @next_request_at.nil?
        # Replay may stop short of a target to stay responsive; a paused
        # engine never moves the target, so behind-target results still need
        # follow-up requests at the refresh rate.
        recurring = !request.paused || catching_up?
        return false unless immediate || (recurring && now >= @next_request_at)

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

      # Lets an idle main loop wake for catch-up requests instead of waiting
      # for its slower idle poll; nil when no follow-up is due.
      def seconds_until_due
        return unless @visible && !@terminal && @next_request_at && catching_up?

        [@next_request_at - @clock.call, 0].max
      end

      def shutdown
        @visible = false
        @telemetry.shutdown
      end

      private

      def interval_for(refresh_hz)
        unless refresh_hz.is_a?(Integer) && REFRESH_HZ_RANGE.cover?(refresh_hz)
          raise ArgumentError, "refresh_hz must be an Integer from #{REFRESH_HZ_RANGE.min} to #{REFRESH_HZ_RANGE.max}"
        end

        1.0 / refresh_hz
      end

      def catching_up?
        @snapshot && @target_sample && @snapshot.sample < @target_sample
      end

      # Identity change keeps the target sample it is about to overwrite;
      # visibility, configuration, and suspend forget the whole session.
      def reset_for(identity)
        clear_results
        @identity = identity
      end

      def clear_session
        clear_results
        @identity = nil
        @target_sample = nil
      end

      def clear_results
        @snapshot = nil
        @last_accepted_sample = nil
        @terminal = false
        @next_request_at = nil
      end

      def suspend
        return if @suspended

        @telemetry.suspend
        @suspended = true
        clear_session
      end
    end
  end
end
