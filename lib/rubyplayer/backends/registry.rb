module RubyPlayer
  module Backends
    class Registry
      GME_EXTS = %w[.nsf .nsfe .gbs .hes .sap .spc .vgm .vgz .gym .ay .kss].freeze
      OPENMPT_EXTS = %w[.mod .xm .it .s3m .mptm .mtm .669 .med .okt .stm .ult
                        .amf .dsm .far .ptm].freeze
      # Formats whose single file can hold many subtunes.
      MULTITRACK_EXTS = %w[.nsf .nsfe .gbs .hes .sap .ay .kss].freeze

      def initialize(overrides = {})
        @map = {}
        GME_EXTS.each { |e| @map[e] = :gme }
        OPENMPT_EXTS.each { |e| @map[e] = :openmpt }
        (overrides || {}).each do |ext, name|
          e = ext.start_with?(".") ? ext.downcase : ".#{ext.downcase}"
          @map[e] = name.to_sym
        end
        @instances = {}
      end

      def supported?(path) = @map.key?(ext_of(path))
      def multitrack?(path) = MULTITRACK_EXTS.include?(ext_of(path))
      def backend_name_for(path) = @map[ext_of(path)]

      def backend_for(path)
        case backend_name_for(path)
        when :gme
          # Lazily require the FFI binding so the registry (and its pure
          # extension-mapping logic) can be used/tested without the native
          # libgme library being installed.
          @instances[:gme] ||= begin
            require_relative "gme"
            Gme.new
          end
        when :openmpt
          @instances[:openmpt] ||= begin
            require_relative "openmpt"
            Openmpt.new
          end
        end
      end

      private

      def ext_of(path) = File.extname(path).downcase
    end
  end
end
