require 'test_helper'
require_relative 'support/app_test_support'

class AppScanningTest < Minitest::Test
  include TestSupport::AppTestSupport

  def test_deletion_only_scan_refreshes_counts_and_panes
    select_tracks_for(:all)
    @app.handle_events
    # Reconciliation can delete rows without producing extraction work. The
    # background scan must still publish completion so the UI reloads them.
    FileUtils.rm(Dir[File.join(@music, '*')])
    @app.scan_paths([@music]).join
    @app.handle_events

    assert_equal 0, @app.tracks_pane.visible_tracks.size
    assert_empty(@app.library_pane.rows.select { |row| row.kind == :folder })
    counts = @app.instance_variable_get(:@db).read do |db|
      db.execute('SELECT track_count FROM folders').map { |row| row['track_count'] }
    end

    assert counts.all?(&:zero?)
  end

  def test_scan_progress_reloads_tracks_before_completion
    @app.handle_events
    select_tracks_for(:all)
    library = @app.instance_variable_get(:@library)
    root = library.roots.first
    library.upsert_track(
      folder_id: root['id'], physical_path: File.join(@music, 'new.vgm'),
      backend: 'gme', format: 'vgm', title: 'New during scan'
    )
    @app.instance_variable_set(
      :@last_scan_refresh_at,
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
    )
    @app.instance_variable_get(:@bus).publish(:scan_progress, processed: 1, total: 2)

    @app.handle_events

    assert_includes @app.tracks_pane.visible_tracks.map(&:title), 'New during scan'
  end

  def test_scan_progress_reveals_a_new_root_before_final_counts
    @app.handle_events
    library = @app.instance_variable_get(:@library)
    root = library.upsert_folder(parent_id: nil, name: 'New root', path: '/new-root', kind: 'dir')
    library.upsert_track(
      folder_id: root, physical_path: '/new-root/new.vgm',
      backend: 'gme', format: 'vgm', title: 'New during scan'
    )
    @app.instance_variable_set(
      :@last_scan_refresh_at,
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
    )
    @app.instance_variable_get(:@bus).publish(:scan_progress, processed: 1, total: 2)

    @app.handle_events

    folders = @app.library_pane.rows.filter_map { |row| row.folder&.fetch('name') }

    assert_includes folders, 'New root'
  end

  def test_scan_progress_refresh_is_throttled_and_deferred
    @app.handle_events
    refreshes = 0
    original = @app.method(:refresh_scan_panes)
    @app.define_singleton_method(:refresh_scan_panes) do
      refreshes += 1
      original.call
    end
    bus = @app.instance_variable_get(:@bus)
    @app.instance_variable_set(
      :@last_scan_refresh_at,
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
    )

    bus.publish(:scan_progress, processed: 1, total: 3)
    @app.handle_events
    bus.publish(:scan_progress, processed: 2, total: 3)
    @app.handle_events

    assert_equal 1, refreshes

    @app.instance_variable_set(
      :@last_scan_refresh_at,
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
    )
    @app.handle_events

    assert_equal 2, refreshes
  end

  def test_scan_progress_does_not_reload_the_queue
    @app.handle_events
    queue_reloads = 0
    queued = @app.queued_pane
    original = queued.method(:reload!)
    queued.define_singleton_method(:reload!) do
      queue_reloads += 1
      original.call
    end
    @app.instance_variable_set(
      :@last_scan_refresh_at,
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
    )
    @app.instance_variable_get(:@bus).publish(:scan_progress, processed: 1, total: 2)

    @app.handle_events

    assert_equal 0, queue_reloads
  end
end
