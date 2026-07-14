# rubyplayer user configuration
#
# This file is executable Ruby. Only add code you trust.
# Rubyplayer installs a copy at ~/.config/rubyplayer/config.rb.
# Edit installed copy, not this packaged example.
#
# Existing config.rb is never overwritten. If config.rb disappears and
# config-previous.rb exists, rubyplayer restores last-known-good source.
# Full setting reference and more formatter presets: README.md

RubyPlayer.configure do |config|
  # Common UI settings
  # config.ui.theme = "ocean_mist"
  # config.ui.library_pane_percent = 30
  # config.ui.seek_seconds = 10

  # Audio and scanning
  # config.audio.sample_rate = "auto" # or 48_000
  # config.audio.ring_buffer_ms = 500
  # config.scanner.thread_count = 0   # 0 uses CPU count

  # Key and backend maps
  # config.keymap.global["ctrl+p"] = :toggle_play
  # config.keymap.library["j"] = :nav_down
  # config.keymap.library["k"] = :nav_up
  # config.backends[".xyz"] = :ffmpeg

  # Compact flat-view formatter
  # config.ui.format_track_ungrouped = lambda do |track, fmt|
  #   fmt.line(
  #     fmt.number(track.track_number, fg: :text_muted),
  #     fmt.text(track.title, bold: true),
  #     fmt.text(track.artist, italic: true),
  #     fmt.duration(track.duration_ms, fg: :text_muted),
  #     fmt.stars(track.rating, fg: :yellow)
  #   )
  # end

  # Grouped formatter hides artist when it matches dominant album artist.
  # config.ui.format_track_grouped = lambda do |track, fmt|
  #   fmt.line(
  #     fmt.number(track.track_number, fg: :text_muted),
  #     fmt.text(track.title, bold: true),
  #     fmt.duration(track.duration_ms, fg: :text_muted),
  #     (fmt.text(track.artist, italic: true)
  #       unless track.artist == fmt.album_artist),
  #     fmt.stars(track.rating, fg: "#ffaa00")
  #   )
  # end
end
