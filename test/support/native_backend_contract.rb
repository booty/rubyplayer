require 'minitest/mock'
require 'rubyplayer/backends/registry'

module TestSupport
  # Registry wiring every native libgme-core backend (SPC, GBS, NSF, HES)
  # must keep: its formats route to it by default, a backends config
  # override or a missing dylib falls back to libgme, and other formats
  # stay on libgme. Including classes define BACKEND_CLASS, BACKEND_NAME
  # (the registry's symbol for it) and EXTENSIONS (first one is canonical).
  module NativeBackendContract
    def setup
      @backend = self.class::BACKEND_CLASS.new
    end

    def teardown
      @handle&.close
    end

    def test_registry_routes_its_formats_to_the_native_player_by_default
      registry = RubyPlayer::Backends::Registry.new

      self.class::EXTENSIONS.each do |extension|
        assert_equal self.class::BACKEND_NAME, registry.backend_name_for("/x/a#{extension}")
        assert_equal self.class::BACKEND_NAME.to_s, registry.backend_for("/x/a#{extension}").name
      end
      assert_equal 'gme', registry.backend_for('/x/a.vgm').name
    end

    def test_backends_config_override_restores_libgme_playback
      extension = self.class::EXTENSIONS.first
      registry = RubyPlayer::Backends::Registry.new(extension => 'gme')

      assert_equal 'gme', registry.backend_for("/x/a#{extension}").name
    end

    def test_missing_native_library_falls_back_to_libgme
      self.class::BACKEND_CLASS.stub(:available?, false) do
        assert_equal 'gme', RubyPlayer::Backends::Registry.new.backend_for("/x/a#{self.class::EXTENSIONS.first}").name
      end
    end
  end
end
