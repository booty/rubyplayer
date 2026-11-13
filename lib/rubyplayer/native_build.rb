# frozen_string_literal: true

require_relative 'native_paths'

module RubyPlayer
  # Shared by Rake and preflight; checking freshness must not load Rake or a
  # stale dylib (dlopen can retain its old symbols even after we replace it).
  module NativeBuild
    SPC_SOURCES = ['ext/rp_spc/rp_spc.cpp', *Dir.glob('ext/snes_spc/*.cpp', base: NativePaths::PROJECT_ROOT)].freeze
    GME_FRAMEWORK = %w[Blip_Buffer Classic_Emu Data_Reader Effects_Buffer Gme_File M3u_Playlist Multi_Buffer
                       Music_Emu gme].map { |name| "ext/gme/#{name}.cpp" }.freeze
    GME_HEADERS = Dir.glob('ext/gme/**/*.h', base: NativePaths::PROJECT_ROOT).freeze
    GBS_SOURCES = ['ext/rp_gbs/rp_gbs.cpp', *GME_FRAMEWORK,
                   *%w[Gb_Apu Gb_Cpu Gb_Oscs Gbs_Emu].map { |name| "ext/gme/#{name}.cpp" }].freeze
    NSF_SOURCES = ['ext/rp_nsf/rp_nsf.cpp', *GME_FRAMEWORK,
                   *%w[Nes_Apu Nes_Cpu Nes_Oscs Nes_Fme7_Apu Nes_Namco_Apu Nes_Vrc6_Apu Nes_Fds_Apu
                       Nes_Vrc7_Apu Nsf_Emu Nsfe_Emu].map { |name| "ext/gme/#{name}.cpp" }].freeze
    HES_SOURCES = ['ext/rp_hes/rp_hes.cpp', *GME_FRAMEWORK,
                   *%w[Hes_Apu Hes_Apu_Adpcm Hes_Cpu Hes_Emu].map { |name| "ext/gme/#{name}.cpp" }].freeze
    EMU2413_OBJECT = 'tmp/native/emu2413.o'
    BUILD_RULES = %w[Rakefile lib/rubyplayer/native_build.rb lib/rubyplayer/native_paths.rb].freeze

    def self.player_headers(directory)
      GME_HEADERS + Dir.glob(["#{directory}/*.h", 'ext/rp_gme/*.h'], base: NativePaths::PROJECT_ROOT)
    end

    DEPENDENCIES = {
      NativePaths::AUDIO_DYLIB => %w[ext/rp_audio/rp_audio.c ext/rp_audio/effects.c ext/rp_audio/effects.h
                                     ext/rp_audio/ring_cursor.h ext/rp_audio/miniaudio.h],
      NativePaths::MEDIA_KEYS_HELPER => %w[ext/rp_media_keys/rp_media_keys.m ext/rp_media_keys/Info.plist],
      NativePaths::SPC_DYLIB => SPC_SOURCES + ['ext/rp_spc/rp_spc.h',
                                               *Dir.glob('ext/snes_spc/*.h', base: NativePaths::PROJECT_ROOT)],
      NativePaths::GBS_DYLIB => GBS_SOURCES + player_headers('ext/rp_gbs'),
      NativePaths::NSF_DYLIB => NSF_SOURCES + [EMU2413_OBJECT] + player_headers('ext/rp_nsf'),
      NativePaths::HES_DYLIB => HES_SOURCES + player_headers('ext/rp_hes'),
      EMU2413_OBJECT => %w[ext/gme/ext/emu2413.c ext/gme/ext/emu2413.h]
    }.transform_values { |paths| (paths + BUILD_RULES).freeze }.freeze

    # Include transitive object inputs: a changed VRC7 source must invalidate
    # the NSF dylib even before Rake has rebuilt emu2413.o.
    def self.inputs(target)
      DEPENDENCIES.fetch(target).flat_map do |path|
        DEPENDENCIES.key?(path) ? [path, *inputs(path)] : path
      end.uniq
    end

    def self.stale?(target, root: NativePaths::PROJECT_ROOT)
      built_at = File.mtime(File.join(root, target))
      inputs(target).any? { |path| File.mtime(File.join(root, path)) > built_at }
    rescue Errno::ENOENT
      true
    end
  end
end
