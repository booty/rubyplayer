# frozen_string_literal: true

module RubyPlayer
  # Where `rake compile` puts each native artifact. The Rakefile builds these
  # targets, RuntimeDependencies checks and rebuilds them by name, and the
  # FFI bindings load them, so the paths live here once. Plain constants
  # with no requires: the Rakefile and startup preflight load this first.
  module NativePaths
    PROJECT_ROOT = File.expand_path('../..', __dir__)
    # Project-relative, because they double as rake file-task names.
    DIR = 'lib/rubyplayer/native'
    AUDIO_DYLIB = "#{DIR}/librp_audio.dylib".freeze
    MEDIA_KEYS_APP_CONTENTS = "#{DIR}/RubyPlayerMedia.app/Contents".freeze
    MEDIA_KEYS_HELPER = "#{MEDIA_KEYS_APP_CONTENTS}/MacOS/RubyPlayerMedia".freeze
    SPC_DYLIB = "#{DIR}/librp_spc.dylib".freeze
    GBS_DYLIB = "#{DIR}/librp_gbs.dylib".freeze
    NSF_DYLIB = "#{DIR}/librp_nsf.dylib".freeze
    HES_DYLIB = "#{DIR}/librp_hes.dylib".freeze

    def self.absolute(relative_path) = File.join(PROJECT_ROOT, relative_path)
  end
end
