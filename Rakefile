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

# Vendored libgme (see ext/gme/VENDOR.md for the flags). Each native player
# links the shared framework plus only its own format's emulator, enabled
# with -DUSE_GME_*. Hidden visibility keeps these libgme symbols from
# colliding with Homebrew libgme, loaded into the same process for every
# other format.
GME_FRAMEWORK = %w[Blip_Buffer Classic_Emu Data_Reader Effects_Buffer Gme_File M3u_Playlist Multi_Buffer
                   Music_Emu gme].map { |name| "ext/gme/#{name}.cpp" }.freeze
GME_HEADERS = Dir['ext/gme/**/*.h'].freeze
GME_FLAGS = '-O2 -DNDEBUG -DBLARGG_LITTLE_ENDIAN=1 -fvisibility=hidden'

def gme_player(dylib, sources:, hooks:, types:, objects: [])
  headers = [*GME_HEADERS, hooks, *Dir["#{File.dirname(hooks)}/*.h"], *Dir['ext/rp_gme/*.h']]
  defines = types.map { |type| "-DUSE_GME_#{type}" }.join(' ')
  file dylib => sources + objects + headers do
    mkdir_p 'lib/rubyplayer/native'
    sh "clang++ -std=c++11 #{GME_FLAGS} -fvisibility-inlines-hidden #{defines} -include #{hooks} -dynamiclib " \
       "-I ext/gme -I ext/rp_gme -I #{File.dirname(hooks)} -o #{dylib} #{(sources + objects).join(' ')}"
  end
end

GBS_DYLIB = 'lib/rubyplayer/native/librp_gbs.dylib'
gme_player GBS_DYLIB, hooks: 'ext/rp_gbs/rp_gbs_hooks.h', types: %w[GBS],
                      sources: ['ext/rp_gbs/rp_gbs.cpp', *GME_FRAMEWORK,
                                *%w[Gb_Apu Gb_Cpu Gb_Oscs Gbs_Emu].map { |name| "ext/gme/#{name}.cpp" }]

# emu2413 (the VRC7's FM core) is C, so it is compiled on its own.
EMU2413_OBJECT = 'tmp/native/emu2413.o'
file EMU2413_OBJECT => ['ext/gme/ext/emu2413.c', 'ext/gme/ext/emu2413.h'] do
  mkdir_p 'tmp/native'
  sh "clang #{GME_FLAGS} -c -o #{EMU2413_OBJECT} ext/gme/ext/emu2413.c"
end

NSF_DYLIB = 'lib/rubyplayer/native/librp_nsf.dylib'
gme_player NSF_DYLIB, hooks: 'ext/rp_nsf/rp_nsf_hooks.h', types: %w[NSF NSFE], objects: [EMU2413_OBJECT],
                      sources: ['ext/rp_nsf/rp_nsf.cpp', *GME_FRAMEWORK,
                                *%w[Nes_Apu Nes_Cpu Nes_Oscs Nes_Fme7_Apu Nes_Namco_Apu Nes_Vrc6_Apu Nes_Fds_Apu
                                    Nes_Vrc7_Apu Nsf_Emu Nsfe_Emu].map { |name| "ext/gme/#{name}.cpp" }]

HES_DYLIB = 'lib/rubyplayer/native/librp_hes.dylib'
gme_player HES_DYLIB, hooks: 'ext/rp_hes/rp_hes_hooks.h', types: %w[HES],
                      sources: ['ext/rp_hes/rp_hes.cpp', *GME_FRAMEWORK,
                                *%w[Hes_Apu Hes_Apu_Adpcm Hes_Cpu Hes_Emu].map { |name| "ext/gme/#{name}.cpp" }]

desc 'Build the native audio shim and the SPC, GBS, NSF, and HES players'
task compile: [NATIVE_DYLIB, SPC_DYLIB, GBS_DYLIB, NSF_DYLIB, HES_DYLIB]

task test: :compile

task default: :test
