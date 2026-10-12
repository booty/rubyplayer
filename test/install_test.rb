# frozen_string_literal: true

require_relative 'test_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

class InstallTest < Minitest::Test
  INSTALLER = File.expand_path('../bin/install', __dir__)

  def setup
    @temporary = File.realpath(Dir.mktmpdir('rubyplayer-install'))
    @project = File.join(@temporary, "player's checkout")
    @destination = File.join(@temporary, 'local bin')
    @caller = File.join(@temporary, 'music folder')
    FileUtils.mkdir_p([File.join(@project, 'bin'), @destination, @caller])
    File.write(File.join(@project, 'Gemfile'), "source 'https://rubygems.org'\n")
    FileUtils.cp(File.expand_path('../.ruby-version', __dir__), @project)
    File.write(File.join(@project, 'bin/rubyplayer'), <<~RUBY)
      require 'json'
      puts JSON.generate(cwd: Dir.pwd, args: ARGV, yjit: RubyVM::YJIT.enabled?,
                         gemfile: Bundler.default_gemfile.to_s,
                         lockfile: Bundler.default_lockfile.to_s)
      exit Integer(ENV.fetch('PLAYER_EXIT_STATUS', '0'))
    RUBY
  end

  def teardown
    FileUtils.remove_entry(@temporary)
  end

  def test_both_commands_preserve_caller_paths_and_use_project_bundle_with_yjit
    install!
    %w[rubyplayer rp].each do |command|
      stdout, stderr, status = Open3.capture3(
        { 'PLAYER_EXIT_STATUS' => '23' }, File.join(@destination, command),
        './album with spaces', "a'b.vgm", chdir: @caller
      )

      assert_equal 23, status.exitstatus, stderr
      result = JSON.parse(stdout)

      assert_equal @caller, result.fetch('cwd')
      assert_equal ['./album with spaces', "a'b.vgm"], result.fetch('args')
      assert result.fetch('yjit')
      assert_equal File.join(@project, 'Gemfile'), result.fetch('gemfile')
      assert_equal File.join(@project, 'Gemfile.lock'), result.fetch('lockfile')
    end
  end

  def test_reinstallation_updates_managed_launchers
    install!
    install!

    assert File.executable?(File.join(@destination, 'rubyplayer'))
    assert_equal 'rubyplayer', File.readlink(File.join(@destination, 'rp'))
  end

  def test_conflicting_command_is_preserved_without_partial_installation
    existing = File.join(@destination, 'rp')
    File.write(existing, 'existing command')
    _stdout, stderr, status = install

    refute_predicate status, :success?
    assert_includes stderr, existing
    assert_equal 'existing command', File.read(existing)
    refute_path_exists File.join(@destination, 'rubyplayer')
  end

  private

  def install
    # Copy the installer so path quoting is exercised against a real checkout path.
    FileUtils.cp(INSTALLER, File.join(@project, 'bin/install'))
    Open3.capture3('/bin/bash', File.join(@project, 'bin/install'), '--bin-dir', @destination,
                   chdir: @caller)
  end

  def install!
    _stdout, stderr, status = install

    assert_predicate status, :success?, stderr
  end
end
