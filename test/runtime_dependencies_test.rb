require "test_helper"
require "rubyplayer/runtime_dependencies"

class RuntimeDependenciesTest < Minitest::Test
  def build_checker(executables: true, libraries: true, native_shim: true)
    RubyPlayer::RuntimeDependencies.new(
      executable_probe: ->(name) { executables == true || executables.include?(name) },
      library_probe: ->(candidates) { libraries == true || libraries.include?(candidates) },
      file_probe: ->(_path) { native_shim },
    )
  end

  def test_verify_succeeds_when_all_dependencies_exist
    checker = build_checker

    assert_empty checker.check
    assert checker.verify!
  end

  def test_reports_all_missing_dependencies_and_deduplicates_formulas
    checker = build_checker(
      executables: ["bsdtar"],
      libraries: [RubyPlayer::RuntimeDependencies::OPENMPT_LIBRARY_CANDIDATES],
    )

    error = assert_raises(RubyPlayer::RuntimeDependencies::MissingError) { checker.verify! }

    assert_includes error.message, "- libgme"
    assert_includes error.message, "- sox"
    assert_includes error.message, "- ffmpeg"
    assert_includes error.message, "- ffprobe"
    assert_includes error.message, "brew install libgme sox ffmpeg"
    install_line = error.message.lines.find { |line| line.include?("brew install") }
    assert_equal 1, install_line.split.count("ffmpeg"),
      "ffmpeg formula should appear once for ffmpeg and ffprobe"
  end

  def test_missing_native_shim_prints_project_build_command
    checker = build_checker(native_shim: false)

    error = assert_raises(RubyPlayer::RuntimeDependencies::MissingError) { checker.verify! }

    assert_includes error.message, "- native audio shim"
    assert_includes error.message, "bundle exec rake compile"
    refute_includes error.message, "brew install"
  end

  def test_probe_errors_are_treated_as_missing_dependencies
    boom = ->(*) { raise "probe failed" }
    checker = RubyPlayer::RuntimeDependencies.new(
      executable_probe: boom,
      library_probe: boom,
      file_probe: boom,
    )

    missing = checker.check

    assert_equal ["libgme", "libopenmpt", "sox", "ffmpeg", "ffprobe", "bsdtar",
                  "native audio shim"], missing
  end
end
