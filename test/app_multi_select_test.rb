# frozen_string_literal: true

require 'test_helper'
require_relative 'support/app_test_support'

# Shift+Up/Down selects a range in the Tracks pane; track actions apply to
# every selected track, in list order.
class AppMultiSelectTest < Minitest::Test
  include TestSupport::AppTestSupport

  def setup
    super
    select_tracks_for(:folder)
    @app.handle_key('down')
    2.times { @app.handle_key('shift_down') }
    @selected = @app.tracks_pane.selected_tracks
  end

  def test_shift_arrows_select_three_tracks
    assert_equal 3, @selected.size
    assert_equal 3, @selected.map(&:id).uniq.size
  end

  # Enter puts the whole range at the head of the queue and plays its first.
  def test_enter_queues_the_range_first_and_plays_its_first_track
    calls = []
    @app.engine.define_singleton_method(:enqueue_now) { |tracks| calls << tracks }
    @app.handle_key('enter')

    assert_equal [@selected], calls
  end

  def test_queue_keys_enqueue_the_whole_range
    @app.handle_key('n')

    assert_equal @selected.map(&:id), @app.engine.queue_items.map(&:id)
  end

  def test_rating_rates_every_selected_track
    @app.handle_key('4')

    assert_equal [4, 4, 4], @selected.map { |track| library.rating_of(track.id) }
    assert_equal 3, @app.tracks_pane.selected_tracks.size, 'the range survives the rating'
  end

  def test_add_to_playlist_adds_the_whole_range
    id = library.create_playlist('Mix')
    @app.handle_key('l')
    @app.handle_key('enter')

    assert_equal @selected.map(&:id), library.playlist_tracks(id).map(&:id)
  end

  def test_playlist_view_removes_every_selected_entry_and_refuses_moves
    id = library.create_playlist('Mix')
    tracks = library.all_tracks.first(4)
    tracks.each { |track| library.add_to_playlist(id, track.id) }
    open_playlist(id)
    @app.handle_key('down')
    @app.handle_key('shift_down')
    @app.handle_key('ctrl_down')

    assert_equal tracks.map(&:id), library.playlist_tracks(id).map(&:id)
    @app.handle_key('x')

    assert_equal [tracks[0].id, tracks[3].id], library.playlist_tracks(id).map(&:id)
  end

  def test_escape_ends_the_range
    @app.handle_key('escape')

    assert_equal 1, @app.tracks_pane.selected_tracks.size
  end

  private

  def library = @app.instance_variable_get(:@library)
end
