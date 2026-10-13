# frozen_string_literal: true

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
      # Native players that record live chip state: backend name => the file
      # defining it and its class. libgme still scans these formats, and
      # plays them itself when a player's dylib is missing.
      NATIVE_BACKENDS = {
        snes_spc: %w[snes_spc SnesSpc],
        gbs_native: %w[gbs_native GbsNative],
        nsf_native: %w[nsf_native NsfNative]
      }.freeze

      def initialize(overrides = {})
        @map = {}
        GME_EXTS.each { |e| @map[e] = :gme }
        OPENMPT_EXTS.each { |e| @map[e] = :openmpt }
        FFMPEG_EXTS.each { |e| @map[e] = :ffmpeg }
        # Playback of these moves to native players (NATIVE_BACKENDS).
        @map['.spc'] = :snes_spc
        @map['.gbs'] = :gbs_native
        @map['.nsf'] = @map['.nsfe'] = :nsf_native
        (overrides || {}).each do |ext, name|
          e = ext.start_with?('.') ? ext.downcase : ".#{ext.downcase}"
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
        name = backend_name_for(path)
        case name
        when :gme then gme_backend
        when *NATIVE_BACKENDS.keys then native_backend(name)
        when :openmpt
          @instances[:openmpt] ||= begin
            require_relative 'openmpt'
            Openmpt.new
          end
        when :ffmpeg
          @instances[:ffmpeg] ||= begin
            require_relative 'ffmpeg'
            Ffmpeg.new
          end
        end
      end

      private

      # Lazily require the FFI binding so the registry (and its pure
      # extension-mapping logic) can be used/tested without the native
      # libgme library being installed.
      def gme_backend
        @instances[:gme] ||= begin
          require_relative 'gme'
          Gme.new
        end
      end

      def native_backend(name)
        file, class_name = NATIVE_BACKENDS.fetch(name)
        require_relative file
        backend = Backends.const_get(class_name)
        return gme_backend unless backend.available?

        @instances[name] ||= backend.new(gme: gme_backend)
      end

      def ext_of(path) = File.extname(path).downcase
    end
  end
end
