require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.pattern = "test/**/*_test.rb"
end

NATIVE_DYLIB = "lib/rubyplayer/native/librp_audio.dylib"

file NATIVE_DYLIB => ["ext/rp_audio/rp_audio.c", "ext/rp_audio/miniaudio.h"] do
  mkdir_p "lib/rubyplayer/native"
  sh "clang -O2 -dynamiclib -o #{NATIVE_DYLIB} ext/rp_audio/rp_audio.c " \
     "-framework CoreFoundation -framework CoreAudio -framework AudioToolbox " \
     "-lpthread -lm"
end

desc "Build the native audio shim"
task compile: NATIVE_DYLIB

task test: :compile

task default: :test
