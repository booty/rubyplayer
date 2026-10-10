require 'test_helper'
require_relative 'support/app_test_support'

class AppPlaylistModalTest < Minitest::Test
  include TestSupport::AppTestSupport

  def test_modal_queries_playlists_only_when_opened
    library = @app.instance_variable_get(:@library)
    library.create_playlist('Mix')
    select_tracks_for(:all)
    use_screen
    queries = 0
    original = library.method(:playlists)
    library.define_singleton_method(:playlists) do |**options|
      queries += 1
      original.call(**options)
    end
    @app.handle_key('l')
    opening_queries = queries
    3.times { @app.render }
    @app.handle_key('m')
    @app.render

    assert_equal opening_queries, queries, 'modal redraws and filtering must use its snapshot'
    assert_operator opening_queries, :>, 0
  end

  def test_reopening_modal_refreshes_its_snapshot
    library = @app.instance_variable_get(:@library)
    select_tracks_for(:all)
    @app.handle_key('l')
    @app.handle_key('escape')
    id = library.create_playlist('New Mix')
    track = @app.tracks_pane.selected_track
    @app.handle_key('l')
    @app.handle_key('enter')

    assert_nil @app.playlist_modal
    assert_equal [track.id], library.playlist_tracks(id).map(&:id)
  end

  def test_name_conflict_stays_open_and_renders_error_until_edit
    library = @app.instance_variable_get(:@library)
    library.create_playlist('Mix')
    select_tracks_for(:all)
    use_screen
    @app.handle_key('l')
    'Mix'.each_char { |key| @app.handle_key(key) }
    2.times { @app.handle_key('down') } # Recent, alphabetical, then create.
    @app.handle_key('enter')
    @app.render

    refute_nil @app.playlist_modal
    assert_includes back_buffer_text, 'already exists'
    @app.handle_key('x')
    @app.render

    refute_includes back_buffer_text, 'already exists'
    assert_includes back_buffer_text, 'New playlist: Mixx'
  end

  def test_deleted_snapshot_playlist_reports_failure_without_crashing
    library = @app.instance_variable_get(:@library)
    id = library.create_playlist('Mix')
    select_tracks_for(:all)
    use_screen
    @app.handle_key('l')
    library.delete_playlist(id)
    @app.handle_key('enter')
    @app.render

    assert_nil @app.playlist_modal
    assert_includes back_buffer_text, 'Playlist no longer exists'
  end
end
