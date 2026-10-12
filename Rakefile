# frozen_string_literal: true

require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test' << 'lib'
  t.pattern = 'test/**/*_test.rb'
end

NATIVE_DYLIB = 'lib/rubyplayer/native/librp_audio.dylib'

file NATIVE_DYLIB => ['ext/rp_audio/rp_audio.c', 'ext/rp_audio/miniaudio.h'] do
  mkdir_p 'lib/rubyplayer/native'
  sh "clang -O2 -dynamiclib -o #{NATIVE_DYLIB} ext/rp_audio/rp_audio.c " \
     '-framework CoreFoundation -framework CoreAudio -framework AudioToolbox ' \
     '-lpthread -lm'
end

SPC_DYLIB = 'lib/rubyplayer/native/librp_spc.dylib'
SPC_SOURCES = ['ext/rp_spc/rp_spc.cpp', *Dir['ext/snes_spc/*.cpp']].freeze
SPC_HEADERS = ['ext/rp_spc/rp_spc.h', *Dir['ext/snes_spc/*.h']].freeze

# Vendored libgme snes_spc core (see ext/snes_spc/VENDOR.md for the flags).
file SPC_DYLIB => SPC_SOURCES + SPC_HEADERS do
  mkdir_p 'lib/rubyplayer/native'
  sh 'clang++ -std=c++11 -O2 -DNDEBUG -DBLARGG_LITTLE_ENDIAN=1 -dynamiclib -I ext/snes_spc ' \
     "-o #{SPC_DYLIB} #{SPC_SOURCES.join(' ')}"
end

GBS_DYLIB = 'lib/rubyplayer/native/librp_gbs.dylib'
GBS_SOURCES = ['ext/rp_gbs/rp_gbs.cpp', *Dir['ext/gme_gbs/*.cpp']].freeze
GBS_HEADERS = ['ext/rp_gbs/rp_gbs.h', 'ext/rp_gbs/rp_gbs_hooks.h', *Dir['ext/gme_gbs/*.h']].freeze

# Vendored libgme GBS core (see ext/gme_gbs/VENDOR.md for the flags). Hidden
# visibility keeps its libgme symbols from colliding with Homebrew libgme,
# which is loaded into the same process for every other format.
file GBS_DYLIB => GBS_SOURCES + GBS_HEADERS do
  mkdir_p 'lib/rubyplayer/native'
  sh 'clang++ -std=c++11 -O2 -DNDEBUG -DBLARGG_LITTLE_ENDIAN=1 -fvisibility=hidden -fvisibility-inlines-hidden ' \
     '-include ext/rp_gbs/rp_gbs_hooks.h -dynamiclib -I ext/gme_gbs -I ext/rp_gbs ' \
     "-o #{GBS_DYLIB} #{GBS_SOURCES.join(' ')}"
end

desc 'Build the native audio shim, SPC player, and GBS player'
task compile: [NATIVE_DYLIB, SPC_DYLIB, GBS_DYLIB]

task test: :compile

task default: :test
