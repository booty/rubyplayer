# frozen_string_literal: true

module RubyPlayer
  # Questions about a PlaybackEngine#state hash, shared by the UI and the
  # media-keys bridge. A paused track still counts as "playing" in the
  # engine's flags, so "audio is running" needs both.
  module PlaybackState
    def self.actively_playing?(state) = !!(state[:playing] && !state[:paused])
  end
end
