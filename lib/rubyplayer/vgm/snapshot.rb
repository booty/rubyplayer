# frozen_string_literal: true

module RubyPlayer
  module Vgm
    # Freezes nested public values so snapshots can cross worker and UI threads safely.
    module Immutable
      def self.deep_freeze(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), copy|
            copy[deep_freeze(key)] = deep_freeze(item)
          end.freeze
        when Array
          value.map { |item| deep_freeze(item) }.freeze
        when String
          value.dup.freeze
        else
          value.freeze unless value.frozen? || value.nil? || value.is_a?(Numeric) || value.is_a?(Symbol)
          value
        end
      end

      def self.record(*members)
        klass = Class.new(Data.define(*members))
        klass.define_method(:initialize) do |**attributes|
          super(**attributes.transform_values { |value| Immutable.deep_freeze(value) })
        end
        klass
      end
      private_class_method :record
    end

    Source = Immutable.send(:record, :generation, :track_identity, :path, :format,
                            :sample_rate, :timeline_policy, :decoder_capabilities)
    Request = Immutable.send(:record, :source, :revision, :sample, :paused)
    Snapshot = Immutable.send(:record, :generation, :revision, :sample, :status,
                              :message, :loop_count, :chips, :warnings)
    ChipSnapshot = Immutable.send(:record, :id, :name, :clock_hz, :channels, :details)
    ChannelSnapshot = Immutable.send(:record, :id, :label, :kind, :state,
                                     :last_trigger_sample, :pitch_hz, :note, :pan,
                                     :patch, :details)
    Patch = Immutable.send(:record, :digest, :algorithm, :feedback, :operators, :details)
    Operator = Immutable.send(:record, :index, :parameters)
  end
end
