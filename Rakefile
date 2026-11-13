# frozen_string_literal: true

require 'rake/testtask'
require_relative 'lib/rubyplayer/native_paths'
require_relative 'lib/rubyplayer/native_build'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test' << 'lib'
  t.pattern = 'test/**/*_test.rb'
end

NATIVE_DYLIB = RubyPlayer::NativePaths::AUDIO_DYLIB

MEDIA_KEYS_APP_DIR = RubyPlayer::NativePaths::MEDIA_KEYS_APP_CONTENTS
MEDIA_KEYS_APP = RubyPlayer::NativePaths::MEDIA_KEYS_HELPER
file MEDIA_KEYS_APP => RubyPlayer::NativeBuild::DEPENDENCIES.fetch(MEDIA_KEYS_APP) do
  mkdir_p "#{MEDIA_KEYS_APP_DIR}/MacOS"
  cp 'ext/rp_media_keys/Info.plist', "#{MEDIA_KEYS_APP_DIR}/Info.plist"
  sh "clang -O2 -fobjc-arc -o #{MEDIA_KEYS_APP} ext/rp_media_keys/rp_media_keys.m " \
     '-framework AppKit -framework Foundation -framework MediaPlayer'
end

file NATIVE_DYLIB => RubyPlayer::NativeBuild::DEPENDENCIES.fetch(NATIVE_DYLIB) do
  mkdir_p RubyPlayer::NativePaths::DIR
  sh "clang -O2 -dynamiclib -o #{NATIVE_DYLIB} ext/rp_audio/rp_audio.c ext/rp_audio/effects.c " \
     '-framework CoreFoundation -framework CoreAudio -framework AudioToolbox ' \
     '-lpthread -lm'
end

SPC_DYLIB = RubyPlayer::NativePaths::SPC_DYLIB
SPC_SOURCES = RubyPlayer::NativeBuild::SPC_SOURCES

# Vendored libgme snes_spc core (see ext/snes_spc/VENDOR.md for the flags).
file SPC_DYLIB => RubyPlayer::NativeBuild::DEPENDENCIES.fetch(SPC_DYLIB) do
  mkdir_p RubyPlayer::NativePaths::DIR
  sh 'clang++ -std=c++11 -O2 -DNDEBUG -DBLARGG_LITTLE_ENDIAN=1 -dynamiclib -I ext/snes_spc ' \
     "-o #{SPC_DYLIB} #{SPC_SOURCES.join(' ')}"
end

# Vendored libgme (see ext/gme/VENDOR.md for the flags). Each native player
# links the shared framework plus only its own format's emulator, enabled
# with -DUSE_GME_*. Hidden visibility keeps these libgme symbols from
# colliding with Homebrew libgme, loaded into the same process for every
# other format.
GME_FLAGS = '-O2 -DNDEBUG -DBLARGG_LITTLE_ENDIAN=1 -fvisibility=hidden'

def gme_player(dylib, sources:, hooks:, types:, objects: [])
  defines = types.map { |type| "-DUSE_GME_#{type}" }.join(' ')
  file dylib => RubyPlayer::NativeBuild::DEPENDENCIES.fetch(dylib) do
    mkdir_p RubyPlayer::NativePaths::DIR
    sh "clang++ -std=c++11 #{GME_FLAGS} -fvisibility-inlines-hidden #{defines} -include #{hooks} -dynamiclib " \
       "-I ext/gme -I ext/rp_gme -I #{File.dirname(hooks)} -o #{dylib} #{(sources + objects).join(' ')}"
  end
end

GBS_DYLIB = RubyPlayer::NativePaths::GBS_DYLIB
gme_player GBS_DYLIB, hooks: 'ext/rp_gbs/rp_gbs_hooks.h', types: %w[GBS],
                      sources: RubyPlayer::NativeBuild::GBS_SOURCES

# emu2413 (the VRC7's FM core) is C, so it is compiled on its own.
EMU2413_OBJECT = RubyPlayer::NativeBuild::EMU2413_OBJECT
file EMU2413_OBJECT => RubyPlayer::NativeBuild::DEPENDENCIES.fetch(EMU2413_OBJECT) do
  mkdir_p 'tmp/native'
  sh "clang #{GME_FLAGS} -c -o #{EMU2413_OBJECT} ext/gme/ext/emu2413.c"
end

NSF_DYLIB = RubyPlayer::NativePaths::NSF_DYLIB
gme_player NSF_DYLIB, hooks: 'ext/rp_nsf/rp_nsf_hooks.h', types: %w[NSF NSFE], objects: [EMU2413_OBJECT],
                      sources: RubyPlayer::NativeBuild::NSF_SOURCES

HES_DYLIB = RubyPlayer::NativePaths::HES_DYLIB
gme_player HES_DYLIB, hooks: 'ext/rp_hes/rp_hes_hooks.h', types: %w[HES],
                      sources: RubyPlayer::NativeBuild::HES_SOURCES

desc 'Build the native audio shim and the SPC, GBS, NSF, and HES players'
task compile: [NATIVE_DYLIB, MEDIA_KEYS_APP, SPC_DYLIB, GBS_DYLIB, NSF_DYLIB, HES_DYLIB]

task test: :compile

namespace :test do
  desc 'Run the suite across parallel processes (TEST_SHARDS=n, default: cores up to 8)'
  task parallel: :compile do
    require_relative 'script/parallel_tests'
    shard_count = ENV['TEST_SHARDS']&.then { Integer(it) }
    abort 'parallel test run failed' unless ParallelTests.new(shard_count: shard_count).passed?
  end
end

task default: :test

desc 'Capture album art in real Kitty and iTerm2 windows and check aspect and gaps (macOS, opens windows)'
task :visual do
  require_relative 'script/visual/suite'
  out_dir = File.expand_path('tmp/visual', __dir__)
  abort "visual checks failed; captures in #{out_dir}" unless Visual::Suite.new(out_dir: out_dir).passed?
end
