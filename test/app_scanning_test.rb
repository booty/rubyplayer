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
end
