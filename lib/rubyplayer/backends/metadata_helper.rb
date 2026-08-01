module RubyPlayer
  module Backends
    module MetadataHelper
      module_function

      def presence(str)
        str.nil? || str.empty? ? nil : str
      end

      def format_extension(path)
        File.extname(path).delete_prefix('.').downcase
      end
    end
  end
end
