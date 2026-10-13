require 'test_helper'
require 'rubyplayer/runtime_dependencies'
require 'stringio'

class RuntimeDependenciesTest < Minitest::Test
  def build_checker(executables: true, libraries: true, native_libraries: true,
                    builder: ->(_) { true }, output: StringIO.new)
    RubyPlayer::RuntimeDependencies.new(
      executable_probe: ->(name) { executables == true || executables.include?(name) },
      library_probe: ->(candidates) { libraries == true || libraries.include?(candidates) },
      file_probe: ->(path) { native_libraries == true || Array(native_libraries).include?(path) },
      native_builder: builder,
      output: output
    )
  end

  def test_verify_succeeds_when_all_dependencies_exist
    checker = build_checker

    assert_empty checker.check
    assert checker.verify!
  end

  def test_reports_all_missing_dependencies_and_deduplicates_formulas
    checker = build_checker(
      executables: ['bsdtar'],
      libraries: [RubyPlayer::RuntimeDependencies::OPENMPT_LIBRARY_CANDIDATES]
    )

    error = assert_raises(RubyPlayer::RuntimeDependencies::MissingError) { checker.verify! }

    assert_includes error.message, '- libgme'
    assert_includes error.message, '- sox'
    assert_includes error.message, '- ffmpeg'
    assert_includes error.message, '- ffprobe'
    assert_includes error.message, 'brew install libgme sox ffmpeg'
    install_line = error.message.lines.find { |line| line.include?('brew install') }

    assert_equal 1, install_line.split.count('ffmpeg'),
                 'ffmpeg formula should appear once for ffmpeg and ffprobe'
  end

  def test_missing_native_libraries_are_built_then_checked_again
    audio_path = File.expand_path('../lib/rubyplayer/native/librp_audio.dylib', __dir__)
    spc_path = File.expand_path('../lib/rubyplayer/native/librp_spc.dylib', __dir__)
    present = { audio_path => false, spc_path => false }
    targets = nil
    checker = RubyPlayer::RuntimeDependencies.new(
      executable_probe: ->(_) { true }, library_probe: ->(_) { true },
      file_probe: ->(path) { present.fetch(path, true) },
      native_builder: lambda { |missing_targets|
        targets = missing_targets
        present[audio_path] = present[spc_path] = true
      }, output: StringIO.new
    )

    assert checker.verify!
    assert_equal %w[lib/rubyplayer/native/librp_audio.dylib lib/rubyplayer/native/librp_spc.dylib], targets
  end

  def test_unloadable_native_library_is_rebuilt
    spc_path = File.expand_path('../lib/rubyplayer/native/librp_spc.dylib', __dir__)
    loadable = false
    targets = nil
    checker = RubyPlayer::RuntimeDependencies.new(
      executable_probe: ->(_) { true },
      library_probe: ->(candidates) { candidates != [spc_path] || loadable },
      file_probe: ->(_) { true },
      native_builder: lambda { |missing_targets|
        targets = missing_targets
        loadable = true
      }, output: StringIO.new
    )

    assert checker.verify!
    assert_equal ['lib/rubyplayer/native/librp_spc.dylib'], targets
  end

  def test_healthy_native_libraries_do_not_start_build
    checker = build_checker(builder: ->(_) { flunk 'unexpected build' })

    assert checker.verify!
  end

  def test_another_launch_can_finish_building_before_this_one_takes_the_build_lock
    audio_path = File.expand_path('../lib/rubyplayer/native/librp_audio.dylib', __dir__)
    audio_probes = 0
    checker = RubyPlayer::RuntimeDependencies.new(
      executable_probe: ->(_) { true }, library_probe: ->(_) { true },
      file_probe: lambda { |path|
        next true unless path == audio_path

        audio_probes += 1
        audio_probes > 1
      },
      native_builder: ->(_) { flunk 'already built by another launch' },
      output: StringIO.new
    )

    assert checker.verify!
  end

  def test_failed_build_is_reported_without_retry
    builds = 0
    checker = build_checker(native_libraries: false, builder: lambda { |_targets|
      builds += 1
      false
    })

    error = assert_raises(RubyPlayer::RuntimeDependencies::MissingError) { checker.verify! }

    assert_equal 1, builds
    assert_includes error.message, 'native audio shim'
    assert_includes error.message, 'compilation failed'
  end

  def test_successful_build_that_remains_unloadable_stops_after_one_attempt
    builds = 0
    checker = build_checker(native_libraries: false, builder: lambda { |_targets|
      builds += 1
      true
    })

    error = assert_raises(RubyPlayer::RuntimeDependencies::MissingError) { checker.verify! }

    assert_equal 1, builds
    assert_includes error.message, 'native GBS player'
  end

  def test_probe_errors_are_treated_as_missing_dependencies
    boom = ->(*) { raise 'probe failed' }
    checker = RubyPlayer::RuntimeDependencies.new(
      executable_probe: boom,
      library_probe: boom,
      file_probe: boom
    )

    missing = checker.check

    assert_equal ['libgme', 'libopenmpt', 'sox', 'ffmpeg', 'ffprobe', 'bsdtar',
                  'native audio shim', 'native SPC player', 'native GBS player',
                  'native NSF player', 'native HES player'], missing
  end
end
