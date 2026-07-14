require "did_you_mean"
require_relative "theme"

module RubyPlayer
  class ConfigError < StandardError
    attr_reader :path, :original

    def initialize(path:, original: nil, message: nil)
      @path = path
      @original = original
      super(message || self.class.describe(path, original))
      set_backtrace(original.backtrace) if original&.backtrace
    end

    def self.describe(path, error)
      location = error&.backtrace&.find { |line| line.start_with?("#{path}:") }
      detail = "#{error.class}: #{error.message}"
      location ? "#{location}: #{detail}" : "#{path}: #{detail}"
    end
  end

  module ConfigDSL
    class SettingError < StandardError; end

    DYNAMIC_MAPS = [%w[backends], %w[keymap global], %w[keymap library],
                    %w[keymap tracks]].freeze

    class Section
      def initialize(data, path = [])
        @data = data
        @path = path
      end

      def [](key)
        key = key.to_s
        return wrap(key, @data[key]) if @data.key?(key)
        return nil if dynamic_map?

        unknown!(key)
      end

      def []=(key, value)
        key = key.to_s
        unknown!(key) unless dynamic_map? || @data.key?(key)
        @data[key] = value
      end

      def method_missing(name, *args)
        method = name.to_s
        if method.end_with?("=")
          key = method.delete_suffix("=")
          return super unless args.one?
          unknown!(key) unless @data.key?(key)
          @data[key] = args.first
        elsif args.empty? && @data.key?(method)
          wrap(method, @data[method])
        else
          unknown!(method)
        end
      end

      def respond_to_missing?(name, include_private = false)
        @data.key?(name.to_s.delete_suffix("=")) || super
      end

      private

      def wrap(key, value)
        value.is_a?(Hash) ? Section.new(value, @path + [key]) : value
      end

      def dynamic_map?
        DYNAMIC_MAPS.include?(@path)
      end

      def unknown!(key)
        full_path = (@path + [key]).join(".")
        suggestion = DidYouMean::SpellChecker.new(dictionary: @data.keys).correct(key).first
        hint = suggestion ? "; did you mean #{suggestion.inspect}?" : ""
        raise SettingError, "unknown setting #{full_path.inspect}#{hint}"
      end
    end

    module_function

    def evaluate(source, path:, defaults:)
      data = deep_copy(defaults)
      builder = Section.new(data)
      facade = Module.new
      facade.define_singleton_method(:configure) do |&block|
        raise SettingError, "RubyPlayer.configure requires a block" unless block
        block.call(builder)
      end
      scope = Module.new
      scope.const_set(:RubyPlayer, facade)
      scope.module_eval(source, path, 1)
      validate!(data)
      data
    rescue ConfigError
      raise
    rescue ScriptError, StandardError => error
      raise ConfigError.new(path: path, original: error), cause: error
    end

    def deep_copy(value)
      case value
      when Hash then value.to_h { |key, child| [key.dup, deep_copy(child)] }
      when Array then value.map { |child| deep_copy(child) }
      else value
      end
    end

    def validate!(data)
      validate_known_tree!(data, RubyPlayer::DEFAULTS)
      validate_special_values!(data)
      data
    end

    def validate_known_tree!(data, defaults, path = [])
      data.each do |key, value|
        current = path + [key]
        next if DYNAMIC_MAPS.include?(path)
        raise SettingError, "unknown setting #{current.join('.').inspect}" unless defaults.key?(key)

        expected = defaults[key]
        if expected.is_a?(Hash)
          raise SettingError, "#{current.join('.')} must be a Hash" unless value.is_a?(Hash)
          validate_known_tree!(value, expected, current)
        elsif expected.respond_to?(:call)
          raise SettingError, "#{current.join('.')} must respond to call" unless value.respond_to?(:call)
        elsif current == %w[audio sample_rate]
          next
        elsif expected.is_a?(Integer)
          raise SettingError, "#{current.join('.')} must be an Integer" unless value.is_a?(Integer)
        elsif !value.is_a?(expected.class)
          raise SettingError, "#{current.join('.')} must be a #{expected.class}"
        end
      end
    end

    def validate_special_values!(data)
      positive = %w[
        ui.frame_fps ui.status_message_seconds ui.seek_seconds
        audio.ring_buffer_ms audio.decode_chunk_frames
        library.backup_retention library.history_limit
        library.history_min_seconds_unknown library.undo_depth
        eq.bands eq.fps
      ]
      positive.each do |setting|
        value = dig(data, setting)
        raise SettingError, "#{setting} must be a positive Integer" unless value.is_a?(Integer) && value.positive?
      end

      pane_percent = dig(data, "ui.library_pane_percent")
      unless pane_percent.is_a?(Integer) && pane_percent.between?(1, 99)
        raise SettingError, "ui.library_pane_percent must be an Integer from 1 to 99"
      end

      scan_threads = dig(data, "scanner.thread_count")
      unless scan_threads.is_a?(Integer) && scan_threads >= 0
        raise SettingError, "scanner.thread_count must be a nonnegative Integer"
      end

      history_percent = dig(data, "library.history_min_percent")
      unless history_percent.is_a?(Integer) && history_percent.between?(0, 100)
        raise SettingError, "library.history_min_percent must be an Integer from 0 to 100"
      end

      sample_rate = dig(data, "audio.sample_rate")
      unless sample_rate == "auto" || (sample_rate.is_a?(Integer) && sample_rate.positive?)
        raise SettingError, 'audio.sample_rate must be "auto" or a positive Integer'
      end

      theme = dig(data, "ui.theme")
      raise SettingError, "ui.theme must name a known theme" unless Theme::ALL_IDS.include?(theme.to_sym)
    end

    def dig(data, path)
      path.split(".").reduce(data) { |value, key| value.fetch(key) }
    end
  end
end
