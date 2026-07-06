require "test_helper"

class RegistryTest < Minitest::Test
  def setup
    @reg = RubyPlayer::Backends::Registry.new
  end

  def test_supported_extensions
    assert @reg.supported?("/x/a.nsf")
    assert @reg.supported?("/x/a.MOD") # case-insensitive
    assert @reg.supported?("/x/a.spc")
    refute @reg.supported?("/x/warrior.jpg")
    refute @reg.supported?("/x/noext")
  end

  def test_backend_names
    assert_equal :gme, @reg.backend_name_for("/x/a.vgm")
    assert_equal :openmpt, @reg.backend_name_for("/x/a.xm")
    assert_nil @reg.backend_name_for("/x/a.jpg")
  end

  def test_multitrack_detection
    assert @reg.multitrack?("/x/a.nsf")
    assert @reg.multitrack?("/x/a.gbs")
    assert @reg.multitrack?("/x/a.hes")
    refute @reg.multitrack?("/x/a.spc")
    refute @reg.multitrack?("/x/a.mod")
  end

  def test_archive_detection
    assert @reg.archive?("/x/a.zip")
    assert @reg.archive?("/x/a.7z")
    assert @reg.archive?("/x/a.RAR") # case-insensitive
    refute @reg.archive?("/x/a.nsf")
    refute @reg.archive?("/x/a.jpg")
  end

  def test_archives_are_supported_but_not_multitrack_and_have_no_backend
    assert @reg.supported?("/x/a.zip")
    refute @reg.multitrack?("/x/a.zip")
    assert_nil @reg.backend_name_for("/x/a.7z")
  end

  def test_config_overrides
    reg = RubyPlayer::Backends::Registry.new({ "vgm" => "openmpt", ".weird" => "gme" })
    assert_equal :openmpt, reg.backend_name_for("/x/a.vgm")
    assert_equal :gme, reg.backend_name_for("/x/a.weird")
  end

  def test_backend_for_returns_memoized_instance
    a = @reg.backend_for("/x/a.mod")
    b = @reg.backend_for("/x/b.xm")
    assert_same a, b
    assert_equal "openmpt", a.name
  end
end
