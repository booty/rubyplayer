require "test_helper"
require "open3"
require "rbconfig"
require "tmpdir"

class StartupPreflightTest < Minitest::Test
  BIN = File.expand_path("../bin/rubyplayer", __dir__)
  RUNTIME_DEPENDENCIES = File.expand_path("../lib/rubyplayer/runtime_dependencies", __dir__)
  UI_APP = File.expand_path("../lib/rubyplayer/ui/app.rb", __dir__)

  def test_missing_dependencies_exit_before_app_construction
    Dir.mktmpdir do |dir|
      override = File.join(dir, "preflight_override.rb")
      File.write(override, <<~RUBY)
        require #{RUNTIME_DEPENDENCIES.inspect}
        module RubyPlayer
          class RuntimeDependencies
            def self.verify!
              raise MissingError, "sentinel dependency failure"
            end
          end

          module UI
            class App
              def initialize(*)
                warn "app was constructed"
              end

              def run; end
            end
          end
        end
        $LOADED_FEATURES << #{UI_APP.inspect}
      RUBY

      env = { "RUBYOPT" => "-r#{override}" }
      _stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, BIN)

      assert_equal 1, status.exitstatus
      assert_includes stderr, "sentinel dependency failure"
      refute_includes stderr, "app was constructed"
      refute_includes stderr, "startup_preflight_test"
    end
  end
end
