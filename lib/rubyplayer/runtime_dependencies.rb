require "ffi"

module RubyPlayer
  # Runs before UI/audio requires so installation problems become one concise
  # diagnostic instead of the first raw dlopen or spawn error encountered.
  class RuntimeDependencies
    class MissingError < StandardError; end

    GME_LIBRARY_CANDIDATES = ["gme", "libgme.dylib",
                              "/opt/homebrew/lib/libgme.dylib"].freeze
    OPENMPT_LIBRARY_CANDIDATES = ["openmpt", "libopenmpt.dylib",
                                  "/opt/homebrew/lib/libopenmpt.dylib"].freeze
    NATIVE_SHIM = File.expand_path("native/librp_audio.dylib", __dir__)

    Library = Data.define(:name, :candidates, :formula)
    Command = Data.define(:name, :formula)

    LIBRARIES = [
      Library.new("libgme", GME_LIBRARY_CANDIDATES, "libgme"),
      Library.new("libopenmpt", OPENMPT_LIBRARY_CANDIDATES, "libopenmpt"),
    ].freeze
    COMMANDS = [
      Command.new("sox", "sox"),
      Command.new("ffmpeg", "ffmpeg"),
      Command.new("ffprobe", "ffmpeg"),
      Command.new("bsdtar", "libarchive"),
    ].freeze

    def self.verify!
      new.verify!
    end

    def initialize(executable_probe: nil, library_probe: nil, file_probe: File.method(:file?),
                   path: ENV.fetch("PATH", ""))
      @executable_probe = executable_probe || ->(name) { executable_on_path?(name, path) }
      @library_probe = library_probe || method(:loadable_library?)
      @file_probe = file_probe
    end

    def check
      missing_specs.map(&:name)
    end

    def verify!
      missing = missing_specs
      raise MissingError, diagnostic(missing) unless missing.empty?

      true
    end

    private

    def missing_specs
      missing = LIBRARIES.reject { |spec| available? { @library_probe.call(spec.candidates) } }
      missing.concat(COMMANDS.reject { |spec| available? { @executable_probe.call(spec.name) } })
      unless available? { @file_probe.call(NATIVE_SHIM) }
        missing << Command.new("native audio shim", nil)
      end
      missing
    end

    # Probe exceptions mean runtime cannot prove dependency usable. Treat them
    # as missing installation state; startup diagnostic remains actionable.
    def available?
      !!yield
    rescue StandardError, LoadError
      false
    end

    def executable_on_path?(name, path)
      path.split(File::PATH_SEPARATOR).any? do |directory|
        directory = "." if directory.empty?
        candidate = File.join(directory, name)
        File.file?(candidate) && File.executable?(candidate)
      end
    end

    # Probe actual loader candidates rather than `brew list`: runtime cares
    # whether dlopen succeeds, not which package manager installed library.
    def loadable_library?(candidates)
      flags = FFI::DynamicLibrary::RTLD_LAZY | FFI::DynamicLibrary::RTLD_LOCAL
      candidates.any? do |candidate|
        FFI::DynamicLibrary.open(candidate, flags)
        true
      rescue LoadError
        false
      end
    end

    def diagnostic(missing)
      lines = ["rubyplayer cannot start; missing runtime dependencies:"]
      lines.concat(missing.map { |spec| "- #{spec.name}" })

      formulas = missing.filter_map(&:formula).uniq
      unless formulas.empty?
        lines.concat(["", "Install missing Homebrew packages:",
                      "  brew install #{formulas.join(' ')}"])
      end
      if missing.any? { |spec| spec.name == "native audio shim" }
        lines.concat(["", "Build rubyplayer's native audio shim:",
                      "  bundle exec rake compile"])
      end
      lines.join("\n")
    end
  end
end
