module RubyPlayer
  module Backends
    class Registry
      GME_EXTS = %w[.nsf .nsfe .gbs .hes .sap .spc .vgm .vgz .gym .ay .kss].freeze
      OPENMPT_EXTS = %w[.mod .xm .it .s3m .mptm .mtm .669 .med .okt .stm .ult
                        .amf .dsm .far .ptm].freeze
      FFMPEG_EXTS = %w[.mp3 .mp4 .m4a .m4b .aac .flac .alac .ogg .oga .opus .wav
                       .aif .aiff .wma].freeze
      # Formats whose single file can hold many subtunes.
      MULTITRACK_EXTS = %w[.nsf .nsfe .gbs .hes .sap .ay .kss].freeze
      # Archive containers whose entries are extracted and scanned as tracks.
      ARCHIVE_EXTS = %w[.zip .7z .rar].freeze

      def initialize(overrides = {})
        @map = {}
        GME_EXTS.each { |e| @map[e] = :gme }
        OPENMPT_EXTS.each { |e| @map[e] = :openmpt }
        FFMPEG_EXTS.each { |e| @map[e] = :ffmpeg }
        (overrides || {}).each do |ext, name|
          e = ext.start_with?(".") ? ext.downcase : ".#{ext.downcase}"
          @map[e] = name.to_sym
        end
        @instances = {}
      end

      # Archives count as supported so the Scanner picks them up, but they
      # have no backend of their own -- the ExtractorPool unpacks them and
      # dispatches each entry to its real backend.
      def supported?(path) = @map.key?(ext_of(path)) || archive?(path)
      def archive?(path) = ARCHIVE_EXTS.include?(ext_of(path))
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
        when :ffmpeg
          @instances[:ffmpeg] ||= begin
            require_relative "ffmpeg"
            Ffmpeg.new
          end
        end
      end

      private

      def ext_of(path) = File.extname(path).downcase
    end
  end
end
