require 'test_helper'

class QueueSelectionTest < Minitest::Test
  def setup
    @selection = RubyPlayer::UI::QueueSelection.new
    @tracks = Array.new(4) { |index| track(index) }
  end

  def track(id)
    RubyPlayer::Track.new(id: id, title: "Track #{id}")
  end

  def test_navigation_selects_ordered_upcoming_tracks
    @selection.replace(@tracks)

    assert_same @tracks[0], @selection.selected_track
    assert @selection.handle_action(:nav_down)
    assert_same @tracks[1], @selection.selected_track
    assert @selection.handle_action(:nav_up)
    assert_same @tracks[0], @selection.selected_track
  end

  def test_replace_preserves_selected_track_identity_when_items_before_it_change
    @selection.replace(@tracks)
    @selection.handle_action(:nav_down)
    @selection.handle_action(:nav_down)

    replacement = [@tracks[0], @tracks[2], @tracks[3]]
    @selection.replace(replacement)

    assert_same @tracks[2], @selection.selected_track
    assert_equal 1, @selection.selected_index
  end

  def test_replace_matches_fresh_track_objects_by_id
    @selection.replace(@tracks)
    @selection.handle_action(:nav_down)

    replacement = [track(0), track(1), track(3)]
    @selection.replace(replacement)

    assert_equal 1, @selection.selected_index
    assert_equal 1, @selection.selected_track.id
  end

  def test_empty_replacement_has_no_selection
    @selection.replace(@tracks)
    @selection.replace([])

    assert_nil @selection.selected_track
    assert_nil @selection.selected_index
  end

  def test_page_navigation_uses_rendered_page_size
    @selection.replace(@tracks)
    @selection.set_page_size(2)

    assert @selection.handle_action(:nav_page_down)
    assert_equal 2, @selection.selected_index
    assert @selection.handle_action(:nav_page_up)
    assert_equal 0, @selection.selected_index
  end

  def test_visible_items_follow_selection_and_report_trailing_overflow
    @selection.replace(@tracks)
    @selection.set_page_size(2)

    visible, hidden = @selection.visible_items(2)

    assert_equal @tracks.first(2), visible
    assert_equal 2, hidden

    @selection.handle_action(:nav_down)
    @selection.handle_action(:nav_down)
    visible, hidden = @selection.visible_items(2)

    assert_equal @tracks[1, 2], visible
    assert_equal 1, hidden
  end

  # Shift+arrows extend a range from the item they began on; its tracks come
  # back in queue order, by item identity (a queue can hold one track twice).
  def test_extending_selects_a_range_in_queue_order
    @selection.replace(@tracks)
    2.times { @selection.handle_action(:nav_down) }
    2.times { @selection.handle_action(:extend_selection_up) }

    assert_equal @tracks.first(3), @selection.selected_tracks
    @selection.handle_action(:nav_down)

    assert_equal [@tracks[1]], @selection.selected_tracks
  end

  def test_clear_selection_reports_whether_a_range_ended
    @selection.replace(@tracks)
    @selection.handle_action(:extend_selection_down)

    assert @selection.handle_action(:clear_selection)
    refute @selection.handle_action(:clear_selection)
    assert_equal [@tracks[1]], @selection.selected_tracks
  end

  def test_duplicate_tracks_select_by_item_identity
    copy = @tracks[0].dup
    @selection.replace([@tracks[0], @tracks[1], copy])
    @selection.handle_action(:nav_down)
    @selection.handle_action(:extend_selection_down)

    assert_equal [1, 2], @selection.selected_indexes
    assert_same copy, @selection.selected_tracks.last
  end

  # A queue change keeps the range while its anchor is still queued.
  def test_replace_keeps_the_range_until_its_anchor_leaves
    @selection.replace(@tracks)
    @selection.handle_action(:extend_selection_down)
    @selection.replace(@tracks + [track(9)])

    assert_equal @tracks.first(2), @selection.selected_tracks
    @selection.replace(@tracks.drop(1))

    assert_equal 1, @selection.selected_tracks.size
  end
end
