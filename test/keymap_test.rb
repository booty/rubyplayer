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
    assert_equal :filter_tracks, k.action_for("/", pane: :tracks)
  end

  def test_pane_local_beats_global_and_matching_is_case_insensitive
    k = RubyPlayer::Keymap.new
    assert_equal :toggle_group, k.action_for("g", pane: :tracks) # pane-local
    assert_equal :toggle_group, k.action_for("G", pane: :tracks) # same key, either case
    assert_nil k.action_for("g", pane: :library) # group toggle doesn't exist in library pane
    assert_equal :nav_up, k.action_for("up", pane: :library)
  end

  def test_page_navigation_bound_in_both_panes
    k = RubyPlayer::Keymap.new
    %i[library tracks].each do |pane|
      assert_equal :nav_page_up, k.action_for("pgup", pane: pane)
      assert_equal :nav_page_down, k.action_for("pgdn", pane: pane)
      # for keyboards without pgup/pgdn keys
      assert_equal :nav_page_up, k.action_for("shift_up", pane: pane)
      assert_equal :nav_page_down, k.action_for("shift_down", pane: pane)
      # vim-ish aliases
      assert_equal :nav_page_up, k.action_for("ctrl_u", pane: pane)
      assert_equal :nav_page_down, k.action_for("ctrl_d", pane: pane)
    end
  end

  def test_sort_number_and_sort_artist_avoid_colliding_with_global_letters
    k = RubyPlayer::Keymap.new
    # "n"/"a" are global bindings (enqueue_end/add_path); sort_number and
    # sort_artist must not shadow them via case-folding, so they live on
    # non-letter keys instead.
    assert_equal :sort_number, k.action_for("#", pane: :tracks)
    assert_equal :sort_artist, k.action_for("@", pane: :tracks)
    assert_equal :enqueue_end, k.action_for("n", pane: :tracks)
    assert_equal :enqueue_end, k.action_for("N", pane: :tracks)
    assert_equal :add_path, k.action_for("a", pane: :tracks)
    assert_equal :add_path, k.action_for("A", pane: :tracks)
  end

  def test_config_overrides
    k = RubyPlayer::Keymap.new({ "global" => { "x" => "quit" },
                                 "tracks" => { "z" => "toggle_group" } })
    assert_equal :quit, k.action_for("x", pane: :tracks) # global override, no tracks-local "x"
    assert_equal :toggle_group, k.action_for("z", pane: :tracks)
    assert_nil k.action_for("z", pane: :library)
    assert_equal :toggle_play, k.action_for("space", pane: :library) # defaults survive
    # library's own default for "x" shadows the global override, same as
    # any other pane-local binding would.
    assert_equal :remove_library_item, k.action_for("x", pane: :library)
  end

  def test_bindings_for_lists_pane_then_global
    k = RubyPlayer::Keymap.new
    keys = k.bindings_for(:tracks).map(&:first)
    assert keys.index("g") < keys.index("space"), "pane-local keys come first"
  end

  def test_config_override_keys_are_case_folded
    k = RubyPlayer::Keymap.new({ "global" => { "Z" => "quit" } })
    assert_equal :quit, k.action_for("z", pane: :library)
    assert_equal :quit, k.action_for("Z", pane: :library)
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
    assert_equal :remove_from_queue, k.action_for("x", pane: :tracks)
    assert_equal :purge_visible_missing, k.action_for("ctrl_x", pane: :tracks)
  end

  # "x" is pane-scoped: Library removes a library item, everywhere else
  # (the global default) it removes from the playback queue.
  def test_remove_key_is_pane_scoped
    k = RubyPlayer::Keymap.new
    assert_equal :remove_library_item, k.action_for("x", pane: :library)
    assert_equal :remove_from_queue, k.action_for("x", pane: :tracks)
  end

  def test_theme_picker_key_is_global_and_sort_title_moved_off_it
    k = RubyPlayer::Keymap.new
    assert_equal :show_theme_picker, k.action_for("t", pane: :library)
    assert_equal :show_theme_picker, k.action_for("T", pane: :tracks) # not shadowed by sort_title
    assert_equal :sort_title, k.action_for("y", pane: :tracks)
  end

  def test_help_key_is_global
    k = RubyPlayer::Keymap.new
    assert_equal :show_help, k.action_for("?", pane: :library)
    assert_equal :show_help, k.action_for("?", pane: :tracks)
  end

  def test_show_track_info_key_is_tracks_scoped
    k = RubyPlayer::Keymap.new
    assert_equal :show_track_info, k.action_for("i", pane: :tracks)
    assert_nil k.action_for("i", pane: :library)
  end
end
