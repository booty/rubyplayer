# frozen_string_literal: true

require 'test_helper'
require_relative 'support/app_test_support'

# Shift+Up/Down ranges in the Playback Queue view and the Queued pane: X
# removes them in one undoable edit, and track actions take every track.
class AppQueueMultiSelectTest < Minitest::Test
  include TestSupport::AppTestSupport

  def setup
    super
    @queued = library.all_tracks.first(4)
    @app.engine.enqueue_end(@queued)
    @app.refresh_panes
  end

  def test_queue_view_removes_a_range_as_one_undo
    select_tracks_for(:queue)
    @app.handle_key('down')
    2.times { @app.handle_key('shift_down') }

    assert_includes @app.tracks_pane.title, '3 selected'
    @app.handle_key('x')

    assert_equal [@queued[0].id], queue_ids
    @app.handle_key('u')

    assert_equal @queued.map(&:id), queue_ids
  end

  def test_queue_view_rates_the_range
    select_tracks_for(:queue)
    @app.handle_key('shift_down')
    @app.handle_key('5')

    assert_equal [5, 5, nil], @queued.first(3).map { |track| library.rating_of(track.id) }
  end

  def test_queued_pane_ranges_rate_remove_and_shade
    select_library_kind(:folder)
    use_screen(rows: 30, cols: 160)
    @app.handle_key('tab') until @app.active_pane == :queued
    @app.handle_key('shift_down')
    @app.handle_key('3')

    assert_equal [3, 3], @queued.first(2).map { |track| library.rating_of(track.id) }
    @app.render
    backgrounds = queued_row_backgrounds

    assert_includes backgrounds, RubyPlayer::Theme::DEFAULT[:surface_alt]
    assert_includes backgrounds, RubyPlayer::Theme::DEFAULT[:selection_bg]
    @app.handle_key('x')

    assert_equal @queued.drop(2).map(&:id), queue_ids
  end

  private

  def library = @app.instance_variable_get(:@library)

  def queue_ids = @app.engine.queue_items.map(&:id)

  # The first cell of each Queued pane row, just inside its border.
  def queued_row_backgrounds
    back = @app.instance_variable_get(:@screen).instance_variable_get(:@back)
    column = back.first.map(&:ch).join.index('Queued') - 2
    back.map { |row| row[column]&.bg }
  end
end
