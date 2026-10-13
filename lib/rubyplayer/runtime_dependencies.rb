# frozen_string_literal: true

require 'ffi'
require 'fileutils'
require 'rbconfig'

module RubyPlayer
  # Runs before UI/audio requires so installation problems become one concise
  # diagnostic instead of the first raw dlopen or spawn error encountered.
  class RuntimeDependencies
    class MissingError < StandardError; end

    GME_LIBRARY_CANDIDATES = ['gme', 'libgme.dylib',
                              '/opt/homebrew/lib/libgme.dylib'].freeze
    OPENMPT_LIBRARY_CANDIDATES = ['openmpt', 'libopenmpt.dylib',
                                  '/opt/homebrew/lib/libopenmpt.dylib'].freeze
    PROJECT_ROOT = File.expand_path('../..', __dir__)
    NATIVE_BUILD_DIR = File.join(PROJECT_ROOT, 'tmp/native')

    Library = Data.define(:name, :candidates, :formula)
    Command = Data.define(:name, :formula)
    NativeLibrary = Data.define(:name, :target) do
      def path
        File.join(PROJECT_ROOT, target)
      end
    end

    LIBRARIES = [
      Library.new('libgme', GME_LIBRARY_CANDIDATES, 'libgme'),
      Library.new('libopenmpt', OPENMPT_LIBRARY_CANDIDATES, 'libopenmpt')
    ].freeze
    COMMANDS = [
      Command.new('sox', 'sox'),
      Command.new('ffmpeg', 'ffmpeg'),
      Command.new('ffprobe', 'ffmpeg'),
      Command.new('bsdtar', 'libarchive')
    ].freeze
    NATIVE_LIBRARIES = [
      NativeLibrary.new('native audio shim', 'lib/rubyplayer/native/librp_audio.dylib'),
      NativeLibrary.new('native SPC player', 'lib/rubyplayer/native/librp_spc.dylib'),
      NativeLibrary.new('native GBS player', 'lib/rubyplayer/native/librp_gbs.dylib'),
      NativeLibrary.new('native NSF player', 'lib/rubyplayer/native/librp_nsf.dylib')
    ].freeze

    def self.verify!
      new.verify!
    end

    def initialize(executable_probe: nil, library_probe: nil, file_probe: File.method(:file?),
                   native_builder: nil, output: $stderr, path: ENV.fetch('PATH', ''))
      @executable_probe = executable_probe || ->(name) { executable_on_path?(name, path) }
      @library_probe = library_probe || method(:loadable_library?)
      @file_probe = file_probe
      @native_builder = native_builder || method(:build_native_libraries)
      @output = output
    end

    def check
      missing_specs.map(&:name)
    end

    def verify!
      missing = missing_specs
      native_missing = missing.grep(NativeLibrary)
      build_failed = false
      if native_missing.any? && missing.size == native_missing.size
        begin
          FileUtils.mkdir_p(NATIVE_BUILD_DIR)
          File.open(File.join(NATIVE_BUILD_DIR, 'compile.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
            lock.flock(File::LOCK_EX)
            native_missing = missing_native_libraries
            unless native_missing.empty?
              @output.puts 'Building rubyplayer native libraries...'
              build_failed = !@native_builder.call(native_missing.map(&:target))
            end
          end
          missing = missing_specs unless build_failed
        rescue StandardError => e
          @output.puts "Native build error: #{e.message}"
          build_failed = true
        end
      end
      raise MissingError, diagnostic(missing, build_failed: build_failed) unless missing.empty?

      true
    end

    private

    def missing_specs
      missing = LIBRARIES.reject { |spec| available? { @library_probe.call(spec.candidates) } }
      missing.concat(COMMANDS.reject { |spec| available? { @executable_probe.call(spec.name) } })
      missing.concat(missing_native_libraries)
      missing
    end

    def missing_native_libraries
      NATIVE_LIBRARIES.reject do |spec|
        available? { @file_probe.call(spec.path) && @library_probe.call([spec.path]) }
      end
    end

    def build_native_libraries(targets)
      system(RbConfig.ruby, '-S', 'bundle', 'exec', 'rake', '-B', *targets, chdir: PROJECT_ROOT)
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
        directory = '.' if directory.empty?
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

    def diagnostic(missing, build_failed: false)
      lines = ['rubyplayer cannot start; missing runtime dependencies:']
      lines.concat(missing.map { |spec| "- #{spec.name}" })
      lines << 'Native compilation failed; see the build output above.' if build_failed

      formulas = missing.grep(Library).filter_map(&:formula)
      formulas.concat(missing.grep(Command).filter_map(&:formula))
      formulas.uniq!
      unless formulas.empty?
        lines.push('', 'Install missing Homebrew packages:',
                   "  brew install #{formulas.join(' ')}")
      end
      if missing.any?(NativeLibrary)
        lines.push('', 'Retry the native build:',
                   '  mise exec -- bundle exec rake -B compile')
      end
      lines.join("\n")
    end
  end
end
