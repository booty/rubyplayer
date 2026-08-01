module RubyPlayer
  module DurationFormatter
    module_function

    def format(milliseconds, unknown: nil)
      return unknown if milliseconds.nil? || milliseconds == false
      raise TypeError, "duration must be an Integer" unless milliseconds.is_a?(Integer)

      total = milliseconds / 1000
      Kernel.format("%d:%02d", total / 60, total % 60)
    end
  end
end
