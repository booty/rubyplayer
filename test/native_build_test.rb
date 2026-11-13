require 'test_helper'
require 'rubyplayer/runtime_dependencies'
require 'tmpdir'
require 'fileutils'

class NativeBuildTest < Minitest::Test
  def with_artifact(target)
    Dir.mktmpdir do |root|
      (RubyPlayer::NativeBuild.inputs(target) + [target]).each do |path|
        absolute = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(absolute))
        File.write(absolute, '')
        File.utime(Time.at(100), Time.at(100), absolute)
      end
      yield root
    end
  end

  def test_sources_headers_plist_and_build_rules_invalidate_their_artifacts
    {
      RubyPlayer::NativePaths::AUDIO_DYLIB => %w[ext/rp_audio/rp_audio.c ext/rp_audio/effects.h Rakefile
                                                 lib/rubyplayer/native_build.rb],
      RubyPlayer::NativePaths::MEDIA_KEYS_HELPER => %w[ext/rp_media_keys/Info.plist],
      RubyPlayer::NativePaths::SPC_DYLIB => %w[ext/snes_spc/Snes_Spc.cpp],
      RubyPlayer::NativePaths::GBS_DYLIB => %w[ext/gme/Gb_Apu.cpp ext/rp_gme/rp_recorder.h],
      RubyPlayer::NativePaths::NSF_DYLIB => %w[ext/gme/ext/emu2413.c ext/gme/ext/emu2413.h],
      RubyPlayer::NativePaths::HES_DYLIB => %w[ext/rp_hes/rp_hes_hooks.h]
    }.each do |target, changed_paths|
      with_artifact(target) do |root|
        refute RubyPlayer::NativeBuild.stale?(target, root: root), target
        changed_paths.each do |path|
          absolute = File.join(root, path)
          File.utime(Time.at(200), Time.at(200), absolute)

          assert RubyPlayer::NativeBuild.stale?(target, root: root), "changed input #{path}"
          File.utime(Time.at(100), Time.at(100), absolute)
        end
        File.unlink(File.join(root, target))

        assert RubyPlayer::NativeBuild.stale?(target, root: root), 'missing target'
      end
    end
  end

  def test_unrelated_sources_do_not_invalidate_audio
    with_artifact(RubyPlayer::NativePaths::AUDIO_DYLIB) do |root|
      FileUtils.mkdir_p(File.join(root, 'ext/rp_spc'))
      File.write(File.join(root, 'ext/rp_spc/rp_spc.cpp'), '')

      refute RubyPlayer::NativeBuild.stale?(RubyPlayer::NativePaths::AUDIO_DYLIB, root: root)
    end
  end
end
