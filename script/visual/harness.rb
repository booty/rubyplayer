# frozen_string_literal: true

# Runs the real App inside a terminal window for visual snapshots, against a
# throwaway library so the user's config, database, and music stay untouched.
#
#   ruby script/visual/harness.rb WORK_DIR ART_MODE
#
# WORK_DIR must already hold music/ (a playable track plus cover.png). The
# harness rewrites WORK_DIR/status.json whenever the art placement or screen
# size changes, so the launcher can wait for a settled frame before capturing.

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'json'
require 'rubyplayer'
require 'rubyplayer/ui/app'

work_dir, art_mode = ARGV
# The terminal window vanishes on exit, so failures must land in a file the
# launcher can report.
$stderr.reopen(File.join(work_dir, 'harness.log'), 'a')
$stderr.sync = true
music = File.join(work_dir, 'music')
config_path = File.join(work_dir, 'config.rb')
# Accent tinting would pull theme colors toward the synthetic cover's
# magenta and confuse pixel measurement.
File.write(config_path, <<~CONFIG)
  RubyPlayer.configure do |config|
    config.ui.art_mode = #{art_mode.inspect}
    config.ui.art_accent = false
  end
CONFIG

app = RubyPlayer::UI::App.new(config_path: config_path, data_path: File.join(work_dir, 'library.sqlite3'),
                              null_audio: true)
app.scan_paths([music], wait: true)
track = app.instance_variable_get(:@library).all_tracks.first
app.engine.enqueue_now([track])

status_path = File.join(work_dir, 'status.json')
# Closing the window sends SIGHUP; exit through App#run's ensure so the
# terminal and native audio are released normally.
trap('HUP') { app.instance_variable_set(:@quit, true) }

Thread.new do
  last = nil
  loop do
    screen = app.instance_variable_get(:@screen)
    image = app.instance_variable_get(:@kitty_image)
    status = {
      cols: screen.cols, rows: screen.rows,
      region: app.instance_variable_get(:@art_region),
      placement: image.instance_variable_get(:@placement),
      cell_size: RubyPlayer::UI::KittyImage.tty_cell_size,
      settling: app.send(:resize_settling?)
    }
    if status != last
      File.write("#{status_path}.tmp", JSON.generate(status))
      File.rename("#{status_path}.tmp", status_path)
      last = status
    end
    sleep 0.05
  end
end

# Snapshots never type anything. Input is either the user typing while an
# iTerm2 window holds focus or terminal noise (a reply to some query); log it
# for the report but never act on it, so neither can change what's captured.
app.singleton_class.prepend(Module.new do
  def read_input
    warn "input: #{$stdin.read_nonblock(1024).inspect}"
  rescue IO::WaitReadable, EOFError
    nil
  end
end)

begin
  app.run
rescue Exception => e # rubocop:disable Lint/RescueException -- report everything, then re-raise
  warn "#{e.class}: #{e.message}\n#{e.backtrace.join("\n")}"
  raise
end
