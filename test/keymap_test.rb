require "test_helper"

class KeymapTest < Minitest::Test
  def test_global_defaults
    k = RubyPlayer::Keymap.new
    assert_equal :toggle_play, k.action_for("space", pane: :library)
    assert_equal :cycle_pane, k.action_for("tab", pane: :tracks)
    assert_equal :play_now, k.action_for("enter", pane: :tracks)
    assert_equal :enqueue_end, k.action_for("n", pane: :library)
    assert_equal :undo, k.action_for("u", pane: :library)
    assert_equal :redo, k.action_for("ctrl_r", pane: :library)
    assert_equal :rate_3, k.action_for("3", pane: :tracks)
    assert_equal :quit, k.action_for("ctrl_c", pane: :library)
  end

  def test_pane_local_beats_global_and_case_matters
    k = RubyPlayer::Keymap.new
    assert_equal :sort_number, k.action_for("N", pane: :tracks) # uppercase: pane sort
    assert_equal :enqueue_end, k.action_for("n", pane: :tracks) # lowercase: global
    assert_nil k.action_for("N", pane: :library) # sorts don't exist in library pane
    assert_equal :nav_up, k.action_for("up", pane: :library)
  end

  def test_config_overrides
    k = RubyPlayer::Keymap.new({ "global" => { "x" => "quit" },
                                 "tracks" => { "z" => "toggle_group" } })
    assert_equal :quit, k.action_for("x", pane: :library)
    assert_equal :toggle_group, k.action_for("z", pane: :tracks)
    assert_nil k.action_for("z", pane: :library)
    assert_equal :toggle_play, k.action_for("space", pane: :library) # defaults survive
  end

  def test_bindings_for_lists_pane_then_global
    k = RubyPlayer::Keymap.new
    keys = k.bindings_for(:tracks).map(&:first)
    assert keys.index("G") < keys.index("space"), "pane-local keys come first"
  end

  def test_unknown_key_is_nil
    assert_nil RubyPlayer::Keymap.new.action_for("f9", pane: :library)
  end

  def test_transport_defaults_are_global
    k = RubyPlayer::Keymap.new
    assert_equal :next_track, k.action_for(">", pane: :library)
    assert_equal :next_track, k.action_for(">", pane: :tracks)
    assert_equal :seek_back, k.action_for("[", pane: :library)
    assert_equal :seek_back, k.action_for("[", pane: :tracks)
    assert_equal :seek_forward, k.action_for("]", pane: :library)
    assert_equal :seek_forward, k.action_for("]", pane: :tracks)
    assert_equal :remove_from_queue, k.action_for("x", pane: :library)
    assert_equal :remove_from_queue, k.action_for("x", pane: :tracks)
  end
end
