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

desc 'Build the native audio shim and SPC player'
task compile: [NATIVE_DYLIB, SPC_DYLIB]

task test: :compile

task default: :test
