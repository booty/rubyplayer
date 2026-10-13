# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/backends/native_gme_lib'

class NativeGmeLibTest < Minitest::Test
  # Stands in for an FFI::Library module, recording what would be attached.
  class FakeLibrary
    attr_reader :attached

    def initialize
      @attached = {}
    end

    def attach_function(name, parameters, result, **options)
      @attached[name] = [parameters, result, options]
    end
  end

  def test_attaches_the_standard_player_api_under_the_prefix
    library = FakeLibrary.new
    RubyPlayer::Backends::NativeGmeLib.attach_player_api(library, 'rp_x')

    assert_equal %i[rp_x_open rp_x_close rp_x_load_m3u rp_x_start_track rp_x_set_fade rp_x_ignore_silence
                    rp_x_play rp_x_track_ended rp_x_seek rp_x_tell_ms rp_x_mute_voices rp_x_snapshot_size
                    rp_x_snapshot_count rp_x_snapshots rp_x_capture_now], library.attached.keys
    assert_equal [%i[pointer long int], :pointer, {}], library.attached[:rp_x_open]
    assert_equal [%i[pointer pointer long], :int, { blocking: true }], library.attached[:rp_x_play]
  end

  # These emulate in C; releasing the GVL keeps the UI responsive.
  def test_only_emulating_calls_release_the_gvl
    library = FakeLibrary.new
    RubyPlayer::Backends::NativeGmeLib.attach_player_api(library, 'rp_x')
    blocking = library.attached.select { |_name, (_parameters, _result, options)| options[:blocking] }.keys

    assert_equal %i[rp_x_start_track rp_x_play rp_x_seek], blocking
  end
end
